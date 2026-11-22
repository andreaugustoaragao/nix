package chatsend

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

type fakeBrowser struct {
	t          *testing.T
	dom        map[string]any
	taskID     string
	label      string
	pages      map[string]any
	state      string
	actions    []map[string]any
	screenshot string
	onAction   func(action map[string]any, fb *fakeBrowser)
}

func newFakeBrowser(t *testing.T, dir string) *fakeBrowser {
	t.Helper()
	shot := filepath.Join(dir, "shot.png")
	if err := os.WriteFile(shot, []byte("PNGDATA"), 0o600); err != nil {
		t.Fatal(err)
	}
	return &fakeBrowser{
		t:          t,
		taskID:     "task-1234",
		pages:      map[string]any{"main": "PAGE-1"},
		state:      "active",
		screenshot: shot,
		dom: map[string]any{
			"version":              1,
			"url":                  "https://chat.google.com/app/chat/EXAMPLE",
			"title":                "Example Person - Chat",
			"accounts":             []any{"Google Account: Andre Aragao (aragao@avaya.com)"},
			"editors":              []any{map[string]any{"name": "History is on", "text": "", "blocks": []any{}, "mentions": []any{}, "forbidden": false, "signature_list": false, "signature_plain": true}},
			"file_input_count":     1,
			"composer_boundary":    "supported",
			"composer_attachments": []any{},
			"send_count":           1,
			"send_enabled":         false,
			"send_focused":         false,
			"editor_focused":       false,
			"caret_at_plain_end":   false,
			"dialogs":              0,
			"options":              []any{},
			"message_ids":          []any{"msg-0"},
			"identities":           []any{map[string]any{"message_id": "msg-0", "email": "aragao@avaya.com"}},
			"messages": []any{
				map[string]any{
					"id":          "msg-0",
					"sender_id":   "sender-1",
					"body_count":  1,
					"local_only":  "false",
					"pending":     false,
					"error":       false,
					"server":      true,
					"attachments": []any{},
					"body":        map[string]any{"text": "prev", "blocks": []any{map[string]any{"type": "text", "text": "prev"}}, "mentions": []any{}, "forbidden": false, "signature_list": false, "signature_plain": true},
				},
			},
			"publication_supported": true,
			"truncated":             false,
		},
	}
}

