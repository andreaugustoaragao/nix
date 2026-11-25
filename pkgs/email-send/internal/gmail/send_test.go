package gmail

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

func TestAttachmentParsingAndStaging(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "pasted-image-abc.png")
	content := []byte("fake-png-bytes-for-test")
	if err := os.WriteFile(src, content, 0o644); err != nil {
		t.Fatal(err)
	}

	spec1, err := ParseAttachmentSpec(src)
	if err != nil {
		t.Fatalf("ParseAttachmentSpec(plain): %v", err)
	}
	if spec1.DisplayName != "pasted-image-abc.png" {
		t.Fatalf("unexpected display name: %q", spec1.DisplayName)
	}

	spec2, err := ParseAttachmentSpec(src + ":pier-location-change.png")
	if err != nil {
		t.Fatalf("ParseAttachmentSpec(aliased): %v", err)
	}
	if spec2.DisplayName != "pier-location-change.png" {
		t.Fatalf("unexpected aliased display name: %q", spec2.DisplayName)
	}

	if _, err := ParseAttachmentSpec(filepath.Join(dir, "missing.png")); err == nil {
		t.Fatalf("expected error for missing file")
	}

	paths, receipts, cleanup, err := stageAttachments([]AttachmentSpec{spec2, spec2})
	if err != nil {
		t.Fatalf("stageAttachments: %v", err)
	}
	stageDir := filepath.Dir(paths[0])

	sum := sha256.Sum256(content)
	wantHash := hex.EncodeToString(sum[:])

	if len(paths) != 2 || len(receipts) != 2 {
		t.Fatalf("expected 2 staged attachments, got %d / %d", len(paths), len(receipts))
	}
	if receipts[0].Name != "pier-location-change.png" || receipts[1].Name != "pier-location-change-2.png" {
		t.Fatalf("unexpected deduplicated names: %+v", receipts)
	}
	if receipts[0].SHA256 != wantHash || receipts[0].Bytes != int64(len(content)) {
		t.Fatalf("receipt mismatch: %+v", receipts[0])
	}

	cleanup()
	if _, err := os.Stat(stageDir); !os.IsNotExist(err) {
		t.Fatalf("expected stage dir %s to be removed on cleanup", stageDir)
	}
}
func TestVerifyDraftState(t *testing.T) {
	req := SendRequest{
		To:      []string{"ptognini@avaya.com"},
		CC:      []string{"cc@avaya.com"},
		BCC:     []string{"bcc@avaya.com"},
		Subject: "Location change",
		Body:    "Pier,\n\nAs discussed, updated.\n\nAndre",
	}

	// Gmail contenteditable innerText doubles blank lines; normalized body must match.
	okSnap := draftSnapshot{
		Subject: "Location change",
		Body:    "Pier,\n\n\nAs discussed, updated.\n\n\nAndre\n",
		To:      []string{"ptognini@avaya.com"},
		CC:      []string{"cc@avaya.com"},
		BCC:     []string{"bcc@avaya.com"},
		All:     []string{"ptognini@avaya.com", "cc@avaya.com", "bcc@avaya.com"},
	}
	if err := verifyDraftState(req, okSnap); err != nil {
		t.Fatalf("expected valid draft to pass, got %v", err)
	}

	// Truncated body must fail closed.
	badBody := okSnap
	badBody.Body = "Pier,"
	if err := verifyDraftState(req, badBody); err == nil {
		t.Fatalf("expected truncated body to fail verification")
	}

	// Extra unexpected recipient must fail closed.
	extraRecip := okSnap
	extraRecip.To = []string{"ptognini@avaya.com", "leak@external.com"}
	extraRecip.All = []string{"ptognini@avaya.com", "leak@external.com", "cc@avaya.com", "bcc@avaya.com"}
	if err := verifyDraftState(req, extraRecip); err == nil {
		t.Fatalf("expected unexpected recipient to fail verification")
	}

	// Bcc landing in To must fail closed even when total set matches.
	bccLeak := okSnap
	bccLeak.To = []string{"ptognini@avaya.com", "bcc@avaya.com"}
	bccLeak.BCC = nil
	if err := verifyDraftState(req, bccLeak); err == nil {
		t.Fatalf("expected Bcc->To mixup to fail verification")
	}
}

func TestVerifySentMessage(t *testing.T) {
	req := SendRequest{
		To:      []string{"ptognini@avaya.com"},
		Subject: "Location change effective Jan 1, 2027",
	}
	attach := []AttachmentReceipt{{Name: "pier-location-change.png", Bytes: 43403}}

	okMsg := sentMessageSnapshot{
		URL:         "https://mail.google.com/mail/u/0/#sent/FMfcgz123",
		Subject:     "Location change effective Jan 1, 2027",
		MessageID:   "msg-a:r123456",
		Recipients:  []string{"aragao@avaya.com", "ptognini@avaya.com"},
		Attachments: []string{"pier-location-change.png"},
	}
	if err := verifySentMessage(req, attach, okMsg); err != nil {
		t.Fatalf("expected valid sent message to pass, got %v", err)
	}

	// Missing named attachment must fail closed even if subject matches.
	noAttach := okMsg
	noAttach.Attachments = nil
	if err := verifySentMessage(req, attach, noAttach); err == nil {
		t.Fatalf("expected missing attachment to fail verification")
	}

	// Wrong attachment name must fail closed.
	wrongAttach := okMsg
	wrongAttach.Attachments = []string{"other-file.png"}
	if err := verifySentMessage(req, attach, wrongAttach); err == nil {
		t.Fatalf("expected wrong attachment name to fail verification")
	}

	// Missing recipient in opened message header must fail closed.
	wrongRecip := okMsg
	wrongRecip.Recipients = []string{"aragao@avaya.com"}
	if err := verifySentMessage(req, attach, wrongRecip); err == nil {
		t.Fatalf("expected missing recipient to fail verification")
	}
}

