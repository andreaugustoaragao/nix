package gmail

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"email-send/internal/browser"
	"email-send/internal/cdp"
)

// AttachmentSpec describes a local file to attach and an optional display filename.
type AttachmentSpec struct {
	SourcePath  string
	DisplayName string
}

// AttachmentReceipt records exact uploaded file metadata.
type AttachmentReceipt struct {
	Name       string `json:"name"`
	SourcePath string `json:"source_path"`
	Bytes      int64  `json:"bytes"`
	SHA256     string `json:"sha256"`
}

// SendRequest specifies one deterministic Gmail compose/send operation.
type SendRequest struct {
	Account     string
	To          []string
	CC          []string
	BCC         []string
	Subject     string
	Body        string
	Attachments []AttachmentSpec
	Send        bool
	KeepDraft   bool
	CDPPort     int
	OperationID string
	// BeforeSend runs immediately before clicking Gmail Send (used to persist dispatching state).
	BeforeSend func() error
}

// Receipt is the machine-readable result emitted to stdout.
type Receipt struct {
	Status          string              `json:"status"`
	OperationID     string              `json:"operation_id,omitempty"`
	Account         string              `json:"account"`
	To              []string            `json:"to"`
	CC              []string            `json:"cc,omitempty"`
	BCC             []string            `json:"bcc,omitempty"`
	Subject         string              `json:"subject"`
	Body            string              `json:"body"`
	Attachments     []AttachmentReceipt `json:"attachments,omitempty"`
	VerifiedInSent  bool                `json:"verified_in_sent"`
	SentMessageID   string              `json:"sent_message_id,omitempty"`
	SentMessageURL  string              `json:"sent_message_url,omitempty"`
	SentRowPreview  string              `json:"sent_row_preview,omitempty"`
	SentAtUTC       string              `json:"sent_at_utc,omitempty"`
	ElapsedMS       int64               `json:"elapsed_ms"`
}