func (f *fakeBrowser) Run(args []string, input []byte, _ time.Duration) ([]byte, error) {
	if len(args) == 0 {
		return nil, Stop("browser_command_failed")
	}
	switch args[0] {
	case "start":
		for i := range args {
			if args[i] == "--label" && i+1 < len(args) {
				f.label = args[i+1]
			}
		}
		f.state = "active"
		return Encode(map[string]any{"task": f.taskID, "pages": f.pages})
	case "info":
		return Encode(map[string]any{
			"task":    f.taskID,
			"profile": "accounts",
			"label":   f.label,
			"pages":   f.pages,
			"state":   f.state,
		})
	case "keep":
		f.state = "kept"
		return Encode(map[string]any{"ok": true})
	case "resume":
		f.state = "active"
		return Encode(map[string]any{"ok": true})
	case "finish":
		f.state = "finished"
		return Encode(map[string]any{"ok": true})
	case "action":
		var act map[string]any
		dec := json.NewDecoder(bytes.NewReader(input))
		dec.UseNumber()
		if err := dec.Decode(&act); err != nil {
			return nil, err
		}
		f.actions = append(f.actions, act)
		if f.onAction != nil {
			f.onAction(act, f)
		}
		kind, _ := act["type"].(string)
		switch kind {
		case "evaluate":
			return Encode(map[string]any{"value": f.dom})
		case "screenshot":
			return Encode(map[string]any{"path": f.screenshot})
		case "fill":
			txt, _ := act["text"].(string)
			ed := f.dom["editors"].([]any)[0].(map[string]any)
			ed["text"] = txt
			if txt == "" {
				ed["blocks"] = []any{}
				f.dom["send_enabled"] = false
			} else {
				ed["blocks"] = []any{map[string]any{"type": "text", "text": txt}}
				f.dom["send_enabled"] = true
			}
			return Encode(map[string]any{"ok": true})
		case "upload":
			files, _ := act["files"].([]any)
			atts := make([]any, 0, len(files))
			for _, raw := range files {
				p, _ := raw.(string)
				atts = append(atts, map[string]any{
					"name":      filepath.Base(p),
					"pending":   false,
					"error":     false,
					"removable": true,
				})
			}
			f.dom["composer_attachments"] = atts
			f.dom["send_enabled"] = true
			return Encode(map[string]any{"ok": true, "count": len(files)})
		case "click":
			target, _ := act["target"].(map[string]any)
			name, _ := target["name"].(string)
			if strings.HasPrefix(name, "Remove ") {
				rmName := strings.TrimPrefix(name, "Remove ")
				cur, _ := f.dom["composer_attachments"].([]any)
				next := make([]any, 0, len(cur))
				for _, raw := range cur {
					m, _ := raw.(map[string]any)
					if m["name"] != rmName {
						next = append(next, m)
					}
				}
				f.dom["composer_attachments"] = next
			} else if target["role"] == "textbox" {
				f.dom["editor_focused"] = true
			}
			return Encode(map[string]any{"ok": true})
		case "key":
			k, _ := act["key"].(string)
			switch k {
			case "Control+End":
				f.dom["editor_focused"] = true
				f.dom["caret_at_plain_end"] = true
			case "Tab":
				f.dom["editor_focused"] = false
				f.dom["send_focused"] = true
			case "Space":
				// Simulate publishing message + clearing composer.
				ed := f.dom["editors"].([]any)[0].(map[string]any)
				sentBody := map[string]any{
					"text":            ed["text"],
					"blocks":          ed["blocks"],
					"mentions":        []any{},
					"forbidden":       false,
					"signature_list":  false,
					"signature_plain": true,
				}
				curAtts, _ := f.dom["composer_attachments"].([]any)
				pubAtts := make([]any, 0, len(curAtts))
				for _, raw := range curAtts {
					m, _ := raw.(map[string]any)
					pubAtts = append(pubAtts, map[string]any{
						"name":    m["name"],
						"pending": false,
						"error":   false,
					})
				}
				ed["text"] = ""
				ed["blocks"] = []any{}
				f.dom["composer_attachments"] = []any{}
				f.dom["send_enabled"] = false
				f.dom["message_ids"] = append(f.dom["message_ids"].([]any), "msg-1")
				f.dom["messages"] = append(f.dom["messages"].([]any), map[string]any{
					"id":          "msg-1",
					"sender_id":   "sender-1",
					"body_count":  1,
					"topic_id":    "topic-1",
					"local_only":  "false",
					"pending":     false,
					"error":       false,
					"server":      true,
					"attachments": pubAtts,
					"body":        sentBody,
				})
			}
			return Encode(map[string]any{"ok": true})
		default:
			return Encode(map[string]any{"ok": true})
		}
	default:
		return nil, Stop("browser_command_failed")
	}
}

func setupRoutesAndMsg(t *testing.T, dir string, msg map[string]any) (string, string, string) {
	t.Helper()
	routesPath := filepath.Join(dir, "routes.json")
	routes := map[string]any{
		"version": 1,
		"routes": map[string]any{
			"example": map[string]any{
				"url":           "https://chat.google.com/app/chat/EXAMPLE",
				"title":         "Example Person - Chat",
				"account":       "aragao@avaya.com",
				"account_label": "Google Account: Andre Aragao  \n(aragao@avaya.com)",
			},
		},
	}
	if err := AtomicWriteJSON(routesPath, routes); err != nil {
		t.Fatal(err)
	}
	msgPath := filepath.Join(dir, "msg.json")
	if err := AtomicWriteJSON(msgPath, msg); err != nil {
		t.Fatal(err)
	}
	stateDir := filepath.Join(dir, "state")
	return routesPath, msgPath, stateDir
}

