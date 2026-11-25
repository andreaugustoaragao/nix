package cdp

import (
	"bufio"
	"context"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestSetFileInputFilesMockCDP(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	port := ln.Addr().(*net.TCPAddr).Port

	var gotFiles []string
	var gotSelector string
	var gotInserted []string
	var enterEvents int
	mux := http.NewServeMux()
	mux.HandleFunc("/json/list", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode([]targetInfo{{
			ID:                   "TARGET-1",
			Type:                 "page",
			URL:                  "https://mail.google.com/mail/u/0/#inbox",
			WebSocketDebuggerURL: fmt.Sprintf("ws://127.0.0.1:%d/devtools/page/TARGET-1", port),
		}})
	})
	mux.HandleFunc("/devtools/page/TARGET-1", func(w http.ResponseWriter, r *http.Request) {
		hj, ok := w.(http.Hijacker)
		if !ok {
			t.Error("response writer does not support hijack")
			return
		}
		conn, brw, err := hj.Hijack()
		if err != nil {
			t.Errorf("hijack: %v", err)
			return
		}
		defer conn.Close()

		key := r.Header.Get("Sec-WebSocket-Key")
		sum := sha1.Sum([]byte(key + wsGUID))
		accept := base64.StdEncoding.EncodeToString(sum[:])
		_, _ = fmt.Fprintf(conn, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept)

		for {
			payload, err := readClientFrame(brw.Reader)
			if err != nil {
				return
			}
			var req struct {
				ID     int64           `json:"id"`
				Method string          `json:"method"`
				Params json.RawMessage `json:"params"`
			}
			if err := json.Unmarshal(payload, &req); err != nil {
				return
			}
			// Inject an asynchronous CDP event before replying to verify event skipping.
			_ = writeServerTextFrame(conn, []byte(`{"method":"DOM.documentUpdated","params":{}}`))

			var reply map[string]any
			switch req.Method {
			case "DOM.enable":
				reply = map[string]any{"id": req.ID, "result": map[string]any{}}
			case "DOM.getDocument":
				reply = map[string]any{"id": req.ID, "result": map[string]any{"root": map[string]any{"nodeId": 10}}}
			case "DOM.querySelector":
				var p struct {
					Selector string `json:"selector"`
				}
				_ = json.Unmarshal(req.Params, &p)
				gotSelector = p.Selector
				nodeID := 42
				if strings.Contains(p.Selector, "missing") {
					nodeID = 0
				}
				reply = map[string]any{"id": req.ID, "result": map[string]any{"nodeId": nodeID}}
			case "DOM.setFileInputFiles":
				var p struct {
					NodeID int      `json:"nodeId"`
					Files  []string `json:"files"`
				}
				_ = json.Unmarshal(req.Params, &p)
				gotFiles = append([]string(nil), p.Files...)
				reply = map[string]any{"id": req.ID, "result": map[string]any{}}
			case "Runtime.evaluate":
				var p struct {
					Expression string `json:"expression"`
				}
				_ = json.Unmarshal(req.Params, &p)
				okVal := !strings.Contains(p.Expression, "failFocus")
				reply = map[string]any{"id": req.ID, "result": map[string]any{"result": map[string]any{"value": okVal}}}
			case "Input.insertText":
				var p struct {
					Text string `json:"text"`
				}
				_ = json.Unmarshal(req.Params, &p)
				gotInserted = append(gotInserted, p.Text)
				reply = map[string]any{"id": req.ID, "result": map[string]any{}}
			case "Input.dispatchKeyEvent":
				var p struct {
					Key string `json:"key"`
				}
				_ = json.Unmarshal(req.Params, &p)
				if p.Key == "Enter" {
					enterEvents++
				}
				reply = map[string]any{"id": req.ID, "result": map[string]any{}}
			}
			b, _ := json.Marshal(reply)
			_ = writeServerTextFrame(conn, b)
		}
	})

	srv := &http.Server{Handler: mux}
	go func() { _ = srv.Serve(ln) }()
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wantFiles := []string{"/tmp/one.png", "/tmp/two.pdf"}
	if err := SetFileInputFiles(ctx, port, "TARGET-1", `input[name="Filedata"]`, wantFiles); err != nil {
		t.Fatalf("SetFileInputFiles failed: %v", err)
	}
	if gotSelector != `input[name="Filedata"]` {
		t.Fatalf("selector = %q", gotSelector)
	}
	if len(gotFiles) != 2 || gotFiles[0] != wantFiles[0] || gotFiles[1] != wantFiles[1] {
		t.Fatalf("files = %v, want %v", gotFiles, wantFiles)
	}

	if err := SetFileInputFiles(ctx, port, "TARGET-1", `input.missing`, wantFiles); err == nil {
		t.Fatalf("expected error for missing file input selector")
	}
	if err := SetFileInputFiles(ctx, port, "UNKNOWN", `input[name="Filedata"]`, wantFiles); err == nil {
		t.Fatalf("expected error for unknown target ID")
	}

	if err := FillRecipientChips(ctx, port, "TARGET-1", "focusOk()", []string{"a@avaya.com", "b@avaya.com"}); err != nil {
		t.Fatalf("FillRecipientChips failed: %v", err)
	}
	if len(gotInserted) != 2 || gotInserted[0] != "a@avaya.com" || gotInserted[1] != "b@avaya.com" || enterEvents != 4 {
		t.Fatalf("unexpected recipient events: inserted=%v enterEvents=%d", gotInserted, enterEvents)
	}
	if err := FillRecipientChips(ctx, port, "TARGET-1", "failFocus()", []string{"a@avaya.com"}); err == nil {
		t.Fatalf("expected error when focus expression returns false")
	}
}

func readClientFrame(r *bufio.Reader) ([]byte, error) {
	var hdr [2]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return nil, err
	}
	if (hdr[0] & 0x0f) == 0x8 {
		return nil, io.EOF
	}
	n := uint64(hdr[1] & 0x7f)
	if n == 126 {
		var ext [2]byte
		if _, err := io.ReadFull(r, ext[:]); err != nil {
			return nil, err
		}
		n = uint64(binary.BigEndian.Uint16(ext[:]))
	} else if n == 127 {
		var ext [8]byte
		if _, err := io.ReadFull(r, ext[:]); err != nil {
			return nil, err
		}
		n = binary.BigEndian.Uint64(ext[:])
	}
	var mask [4]byte
	if _, err := io.ReadFull(r, mask[:]); err != nil {
		return nil, err
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, err
	}
	for i := range buf {
		buf[i] ^= mask[i%4]
	}
	return buf, nil
}

func writeServerTextFrame(w io.Writer, payload []byte) error {
	var hdr [10]byte
	hdr[0] = 0x81
	idx := 2
	n := len(payload)
	switch {
	case n < 126:
		hdr[1] = byte(n)
	case n <= 65535:
		hdr[1] = 126
		binary.BigEndian.PutUint16(hdr[2:4], uint16(n))
		idx = 4
	default:
		hdr[1] = 127
		binary.BigEndian.PutUint64(hdr[2:10], uint64(n))
		idx = 10
	}
	if _, err := w.Write(hdr[:idx]); err != nil {
		return err
	}
	_, err := w.Write(payload)
	return err
}
