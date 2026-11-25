package cdp

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type targetInfo struct {
	ID                   string `json:"id"`
	Type                 string `json:"type"`
	URL                  string `json:"url"`
	WebSocketDebuggerURL string `json:"webSocketDebuggerUrl"`
}

// SetFileInputFiles attaches local file paths to a matching <input type="file"> on a specific
// CDP page target using pure Go stdlib RFC 6455 WebSocket + Chrome DevTools Protocol.
func SetFileInputFiles(ctx context.Context, cdpPort int, targetID, cssSelector string, files []string) error {
	if cdpPort <= 0 {
		return errors.New("invalid CDP port")
	}
	if targetID == "" {
		return errors.New("missing browser-task page target ID")
	}
	if len(files) == 0 {
		return nil
	}

	wsURL, err := lookupTargetWS(ctx, cdpPort, targetID)
	if err != nil {
		return err
	}
	conn, err := dialWS(ctx, wsURL)
	if err != nil {
		return err
	}
	defer conn.Close()

	var nextID int64
	call := func(method string, params map[string]any) (json.RawMessage, error) {
		nextID++
		return conn.call(ctx, nextID, method, params)
	}

	if _, err := call("DOM.enable", nil); err != nil {
		return fmt.Errorf("DOM.enable: %w", err)
	}
	docRaw, err := call("DOM.getDocument", map[string]any{
		"depth":  -1,
		"pierce": true,
	})
	if err != nil {
		return fmt.Errorf("DOM.getDocument: %w", err)
	}
	var doc struct {
		Root struct {
			NodeID int `json:"nodeId"`
		} `json:"root"`
	}
	if err := json.Unmarshal(docRaw, &doc); err != nil || doc.Root.NodeID == 0 {
		return fmt.Errorf("invalid DOM.getDocument root: %w", err)
	}

	selRaw, err := call("DOM.querySelector", map[string]any{
		"nodeId":   doc.Root.NodeID,
		"selector": cssSelector,
	})
	if err != nil {
		return fmt.Errorf("DOM.querySelector(%q): %w", cssSelector, err)
	}
	var sel struct {
		NodeID int `json:"nodeId"`
	}
	if err := json.Unmarshal(selRaw, &sel); err != nil || sel.NodeID == 0 {
		return fmt.Errorf("file input selector %q not found in target %s", cssSelector, targetID)
	}

	if _, err := call("DOM.setFileInputFiles", map[string]any{
		"nodeId": sel.NodeID,
		"files":  files,
	}); err != nil {
		return fmt.Errorf("DOM.setFileInputFiles: %w", err)
	}
	return nil
}

// FillRecipientChips focuses a collapsible Gmail recipient input and enters each address via
// real Chromium Input.insertText + Enter key events inside one continuous CDP session so
// Gmail never blurs/collapses the recipient row between focus and input.
func FillRecipientChips(ctx context.Context, cdpPort int, targetID, focusExpr string, addrs []string) error {
	if cdpPort <= 0 {
		return errors.New("invalid CDP port")
	}
	if targetID == "" {
		return errors.New("missing browser-task page target ID")
	}
	if len(addrs) == 0 {
		return nil
	}

	wsURL, err := lookupTargetWS(ctx, cdpPort, targetID)
	if err != nil {
		return err
	}
	conn, err := dialWS(ctx, wsURL)
	if err != nil {
		return err
	}
	defer conn.Close()

	var nextID int64
	call := func(method string, params map[string]any) (json.RawMessage, error) {
		nextID++
		return conn.call(ctx, nextID, method, params)
	}

	evalRaw, err := call("Runtime.evaluate", map[string]any{
		"expression":    focusExpr,
		"returnByValue": true,
	})
	if err != nil {
		return fmt.Errorf("Runtime.evaluate focus recipient input: %w", err)
	}
	var evalRes struct {
		Result struct {
			Value bool `json:"value"`
		} `json:"result"`
	}
	if err := json.Unmarshal(evalRaw, &evalRes); err != nil || !evalRes.Result.Value {
		return fmt.Errorf("failed to focus recipient input in target %s (raw: %s)", targetID, string(evalRaw))
	}

	for _, addr := range addrs {
		if _, err := call("Input.insertText", map[string]any{"text": addr}); err != nil {
			return fmt.Errorf("Input.insertText(%q): %w", addr, err)
		}
		for _, evType := range []string{"keyDown", "keyUp"} {
			if _, err := call("Input.dispatchKeyEvent", map[string]any{
				"type":                  evType,
				"key":                   "Enter",
				"code":                  "Enter",
				"windowsVirtualKeyCode": 13,
				"nativeVirtualKeyCode":  13,
			}); err != nil {
				return fmt.Errorf("Input.dispatchKeyEvent(Enter %s): %w", evType, err)
			}
		}
	}
	return nil
}