func TestTextOnlyPreviewSendAndCancel(t *testing.T) {
	dir := t.TempDir()
	routes, msg, state := setupRoutesAndMsg(t, dir, map[string]any{
		"version":      1,
		"operation_id": "op-text-1",
		"blocks":       []any{map[string]any{"type": "text", "text": "Hello from Go"}},
	})
	fb := newFakeBrowser(t, dir)

	res := Run(Options{Route: "example", Message: msg, RoutesFile: routes, StateDir: state, Runner: fb, FastTests: true})
	if res["outcome"] != "preview" || res["reason"] != "ready_for_review" {
		t.Fatalf("unexpected preview result: %+v", res)
	}

	// Status should not mutate.
	st := Run(Options{Mode: "status", Operation: "op-text-1", RoutesFile: routes, StateDir: state, Runner: fb, FastTests: true})
	if st["outcome"] != "preview" || st["reason"] != "ready_for_review" {
		t.Fatalf("unexpected status result: %+v", st)
	}

	// Send with the same operation ID.
	sent := Run(Options{Route: "example", Message: msg, Send: true, Operation: "op-text-1", RoutesFile: routes, StateDir: state, Runner: fb, FastTests: true})
	if sent["outcome"] != "sent" || sent["reason"] != "publication_confirmed" {
		t.Fatalf("unexpected send result: %+v", sent)
	}
}

func TestAttachmentPreviewCancelAndSend(t *testing.T) {
	dir := t.TempDir()
	notePath := filepath.Join(dir, "report.md")
	if err := os.WriteFile(notePath, []byte("# Report\nhello\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	routes, msg, state := setupRoutesAndMsg(t, dir, map[string]any{
		"version":      1,
		"operation_id": "op-att-cancel",
		"blocks":       []any{map[string]any{"type": "text", "text": "Attached report"}},
	})
	fb := newFakeBrowser(t, dir)

	prev := Run(Options{Route: "example", Message: msg, Attach: []string{notePath}, RoutesFile: routes, StateDir: state, Runner: fb, FastTests: true})
	if prev["outcome"] != "preview" || prev["reason"] != "ready_for_review" {
		t.Fatalf("attachment preview failed: %+v", prev)
	}

	cancelled := Run(Options{Mode: "cancel", Operation: "op-att-cancel", RoutesFile: routes, StateDir: state, Runner: fb, FastTests: true})
	if cancelled["outcome"] != "preview" || cancelled["reason"] != "cancelled" {
		t.Fatalf("attachment cancel failed: %+v", cancelled)
	}

	// New operation: full send with attachment confirmation.
	msg2Path := filepath.Join(dir, "msg2.json")
	if err := AtomicWriteJSON(msg2Path, map[string]any{
		"version":      1,
		"operation_id": "op-att-send",
		"blocks":       []any{map[string]any{"type": "text", "text": "Sending report"}},
	}); err != nil {
		t.Fatal(err)
	}
	fb2 := newFakeBrowser(t, dir)
	sent := Run(Options{Route: "example", Message: msg2Path, Attach: []string{notePath}, Send: true, Operation: "op-att-send", RoutesFile: routes, StateDir: state, Runner: fb2, FastTests: true})
	if sent["outcome"] != "sent" || sent["reason"] != "publication_confirmed" {
		t.Fatalf("attachment send failed: %+v", sent)
	}
}