// ParseAttachmentSpec parses "path" or "path:displayname".
func ParseAttachmentSpec(raw string) (AttachmentSpec, error) {
	s := strings.TrimSpace(raw)
	if s == "" {
		return AttachmentSpec{}, fmt.Errorf("empty attachment path")
	}
	// If the literal path exists, treat the whole string as SourcePath.
	if _, err := os.Stat(s); err == nil {
		return AttachmentSpec{SourcePath: s, DisplayName: filepath.Base(s)}, nil
	}
	// Otherwise support "source_path:display_name" where display_name has no path separators.
	if idx := strings.LastIndex(s, ":"); idx > 0 {
		src := s[:idx]
		name := strings.TrimSpace(s[idx+1:])
		if name != "" && !strings.ContainsAny(name, `/\`) {
			if _, err := os.Stat(src); err == nil {
				return AttachmentSpec{SourcePath: src, DisplayName: name}, nil
			}
		}
	}
	return AttachmentSpec{}, fmt.Errorf("attachment not found: %s", raw)
}

func stageAttachments(specs []AttachmentSpec) ([]string, []AttachmentReceipt, func(), error) {
	if len(specs) == 0 {
		return nil, nil, func() {}, nil
	}
	tmpDir, err := os.MkdirTemp("", "email-send-attach-*")
	if err != nil {
		return nil, nil, func() {}, fmt.Errorf("create attachment stage dir: %w", err)
	}
	cleanup := func() { _ = os.RemoveAll(tmpDir) }

	paths := make([]string, 0, len(specs))
	receipts := make([]AttachmentReceipt, 0, len(specs))
	seenNames := make(map[string]int)

	for _, spec := range specs {
		absSrc, err := filepath.Abs(spec.SourcePath)
		if err != nil {
			cleanup()
			return nil, nil, func() {}, fmt.Errorf("abs path %s: %w", spec.SourcePath, err)
		}
		info, err := os.Stat(absSrc)
		if err != nil {
			cleanup()
			return nil, nil, func() {}, fmt.Errorf("stat attachment %s: %w", absSrc, err)
		}
		if info.IsDir() || info.Size() == 0 {
			cleanup()
			return nil, nil, func() {}, fmt.Errorf("attachment %s must be a non-empty regular file", absSrc)
		}
		name := spec.DisplayName
		if name == "" {
			name = filepath.Base(absSrc)
		}
		if seenNames[name] > 0 {
			ext := filepath.Ext(name)
			base := strings.TrimSuffix(name, ext)
			name = fmt.Sprintf("%s-%d%s", base, seenNames[name]+1, ext)
		}
		seenNames[spec.DisplayName]++

		dst := filepath.Join(tmpDir, name)
		sum, n, err := copyAndHash(absSrc, dst)
		if err != nil {
			cleanup()
			return nil, nil, func() {}, err
		}
		paths = append(paths, dst)
		receipts = append(receipts, AttachmentReceipt{
			Name:       name,
			SourcePath: absSrc,
			Bytes:      n,
			SHA256:     sum,
		})
	}
	return paths, receipts, cleanup, nil
}

func copyAndHash(src, dst string) (string, int64, error) {
	in, err := os.Open(src)
	if err != nil {
		return "", 0, fmt.Errorf("open %s: %w", src, err)
	}
	defer in.Close()

	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return "", 0, fmt.Errorf("create staged file %s: %w", dst, err)
	}
	defer out.Close()

	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(out, h), in)
	if err != nil {
		return "", 0, fmt.Errorf("stage attachment %s: %w", src, err)
	}
	if err := out.Close(); err != nil {
		return "", 0, err
	}
	return hex.EncodeToString(h.Sum(nil)), n, nil
}

// Execute runs the end-to-end deterministic Gmail compose, attach, optional send, and verification flow.
func Execute(ctx context.Context, client *browser.Client, req SendRequest) (*Receipt, error) {
	started := time.Now()
	if len(req.To) == 0 {
		return nil, fmt.Errorf("at least one --to recipient is required")
	}
	if strings.TrimSpace(req.Subject) == "" {
		return nil, fmt.Errorf("--subject is required")
	}
	if strings.TrimSpace(req.Body) == "" {
		return nil, fmt.Errorf("--body or --body-file is required")
	}

	stagedPaths, attachReceipts, cleanupStage, err := stageAttachments(req.Attachments)
	if err != nil {
		return nil, err
	}
	defer cleanupStage()

	const page = "main"
	_, targetID, err := client.Start(ctx, "email-send", "https://mail.google.com/mail/u/0/#inbox")
	if err != nil {
		return nil, err
	}
	defer func() { _ = client.Finish() }()

	if err := client.Viewport(ctx, page, 1280, 900); err != nil {
		return nil, fmt.Errorf("set viewport: %w", err)
	}

	// Wait for Gmail shell + Compose button to load.
	if err := client.WaitForCondition(ctx, page,
		`Boolean(document.querySelector('div[role="button"][gh="cm"], [role="button"]')) && (document.title || '').includes('@')`,
		25*time.Second); err != nil {
		return nil, fmt.Errorf("wait for Gmail inbox: %w", err)
	}

	// Fail closed unless active Google account matches expected email.
	var acctInfo struct {
		Title   string `json:"title"`
		Account string `json:"account"`
		URL     string `json:"url"`
	}
	if err := client.Evaluate(ctx, page, `({
		title: document.title || '',
		account: document.querySelector('a[aria-label*="@"]')?.getAttribute('aria-label') || '',
		url: location.href
	})`, &acctInfo); err != nil {
		return nil, fmt.Errorf("verify Gmail account: %w", err)
	}
	if req.Account != "" {
		want := strings.ToLower(req.Account)
		if !strings.Contains(strings.ToLower(acctInfo.Account), want) && !strings.Contains(strings.ToLower(acctInfo.Title), want) {
			return nil, fmt.Errorf("active Gmail account mismatch: want %q, got account=%q title=%q url=%q",
				req.Account, acctInfo.Account, acctInfo.Title, acctInfo.URL)
		}
	}

	// Open a fresh Compose dialog.
	if err := client.ClickRole(ctx, page, "button", "Compose"); err != nil {
		return nil, fmt.Errorf("click Compose: %w", err)
	}
	if err := client.WaitForCondition(ctx, page,
		`Boolean(document.querySelector('div[role="dialog"] input[name="subjectbox"]'))`,
		15*time.Second); err != nil {
		return nil, fmt.Errorf("wait for Compose dialog: %w", err)
	}

	// Expand Compose dialog if Gmail opened it minimized.
	var dlgHeight float64
	if err := client.Evaluate(ctx, page,
		`document.querySelector('div[role="dialog"]')?.getBoundingClientRect().height || 0`, &dlgHeight); err != nil {
		return nil, err
	}
	if dlgHeight < 200 {
		if err := client.ClickRole(ctx, page, "button", "Maximize"); err != nil {
			return nil, fmt.Errorf("maximize Compose dialog: %w", err)
		}
		if err := client.WaitForCondition(ctx, page,
			`(document.querySelector('div[role="dialog"]')?.getBoundingClientRect().height || 0) >= 200`,
			10*time.Second); err != nil {
			return nil, fmt.Errorf("wait for Compose maximize: %w", err)
		}
	}

	// Verify fresh empty draft before filling.
	var preCheck struct {
		Subject string   `json:"subject"`
		Chips   []string `json:"chips"`
	}
	if err := client.Evaluate(ctx, page, `(() => {
		const dlg = document.querySelector('div[role="dialog"]');
		return {
			subject: dlg?.querySelector('input[name="subjectbox"]')?.value || '',
			chips: Array.from(dlg?.querySelectorAll('[data-hovercard-id]') || []).map(e => e.getAttribute('data-hovercard-id') || '')
		};
	})()`, &preCheck); err != nil {
		return nil, err
	}
	if preCheck.Subject != "" || len(preCheck.Chips) > 0 {
		return nil, fmt.Errorf("refusing to reuse non-empty Compose dialog (subject=%q chips=%v)", preCheck.Subject, preCheck.Chips)
	}

	port := req.CDPPort
	if port <= 0 {
		var discErr error
		port, discErr = client.DiscoverCDPPort()
		if discErr != nil {
			return nil, fmt.Errorf("discover CDP port: %w", discErr)
		}
	}

	// Fill To/Cc/Bcc recipients in one continuous CDP session so Gmail never blurs/collapses the input.
	if err := fillRecipients(ctx, port, targetID, "To", req.To); err != nil {
		return nil, err
	}
	if len(req.CC) > 0 {
		if err := fillRecipients(ctx, port, targetID, "Cc", req.CC); err != nil {
			return nil, err
		}
	}
	if len(req.BCC) > 0 {
		if err := fillRecipients(ctx, port, targetID, "Bcc", req.BCC); err != nil {
			return nil, err
		}
	}

	// Fill Subject and Body.
	if err := client.FillRole(ctx, page, "textbox", "Subject", req.Subject); err != nil {
		return nil, fmt.Errorf("fill Subject: %w", err)
	}
	if err := client.FillRole(ctx, page, "textbox", "Message Body", req.Body); err != nil {
		return nil, fmt.Errorf("fill Message Body: %w", err)
	}

	// Upload attachments via CDP DOM.setFileInputFiles on our task-owned page target.
	if len(stagedPaths) > 0 {
		if err := cdp.SetFileInputFiles(ctx, port, targetID, `div[role="dialog"] input[type="file"][name="Filedata"]`, stagedPaths); err != nil {
			return nil, fmt.Errorf("upload attachments: %w", err)
		}
		namesJSON, _ := json.Marshal(attachmentNames(attachReceipts))
		waitAttachExpr := fmt.Sprintf(`(() => {
			const dlg = document.querySelector('div[role="dialog"]');
			if (!dlg) return false;
			if (dlg.querySelector('[role="progressbar"]')) return false;
			const txt = dlg.innerText || '';
			return %s.every(name => txt.includes(name));
		})()`, string(namesJSON))
		if err := client.WaitForCondition(ctx, page, waitAttachExpr, 30*time.Second); err != nil {
			return nil, fmt.Errorf("wait for attachment upload completion: %w", err)
		}
	}

	// Verify composed fields (subject, normalized body, and exact To/Cc/Bcc recipient sets) before preview/send.
	var verified draftSnapshot
	if err := client.Evaluate(ctx, page, `(() => {
		const dlg = document.querySelector('div[role="dialog"]');
		const readChips = (root) => {
			if (!root) return [];
			const seen = new Set();
			for (const el of root.querySelectorAll('[data-hovercard-id]')) {
				const id = (el.getAttribute('data-hovercard-id') || '').trim().toLowerCase();
				if (id) seen.add(id);
			}
			return Array.from(seen);
		};
		const fieldChips = (nameAttr, ariaLabel) => {
			if (!dlg) return [];
			const byName = dlg.querySelector('div[name="' + nameAttr + '"]');
			if (byName) return readChips(byName);
			const inp = dlg.querySelector('input[aria-label="' + ariaLabel + '"]');
			const row = inp ? (inp.closest('div[name]') || inp.closest('tr')) : null;
			return readChips(row);
		};
		return {
			subject: dlg?.querySelector('input[name="subjectbox"]')?.value || '',
			body: (dlg?.querySelector('div[aria-label="Message Body"]')?.innerText || '').trim(),
			to: fieldChips('to', 'To recipients'),
			cc: fieldChips('cc', 'CC recipients'),
			bcc: fieldChips('bcc', 'BCC recipients'),
			all: readChips(dlg)
		};
	})()`, &verified); err != nil {
		return nil, fmt.Errorf("verify composed draft: %w", err)
	}
	if err := verifyDraftState(req, verified); err != nil {
		return nil, err
	}

	receipt := &Receipt{
		OperationID: req.OperationID,
		Account:     req.Account,
		To:          req.To,
		CC:          req.CC,
		BCC:         req.BCC,
		Subject:     req.Subject,
		Body:        req.Body,
		Attachments: attachReceipts,
	}

	if !req.Send {
		if !req.KeepDraft {
			// Discard dry-run draft cleanly so inbox/Drafts stay uncluttered.
			_ = client.Evaluate(ctx, page, `(() => {
				const btn = document.querySelector('div[role="dialog"] div[role="button"][aria-label*="Discard draft"]');
				if (btn) btn.click();
				return Boolean(btn);
			})()`, nil)
			_ = client.WaitForCondition(ctx, page, `!document.querySelector('div[role="dialog"]')`, 5*time.Second)
		}
		receipt.Status = "dry_run"
		receipt.ElapsedMS = time.Since(started).Milliseconds()
		return receipt, nil
	}

	// Dismiss any covering desktop-notification banner (.vh) before clicking Send.
	_ = client.Evaluate(ctx, page, `(() => {
		const close = document.querySelector('.vh [aria-label="Close"], .vh .bBe');
		if (close) close.click();
		return Boolean(close);
	})()`, nil)

	// Persist dispatching state before clicking Send so post-click timeouts never silently retry.
	if req.BeforeSend != nil {
		if err := req.BeforeSend(); err != nil {
			return nil, fmt.Errorf("pre-send state transition failed (Send NOT clicked): %w", err)
		}
	}

	// Trigger Gmail Send button.
	if err := client.ClickRole(ctx, page, "button", "Send"); err != nil {
		return nil, fmt.Errorf("click Send: %w", err)
	}

	// Wait for "Message sent" confirmation and Compose dialog close.
	if err := client.WaitForCondition(ctx, page, `(() => {
		const dlg = document.querySelector('div[role="dialog"]');
		const alerts = Array.from(document.querySelectorAll('[role="alert"], .bAq, .vh'))
			.map(e => (e.innerText || '').trim());
		return !dlg && alerts.some(a => /message sent/i.test(a));
	})()`, 20*time.Second); err != nil {
		return nil, fmt.Errorf("wait for Message sent confirmation: %w", err)
	}
	receipt.SentAtUTC = time.Now().UTC().Format(time.RFC3339)

	// Open the exact freshly sent message via Gmail's "View message" toast link (falling back to #sent top row).
	var clickedViewMsg bool
	_ = client.Evaluate(ctx, page, `(() => {
		const link = document.querySelector('#link_vsm') ||
			Array.from(document.querySelectorAll('[role="alert"] span, [role="alert"] a, .vh span, .vh a'))
				.find(e => /^view message$/i.test((e.innerText || '').trim()));
		if (!link) return false;
		link.click();
		return true;
	})()`, &clickedViewMsg)

	subjJSON, _ := json.Marshal(req.Subject)
	waitOpenedExpr := fmt.Sprintf(`(() => {
		const h = document.querySelector('div[role="main"] h2.hP');
		const msgs = document.querySelectorAll('div[role="main"] [data-message-id]');
		return Boolean(h && (h.innerText || '').trim() === %s && msgs.length > 0);
	})()`, string(subjJSON))

	opened := false
	if clickedViewMsg {
		if err := client.WaitForCondition(ctx, page, waitOpenedExpr, 10*time.Second); err == nil {
			opened = true
		}
	}
	if !opened {
		if err := client.Navigate(ctx, page, "https://mail.google.com/mail/u/0/#sent"); err != nil {
			return nil, fmt.Errorf("navigate to Sent: %w", err)
		}
		waitSentRowExpr := fmt.Sprintf(`(() => {
			const row = document.querySelector('div[role="main"] tr.zA');
			return Boolean(row && (row.innerText || '').includes(%s));
		})()`, string(subjJSON))
		if err := client.WaitForCondition(ctx, page, waitSentRowExpr, 15*time.Second); err != nil {
			return nil, fmt.Errorf("locate top Sent row for subject %q: %w", req.Subject, err)
		}
		var rowClicked bool
		if err := client.Evaluate(ctx, page, fmt.Sprintf(`(() => {
			const row = document.querySelector('div[role="main"] tr.zA');
			if (!row || !(row.innerText || '').includes(%s)) return false;
			row.click();
			return true;
		})()`, string(subjJSON)), &rowClicked); err != nil || !rowClicked {
			return nil, fmt.Errorf("open top Sent row for subject %q: %v", req.Subject, err)
		}
		if err := client.WaitForCondition(ctx, page, waitOpenedExpr, 15*time.Second); err != nil {
			return nil, fmt.Errorf("wait for opened Sent message: %w", err)
		}
	}

	// Wait briefly if Gmail is still rendering attachment cards on the newly opened message.
	if len(attachReceipts) > 0 {
		namesJSON, _ := json.Marshal(attachmentNames(attachReceipts))
		waitAttachCardsExpr := fmt.Sprintf(`(() => {
			const msgs = Array.from(document.querySelectorAll('div[role="main"] [data-message-id]'));
			const msg = msgs[msgs.length - 1];
			if (!msg) return false;
			const found = new Set();
			for (const el of msg.querySelectorAll('[download_url]')) {
				const du = el.getAttribute('download_url') || '';
				const parts = du.split(':');
				if (parts.length >= 3) found.add(decodeURIComponent(parts[1]));
			}
			for (const el of msg.querySelectorAll('span.aV3')) {
				const t = (el.innerText || '').trim();
				if (t) found.add(t);
			}
			return %s.every(n => found.has(n));
		})()`, string(namesJSON))
		_ = client.WaitForCondition(ctx, page, waitAttachCardsExpr, 8*time.Second)
	}

	var sentMsg sentMessageSnapshot
	if err := client.Evaluate(ctx, page, `(() => {
		const msgs = Array.from(document.querySelectorAll('div[role="main"] [data-message-id]'));
		const msg = msgs[msgs.length - 1];
		const subject = (document.querySelector('div[role="main"] h2.hP')?.innerText || '').trim();
		if (!msg) return {url: location.href, subject};
		const recipSet = new Set();
		for (const el of msg.querySelectorAll('[email]')) {
			const addr = (el.getAttribute('email') || '').trim().toLowerCase();
			if (addr) recipSet.add(addr);
		}
		const attachSet = new Set();
		for (const el of msg.querySelectorAll('[download_url]')) {
			const du = el.getAttribute('download_url') || '';
			const parts = du.split(':');
			if (parts.length >= 3 && parts[1]) attachSet.add(decodeURIComponent(parts[1]));
		}
		for (const el of msg.querySelectorAll('span.aV3')) {
			const t = (el.innerText || '').trim();
			if (t) attachSet.add(t);
		}
		return {
			url: location.href,
			subject,
			messageId: msg.getAttribute('data-legacy-message-id') || msg.getAttribute('data-message-id') || '',
			recipients: Array.from(recipSet),
			attachments: Array.from(attachSet),
			body: (msg.querySelector('.a3s')?.innerText || '').trim(),
			preview: (msg.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 260)
		};
	})()`, &sentMsg); err != nil {
		return nil, fmt.Errorf("inspect opened sent message: %w", err)
	}

	if err := verifySentMessage(req, attachReceipts, sentMsg); err != nil {
		return nil, fmt.Errorf("sent message verification failed: %w", err)
	}

	receipt.Status = "sent"
	receipt.VerifiedInSent = true
	receipt.SentMessageID = sentMsg.MessageID
	receipt.SentMessageURL = sentMsg.URL
	receipt.SentRowPreview = sentMsg.Preview
	receipt.ElapsedMS = time.Since(started).Milliseconds()
	return receipt, nil
}

func fillRecipients(ctx context.Context, cdpPort int, targetID, field string, addrs []string) error {
	var focusExpr string
	switch field {
	case "To":
		focusExpr = `(() => {
			const dlg = document.querySelector('div[role="dialog"]');
			if (!dlg) return false;
			const hl = dlg.querySelector('.aoD.hl');
			if (hl) hl.focus();
			const inp = dlg.querySelector('input[aria-label="To recipients"]');
			if (!inp) return false;
			inp.focus();
			return document.activeElement === inp;
		})()`
	case "Cc":
		focusExpr = `(() => {
			const dlg = document.querySelector('div[role="dialog"]');
			if (!dlg) return false;
			const btn = dlg.querySelector('span[aria-label*="Add Cc"]');
			if (btn) btn.click();
			const inp = dlg.querySelector('input[aria-label="CC recipients"]');
			if (!inp) return false;
			inp.focus();
			return document.activeElement === inp;
		})()`
	case "Bcc":
		focusExpr = `(() => {
			const dlg = document.querySelector('div[role="dialog"]');
			if (!dlg) return false;
			const btn = dlg.querySelector('span[aria-label*="Add Bcc"]');
			if (btn) btn.click();
			const inp = dlg.querySelector('input[aria-label="BCC recipients"]');
			if (!inp) return false;
			inp.focus();
			return document.activeElement === inp;
		})()`
	default:
		return fmt.Errorf("unknown recipient field %q", field)
	}
	if err := cdp.FillRecipientChips(ctx, cdpPort, targetID, focusExpr, addrs); err != nil {
		return fmt.Errorf("fill %s (%v): %w", field, addrs, err)
	}
	return nil
}

func attachmentNames(list []AttachmentReceipt) []string {
	out := make([]string, len(list))
	for i, a := range list {
		out[i] = a.Name
	}
	return out
}

type draftSnapshot struct {
	Subject string   `json:"subject"`
	Body    string   `json:"body"`
	To      []string `json:"to"`
	CC      []string `json:"cc"`
	BCC     []string `json:"bcc"`
	All     []string `json:"all"`
}

func verifyDraftState(req SendRequest, got draftSnapshot) error {
	if got.Subject != req.Subject {
		return fmt.Errorf("subject verification mismatch: want %q, got %q", req.Subject, got.Subject)
	}
	if normalizeBody(got.Body) != normalizeBody(req.Body) {
		return fmt.Errorf("body verification mismatch: want %q, got %q", normalizeBody(req.Body), normalizeBody(got.Body))
	}
	expectedAll := append(append(append([]string{}, req.To...), req.CC...), req.BCC...)
	if err := verifyExactAddressSet("all recipients", expectedAll, got.All); err != nil {
		return err
	}
	if err := verifyExactAddressSet("To", req.To, got.To); err != nil {
		return err
	}
	if err := verifyExactAddressSet("Cc", req.CC, got.CC); err != nil {
		return err
	}
	if err := verifyExactAddressSet("Bcc", req.BCC, got.BCC); err != nil {
		return err
	}
	return nil
}

func normalizeBody(s string) string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.ReplaceAll(s, "\r", "\n")
	lines := strings.Split(s, "\n")
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return strings.Join(out, "\n")
}

func verifyExactAddressSet(label string, want, got []string) error {
	wantSet := make(map[string]struct{}, len(want))
	for _, w := range want {
		if s := strings.ToLower(strings.TrimSpace(w)); s != "" {
			wantSet[s] = struct{}{}
		}
	}
	gotSet := make(map[string]struct{}, len(got))
	for _, g := range got {
		if s := strings.ToLower(strings.TrimSpace(g)); s != "" {
			gotSet[s] = struct{}{}
		}
	}
	for w := range wantSet {
		if _, ok := gotSet[w]; !ok {
			return fmt.Errorf("%s verification mismatch: missing %q (got %v)", label, w, got)
		}
	}
	for g := range gotSet {
		if _, ok := wantSet[g]; !ok {
			return fmt.Errorf("%s verification mismatch: unexpected recipient %q (want %v)", label, g, want)
		}
	}
	return nil
}

type sentMessageSnapshot struct {
	URL         string   `json:"url"`
	Subject     string   `json:"subject"`
	MessageID   string   `json:"messageId"`
	Recipients  []string `json:"recipients"`
	Attachments []string `json:"attachments"`
	Body        string   `json:"body"`
	Preview     string   `json:"preview"`
}

func verifySentMessage(req SendRequest, expectedAttachments []AttachmentReceipt, got sentMessageSnapshot) error {
	if got.MessageID == "" {
		return fmt.Errorf("missing message ID in opened thread (%s)", got.URL)
	}
	if got.Subject != req.Subject {
		return fmt.Errorf("opened subject mismatch: want %q, got %q", req.Subject, got.Subject)
	}
	recipSet := make(map[string]struct{}, len(got.Recipients))
	for _, r := range got.Recipients {
		if s := strings.ToLower(strings.TrimSpace(r)); s != "" {
			recipSet[s] = struct{}{}
		}
	}
	for _, want := range append(append([]string{}, req.To...), req.CC...) {
		if _, ok := recipSet[strings.ToLower(strings.TrimSpace(want))]; !ok {
			return fmt.Errorf("recipient %q not found in opened message headers %v", want, got.Recipients)
		}
	}
	attachSet := make(map[string]struct{}, len(got.Attachments))
	for _, name := range got.Attachments {
		attachSet[strings.TrimSpace(name)] = struct{}{}
	}
	for _, want := range expectedAttachments {
		if _, ok := attachSet[want.Name]; !ok {
			return fmt.Errorf("attachment %q not found in opened message attachments %v", want.Name, got.Attachments)
		}
	}
	return nil
}