func lookupTargetWS(ctx context.Context, cdpPort int, targetID string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("http://127.0.0.1:%d/json/list", cdpPort), nil)
	if err != nil {
		return "", err
	}
	resp, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if err != nil {
		return "", fmt.Errorf("query CDP target list on 127.0.0.1:%d: %w", cdpPort, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("CDP /json/list returned HTTP %d", resp.StatusCode)
	}
	var targets []targetInfo
	if err := json.NewDecoder(resp.Body).Decode(&targets); err != nil {
		return "", fmt.Errorf("decode CDP target list: %w", err)
	}
	for _, t := range targets {
		if t.ID == targetID {
			if t.WebSocketDebuggerURL == "" {
				return "", fmt.Errorf("target %s has empty webSocketDebuggerUrl", targetID)
			}
			return t.WebSocketDebuggerURL, nil
		}
	}
	return "", fmt.Errorf("target %s not found on CDP port %d (%d targets inspected)", targetID, cdpPort, len(targets))
}

type wsConn struct {
	raw net.Conn
	br  *bufio.Reader
}

const wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

func dialWS(ctx context.Context, rawURL string) (*wsConn, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, fmt.Errorf("parse ws url %q: %w", rawURL, err)
	}
	host := u.Host
	if !strings.Contains(host, ":") {
		host += ":80"
	}
	var d net.Dialer
	c, err := d.DialContext(ctx, "tcp", host)
	if err != nil {
		return nil, fmt.Errorf("dial ws %s: %w", host, err)
	}
	if dl, ok := ctx.Deadline(); ok {
		_ = c.SetDeadline(dl)
	}

	var keyBytes [16]byte
	if _, err := rand.Read(keyBytes[:]); err != nil {
		_ = c.Close()
		return nil, err
	}
	secKey := base64.StdEncoding.EncodeToString(keyBytes[:])
	path := u.RequestURI()
	if path == "" {
		path = "/"
	}
	req := fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
		path, u.Host, secKey)
	if _, err := io.WriteString(c, req); err != nil {
		_ = c.Close()
		return nil, err
	}

	br := bufio.NewReaderSize(c, 64*1024)
	resp, err := http.ReadResponse(br, &http.Request{Method: http.MethodGet})
	if err != nil {
		_ = c.Close()
		return nil, fmt.Errorf("ws handshake response: %w", err)
	}
	if resp.StatusCode != http.StatusSwitchingProtocols {
		_ = c.Close()
		return nil, fmt.Errorf("ws handshake failed: HTTP %d", resp.StatusCode)
	}
	h := sha1.Sum([]byte(secKey + wsGUID))
	expectedAccept := base64.StdEncoding.EncodeToString(h[:])
	if resp.Header.Get("Sec-WebSocket-Accept") != expectedAccept {
		_ = c.Close()
		return nil, errors.New("ws handshake Sec-WebSocket-Accept mismatch")
	}
	return &wsConn{raw: c, br: br}, nil
}