func TestMultiFileRejectedBeforeBrowserMutation(t *testing.T) {
	dir := t.TempDir()
	notePath := filepath.Join(dir, "first.md")
	note2Path := filepath.Join(dir, "second.pdf")
	if err := os.WriteFile(notePath, []byte("# first\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(note2Path, []byte("%PDF-1.4\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	routes, msg, state := setupRoutesAndMsg(t, dir, map[string]any{
		"version":      1,
		"operation_id": "op-att-multi",
		"blocks":       []any{map[string]any{"type": "text", "text": "Two files"}},
	})
	fbMulti := newFakeBrowser(t, dir)
	multiRes := Run(Options{Route: "example", Message: msg, Attach: []string{notePath, note2Path}, Operation: "op-att-multi", RoutesFile: routes, StateDir: state, Runner: fbMulti, FastTests: true})
	if multiRes["outcome"] != "failed" || multiRes["reason"] != "invalid_attachments" {
		t.Fatalf("expected invalid_attachments for >1 file, got: %+v", multiRes)
	}
	if len(fbMulti.actions) != 0 {
		t.Fatalf("multi-file rejection must not invoke browser actions, got %d", len(fbMulti.actions))
	}
}

func TestPublishedAttachmentNullOrMissingNeverConfirms(t *testing.T) {
	dir := t.TempDir()
	op, err := NewOperation(dir, "op-pub-check", nil, "", true)
	if err != nil {
		t.Fatal(err)
	}
	op.Record["request"] = map[string]any{
		"attachments": []any{map[string]any{"name": "report.md"}},
	}
	if op.PublishedAttachments(map[string]any{}) {
		t.Fatal("missing attachments key must not confirm")
	}
	if op.PublishedAttachments(map[string]any{"attachments": nil}) {
		t.Fatal("null attachments must not confirm")
	}
	if op.PublishedAttachments(map[string]any{"attachments": []any{map[string]any{"name": "report.md", "pending": true, "error": false}}}) {
		t.Fatal("pending attachment must not confirm")
	}
	if op.PublishedAttachments(map[string]any{"attachments": []any{map[string]any{"name": "report.md", "pending": false, "error": true}}}) {
		t.Fatal("errored attachment must not confirm")
	}
	if !op.PublishedAttachments(map[string]any{"attachments": []any{map[string]any{"name": "report.md", "pending": false, "error": false}}}) {
		t.Fatal("settled matching attachment must confirm")
	}
	// Text-only must also reject null or missing attachments.
	op.Record["request"] = map[string]any{}
	if op.PublishedAttachments(map[string]any{}) || op.PublishedAttachments(map[string]any{"attachments": nil}) {
		t.Fatal("text-only must reject missing or null attachments")
	}
	if !op.PublishedAttachments(map[string]any{"attachments": []any{}}) {
		t.Fatal("text-only must accept empty attachments list")
	}
}

func TestRefreshPublicationEnforcesPersistedReloadCap(t *testing.T) {
	dir := t.TempDir()
	routes, msg, state := setupRoutesAndMsg(t, dir, map[string]any{
		"version":      1,
		"operation_id": "op-reload-cap",
		"blocks":       []any{map[string]any{"type": "text", "text": "Local only test"}},
	})
	fb := newFakeBrowser(t, dir)
	// Create initial preview so receipt + task exist, then simulate send_attempted with a local-only message.
	prev := Run(Options{Route: "example", Message: msg, RoutesFile: routes, StateDir: state, Runner: fb, FastTests: true})
	if prev["outcome"] != "preview" {
		t.Fatalf("setup preview failed: %+v", prev)
	}
	receiptPath := filepath.Join(state, "op-reload-cap", "receipt.json")
	rec, err := ReadJSON(receiptPath, true)
	if err != nil {
		t.Fatal(err)
	}
	rec["send_attempted"] = true
	rec["baseline_ids"] = []any{"msg-0"}
	rec["sender_id"] = "sender-1"
	rec["outcome"] = "uncertain"
	rec["reason"] = "send_attempt_recorded"
	if err := AtomicWriteJSON(receiptPath, rec); err != nil {
		t.Fatal(err)
	}
	// Empty composer + one new matching local-only message that stays local-only even after reload.
	ed := fb.dom["editors"].([]any)[0].(map[string]any)
	ed["text"] = ""
	ed["blocks"] = []any{}
	fb.dom["message_ids"] = []any{"msg-0", "msg-local"}
	fb.dom["messages"] = append(fb.dom["messages"].([]any), map[string]any{
		"id":          "msg-local",
		"sender_id":   "sender-1",
		"body_count":  1,
		"topic_id":    "topic-1",
		"local_only":  "true",
		"pending":     false,
		"error":       false,
		"server":      false,
		"attachments": []any{},
		"body": map[string]any{
			"text":            "Local only test\n\n" + Marker + Signature,
			"blocks":          []any{map[string]any{"type": "text", "text": "Local only test\n\n" + Marker + Signature}},
			"mentions":        []any{},
			"forbidden":       false,
			"signature_list":  false,
			"signature_plain": true,
		},
	})

	countNav := func() int {
		n := 0
		for _, a := range fb.actions {
			if a["type"] == "navigate" {
				n++
			}
		}
		return n
	}

	st1 := Run(Options{Mode: "status", Operation: "op-reload-cap", RoutesFile: routes, StateDir: state, Runner: fb, FastTests: true})
	if st1["outcome"] != "uncertain" || st1["reason"] != "publication_not_confirmed" {
		t.Fatalf("expected uncertain publication_not_confirmed on status 1, got %+v", st1)
	}
	if navs := countNav(); navs != 1 {
		t.Fatalf("expected exactly 1 reload navigate on first status, got %d", navs)
	}

	// Second separate status call must NOT navigate/reload a second time.
	st2 := Run(Options{Mode: "status", Operation: "op-reload-cap", RoutesFile: routes, StateDir: state, Runner: fb, FastTests: true})
	if st2["outcome"] != "uncertain" || st2["reason"] != "publication_not_confirmed" {
		t.Fatalf("expected uncertain publication_not_confirmed on status 2, got %+v", st2)
	}
	if navs := countNav(); navs != 1 {
		t.Fatalf("expected persisted reload cap to block second navigate, got %d", navs)
	}
}

func TestLargeEscapedReceiptRoundTrips(t *testing.T) {
	dir := t.TempDir()
	tabs := strings.Repeat("\t", 26000)
	routes, msg, state := setupRoutesAndMsg(t, dir, map[string]any{
		"version":      1,
		"operation_id": "op-26k-tabs",
		"blocks":       []any{map[string]any{"type": "code", "text": tabs}},
	})
	fb := newFakeBrowser(t, dir)
	fb.onAction = func(act map[string]any, f *fakeBrowser) {
		if act["type"] == "evaluate" {
			ed := f.dom["editors"].([]any)[0].(map[string]any)
			if txt, _ := ed["text"].(string); strings.HasPrefix(txt, "```") {
				ed["blocks"] = []any{
					map[string]any{"type": "code", "text": tabs},
					map[string]any{"type": "text", "text": Marker + Signature},
				}
			}
		}
	}
	prev := Run(Options{Route: "example", Message: msg, RoutesFile: routes, StateDir: state, Runner: fb, FastTests: true})
	if prev["outcome"] != "preview" || prev["reason"] != "ready_for_review" {
		t.Fatalf("26k-tab preview failed: %+v", prev)
	}
	// Verify receipt actually exceeds 128 KiB JSON ceiling and still reopens cleanly for status and cancel.
	info, err := os.Stat(filepath.Join(state, "op-26k-tabs", "receipt.json"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Size() <= MaxJSONBytes {
		t.Fatalf("expected escaped receipt > %d bytes, got %d", MaxJSONBytes, info.Size())
	}
	st := Run(Options{Mode: "status", Operation: "op-26k-tabs", RoutesFile: routes, StateDir: state, Runner: fb, FastTests: true})
	if st["outcome"] != "preview" || st["reason"] != "ready_for_review" {
		t.Fatalf("26k-tab status failed to reopen receipt: %+v", st)
	}
	can := Run(Options{Mode: "cancel", Operation: "op-26k-tabs", RoutesFile: routes, StateDir: state, Runner: fb, FastTests: true})
	if can["outcome"] != "preview" || can["reason"] != "cancelled" {
		t.Fatalf("26k-tab cancel failed to reopen receipt: %+v", can)
	}
}

func TestExecBrowserRunnerHandlesLargeProbeStdout(t *testing.T) {
	dir := t.TempDir()
	shPath, err := exec.LookPath("sh")
	if err != nil {
		t.Fatalf("sh not found: %v", err)
	}
	script := filepath.Join(dir, "fake-browser-task.sh")
	// Emit a >200 KiB valid JSON stdout payload (exceeding the 128 KiB user-input cap).
	body := "#!" + shPath + "\nprintf '{\"value\":{\"pad\":\"'\nhead -c 204800 /dev/zero | tr '\\0' 'a'\nprintf '\"}}\\n'\n"
	if err := os.WriteFile(script, []byte(body), 0o700); err != nil {
		t.Fatal(err)
	}
	out, err := ExecBrowserRunner{Binary: script}.Run([]string{"action"}, nil, 5*time.Second)
	if err != nil {
		t.Fatalf("ExecBrowserRunner failed on >128 KiB probe output: %v", err)
	}
	if len(out) <= MaxJSONBytes {
		t.Fatalf("expected >%d bytes stdout, got %d", MaxJSONBytes, len(out))
	}
}

func TestStageAttachmentRejectsSymlinkAndFIFO(t *testing.T) {
	dir := t.TempDir()
	realFile := filepath.Join(dir, "real.txt")
	if err := os.WriteFile(realFile, []byte("hello"), 0o600); err != nil {
		t.Fatal(err)
	}
	linkPath := filepath.Join(dir, "link.txt")
	if err := os.Symlink(realFile, linkPath); err != nil {
		t.Fatal(err)
	}
	if _, err := StageAttachment(linkPath, filepath.Join(dir, "out", "link.txt")); err == nil {
		t.Fatal("symlink attachment must be rejected")
	}
	fifoPath := filepath.Join(dir, "pipe.txt")
	if err := syscall.Mkfifo(fifoPath, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := StageAttachment(fifoPath, filepath.Join(dir, "out", "pipe.txt")); err == nil {
		t.Fatal("FIFO attachment must be rejected")
	}
}

func TestEmbeddedDomProbeMatchesSkillScript(t *testing.T) {
	skillProbe := filepath.Join("..", "..", "..", "..", "home", "cli", "chat-send", "scripts", "dom_probe.js")
	raw, err := os.ReadFile(skillProbe)
	if err != nil {
		t.Skip("skill dom_probe.js not adjacent (sandbox build)")
	}
	if string(raw) != DefaultProbeScript {
		t.Fatal("embedded dom_probe.js drifted from home/cli/chat-send/scripts/dom_probe.js")
	}
}

func TestRealDomProbeThroughGoSender(t *testing.T) {
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("node not available in PATH")
	}
	script := `
const vm = require("node:vm");
const source = process.env.PROBE_SRC;
const make = (tag, attrs = {}, parent = null) => {
  const node = {
    tagName: tag, parentElement: parent, childNodes: [],
    getAttribute: k => Object.hasOwn(attrs, k) ? attrs[k] : null,
    getAttributeNames: () => Object.keys(attrs).filter(k => attrs[k] != null),
    getClientRects: () => [{x: 10, y: 10, width: 40, height: 20}],
    contains(other) { for (let c = other; c; c = c.parentElement) if (c === node) return true; return false; },
    closest(sel) { for (let c = node; c; c = c.parentElement) if (c.matches(sel)) return c; return null; },
    matches(sel) {
      return sel.split(',').some(part => {
        const s = part.trim();
        if (s === '*') return true;
        if (s === 'button') return tag === 'BUTTON';
        if (s === '[role="button"]') return attrs.role === 'button';
        if (s === '[aria-label]') return attrs['aria-label'] != null;
        if (s === '[role="textbox"][contenteditable="true"]') return attrs.role === 'textbox' && attrs.contenteditable === 'true';
        if (s === 'input[type="file"]') return tag === 'INPUT' && attrs.type === 'file';
        if (s === '[jsname="BThTkd"]') return attrs.jsname === 'BThTkd';
        if (s === '[jsname="XPtOyb"]') return attrs.jsname === 'XPtOyb';
        if (s === '[jsname="ua35De"]') return attrs.jsname === 'ua35De';
        if (s === '[title]') return attrs.title != null;
        return false;
      });
    },
    querySelectorAll(sel) {
      const out = [];
      const walk = n => { for (const ch of n.childNodes) { if (ch.matches(sel)) out.push(ch); walk(ch); } };
      walk(node);
      return out;
    },
    querySelector(sel) { return node.querySelectorAll(sel)[0] || null; }
  };
  if (parent) parent.childNodes.push(node);
  return node;
};
const doc = make('DOCUMENT', {});
doc.title = 'Example Person - Chat';
doc.defaultView = {}; doc.defaultView.top = doc.defaultView;
make('DIV', {'aria-label': 'Google Account: Andre Aragao  \n(aragao@avaya.com)'}, doc);
const boundary = make('DIV', {jsname: 'ZQsur'}, doc);
make('DIV', {role: 'textbox', contenteditable: 'true', 'aria-label': 'History is on'}, boundary);
const input = make('INPUT', {type: 'file', role: 'button'}, boundary);
input.isConnected = true; input.ownerDocument = doc;
make('BUTTON', {'aria-label': 'Send message'}, boundary);
const shelf = make('DIV', {jsname: 'qaclne', jscontroller: 'WCjcW'}, boundary);
const card = make('DIV', {jsname: 'BThTkd'}, shelf);
make('DIV', {jsname: 'XPtOyb', title: 'report.pdf', 'aria-label': 'report.pdf, PDF.'}, card);
make('BUTTON', {jsname: 'ua35De', jscontroller: 'PIVayb', 'aria-label': 'Remove report.pdf'}, card);
const out = vm.runInNewContext(source, {
  document: doc, top: doc.defaultView, location: {href: 'https://chat.google.com/app/chat/EXAMPLE'},
  innerWidth: 1440, innerHeight: 1000, Node: {TEXT_NODE: 3, ELEMENT_NODE: 1}, TextEncoder,
  getComputedStyle: () => ({visibility: 'visible'})
});
process.stdout.write(JSON.stringify(out));
`
	cmd := exec.Command("node", "-e", script)
	cmd.Env = append(os.Environ(), "PROBE_SRC="+DefaultProbeScript)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("node dom_probe failed: %v", err)
	}
	var dom map[string]any
	dec := json.NewDecoder(bytes.NewReader(out))
	dec.UseNumber()
	if err := dec.Decode(&dom); err != nil {
		t.Fatalf("decode dom: %v", err)
	}

	dir := t.TempDir()
	fb := newFakeBrowser(t, dir)
	fb.dom = dom
	routes, msg, state := setupRoutesAndMsg(t, dir, map[string]any{
		"version":      1,
		"operation_id": "op-real-probe",
		"blocks":       []any{map[string]any{"type": "text", "text": "hello"}},
	})
	route, err := RouteConfig(routes, "example")
	if err != nil {
		t.Fatal(err)
	}
	_, _, _, _, err = PayloadParts(msg, nil)
	if err != nil {
		t.Fatal(err)
	}
	op, err := NewOperation(state, "op-real-probe", fb, "", true)
	if err != nil {
		t.Fatal(err)
	}
	op.Record["request"] = map[string]any{"route": route}
	checked, err := op.Checked()
	if err != nil {
		t.Fatalf("real dom_probe.js failed Checked(): %v", err)
	}
	atts, _ := asSlice(checked["composer_attachments"])
	if len(atts) != 1 || atts[0].(map[string]any)["name"] != "report.pdf" {
		t.Fatalf("unexpected composer_attachments from real dom_probe.js: %+v", atts)
	}
}