func (w *wsConn) Close() error {
	_ = w.writeFrame(0x8, nil)
	return w.raw.Close()
}

func (w *wsConn) writeFrame(opcode byte, payload []byte) error {
	var header [14]byte
	header[0] = 0x80 | (opcode & 0x0f)
	n := len(payload)
	idx := 2
	switch {
	case n < 126:
		header[1] = 0x80 | byte(n)
	case n <= 65535:
		header[1] = 0x80 | 126
		binary.BigEndian.PutUint16(header[2:4], uint16(n))
		idx = 4
	default:
		header[1] = 0x80 | 127
		binary.BigEndian.PutUint64(header[2:10], uint64(n))
		idx = 10
	}
	var mask [4]byte
	if _, err := rand.Read(mask[:]); err != nil {
		return err
	}
	copy(header[idx:idx+4], mask[:])
	idx += 4

	frame := make([]byte, idx+n)
	copy(frame[:idx], header[:idx])
	for i := range n {
		frame[idx+i] = payload[i] ^ mask[i%4]
	}
	_, err := w.raw.Write(frame)
	return err
}

func (w *wsConn) readMessage() ([]byte, error) {
	var msg []byte
	for {
		var hdr [2]byte
		if _, err := io.ReadFull(w.br, hdr[:]); err != nil {
			return nil, err
		}
		fin := (hdr[0] & 0x80) != 0
		opcode := hdr[0] & 0x0f
		masked := (hdr[1] & 0x80) != 0
		length := uint64(hdr[1] & 0x7f)

		switch length {
		case 126:
			var ext [2]byte
			if _, err := io.ReadFull(w.br, ext[:]); err != nil {
				return nil, err
			}
			length = uint64(binary.BigEndian.Uint16(ext[:]))
		case 127:
			var ext [8]byte
			if _, err := io.ReadFull(w.br, ext[:]); err != nil {
				return nil, err
			}
			length = binary.BigEndian.Uint64(ext[:])
		}

		var mask [4]byte
		if masked {
			if _, err := io.ReadFull(w.br, mask[:]); err != nil {
				return nil, err
			}
		}

		payload := make([]byte, length)
		if _, err := io.ReadFull(w.br, payload); err != nil {
			return nil, err
		}
		if masked {
			for i := range payload {
				payload[i] ^= mask[i%4]
			}
		}

		switch opcode {
		case 0x8:
			return nil, io.EOF
		case 0x9:
			_ = w.writeFrame(0xa, payload)
			continue
		case 0xa:
			continue
		case 0x1, 0x2, 0x0:
			msg = append(msg, payload...)
			if fin {
				return msg, nil
			}
		}
	}
}

func (w *wsConn) call(ctx context.Context, id int64, method string, params map[string]any) (json.RawMessage, error) {
	if dl, ok := ctx.Deadline(); ok {
		_ = w.raw.SetDeadline(dl)
	}
	reqObj := map[string]any{
		"id":     id,
		"method": method,
	}
	if params != nil {
		reqObj["params"] = params
	}
	reqBytes, err := json.Marshal(reqObj)
	if err != nil {
		return nil, err
	}
	if err := w.writeFrame(0x1, reqBytes); err != nil {
		return nil, err
	}

	for {
		raw, err := w.readMessage()
		if err != nil {
			return nil, err
		}
		var env struct {
			ID     int64           `json:"id"`
			Result json.RawMessage `json:"result"`
			Error  *struct {
				Code    int    `json:"code"`
				Message string `json:"message"`
			} `json:"error"`
		}
		if err := json.Unmarshal(raw, &env); err != nil {
			continue
		}
		if env.ID != id {
			// Skip asynchronous CDP events.
			continue
		}
		if env.Error != nil {
			return nil, fmt.Errorf("CDP error %d: %s", env.Error.Code, env.Error.Message)
		}
		return env.Result, nil
	}
}
