package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"email-send/internal/browser"
	"email-send/internal/gmail"
	"email-send/internal/people"
)

type multiFlag []string

func (m *multiFlag) String() string { return strings.Join(*m, ",") }
func (m *multiFlag) Set(v string) error {
	*m = append(*m, v)
	return nil
}

func main() {
	var (
		toFlags    multiFlag
		ccFlags    multiFlag
		bccFlags   multiFlag
		attachFlag multiFlag

		subject     string
		body        string
		bodyFile    string
		account     string
		vaultRoot   string
		profile     string
		cdpPort     int
		send        bool
		keepDraft   bool
		operationID string
		stateDir    string
		timeout     time.Duration
	)

	flag.Var(&toFlags, "to", "Recipient email or vault person name (repeatable or comma-separated)")
	flag.Var(&ccFlags, "cc", "CC recipient email or vault person name (repeatable or comma-separated)")
	flag.Var(&bccFlags, "bcc", "BCC recipient email or vault person name (repeatable or comma-separated)")
	flag.Var(&attachFlag, "attach", "Local file to attach, optionally as path:displayname (repeatable)")
	flag.StringVar(&subject, "subject", "", "Email subject line (required)")
	flag.StringVar(&body, "body", "", "Plain-text email body")
	flag.StringVar(&bodyFile, "body-file", "", "Path to UTF-8 file containing body ('-' for stdin)")
	flag.StringVar(&account, "account", "aragao@avaya.com", "Expected active Gmail account (fail-closed check)")
	flag.StringVar(&vaultRoot, "vault-root", defaultVaultRoot(), "Vault root for people/*.md lookup")
	flag.StringVar(&profile, "profile", "accounts", "Managed browser-task profile")
	flag.IntVar(&cdpPort, "cdp-port", 0, "Override CDP port for attachments (0 = auto-discover from browser-task config)")
	flag.BoolVar(&send, "send", false, "Actually send the email (default false = dry-run preview)")
	flag.BoolVar(&keepDraft, "keep-draft", false, "Keep composed draft in Gmail on dry-run instead of discarding")
	flag.StringVar(&operationID, "operation", "", "Optional idempotency key to prevent duplicate sends")
	flag.StringVar(&stateDir, "state-dir", "", "Directory for operation receipts (default $XDG_STATE_HOME/email-send or ~/.local/state/email-send)")
	flag.DurationVar(&timeout, "timeout", 90*time.Second, "Overall execution timeout")
	flag.Parse()

	if err := run(runOpts{
		toRaw:       splitComma(toFlags),
		ccRaw:       splitComma(ccFlags),
		bccRaw:      splitComma(bccFlags),
		attachRaw:   attachFlag,
		subject:     subject,
		body:        body,
		bodyFile:    bodyFile,
		account:     account,
		vaultRoot:   vaultRoot,
		profile:     profile,
		cdpPort:     cdpPort,
		send:        send,
		keepDraft:   keepDraft,
		operationID: strings.TrimSpace(operationID),
		stateDir:    stateDir,
		timeout:     timeout,
	}); err != nil {
		fmt.Fprintf(os.Stderr, "email-send: %v\n", err)
		os.Exit(1)
	}
}

type runOpts struct {
	toRaw       []string
	ccRaw       []string
	bccRaw      []string
	attachRaw   []string
	subject     string
	body        string
	bodyFile    string
	account     string
	vaultRoot   string
	profile     string
	cdpPort     int
	send        bool
	keepDraft   bool
	operationID string
	stateDir    string
	timeout     time.Duration
}

func run(o runOpts) error {
	if len(o.toRaw) == 0 {
		return errors.New("at least one --to recipient is required")
	}
	if strings.TrimSpace(o.subject) == "" {
		return errors.New("--subject is required")
	}

	bodyText, err := loadBody(o.body, o.bodyFile)
	if err != nil {
		return err
	}
	if strings.TrimSpace(bodyText) == "" {
		return errors.New("email body is empty (provide --body or --body-file)")
	}

	var store *gmail.OperationStore
	if o.operationID != "" {
		if strings.ContainsAny(o.operationID, `/\`) || o.operationID == "." || o.operationID == ".." {
			return fmt.Errorf("invalid --operation id %q", o.operationID)
		}
		if o.stateDir == "" {
			dir, err := defaultStateDir()
			if err != nil {
				return err
			}
			o.stateDir = dir
		}
		store = &gmail.OperationStore{Dir: o.stateDir}
	}

	// Load vault people roster (tolerate missing dir if all recipients are literal emails).
	roster, rosterErr := people.LoadDir(filepath.Join(o.vaultRoot, "people"))
	resolveAll := func(raw []string) ([]string, error) {
		out := make([]string, 0, len(raw))
		for _, q := range raw {
			p, err := people.Resolve(q, roster)
			if err != nil {
				if rosterErr != nil {
					return nil, fmt.Errorf("%w (also failed loading people dir: %v)", err, rosterErr)
				}
				return nil, err
			}
			out = append(out, p.Email)
		}
		return out, nil
	}

	toAddrs, err := resolveAll(o.toRaw)
	if err != nil {
		return fmt.Errorf("resolve --to: %w", err)
	}
	ccAddrs, err := resolveAll(o.ccRaw)
	if err != nil {
		return fmt.Errorf("resolve --cc: %w", err)
	}
	bccAddrs, err := resolveAll(o.bccRaw)
	if err != nil {
		return fmt.Errorf("resolve --bcc: %w", err)
	}

	attachments := make([]gmail.AttachmentSpec, 0, len(o.attachRaw))
	for _, raw := range o.attachRaw {
		spec, err := gmail.ParseAttachmentSpec(raw)
		if err != nil {
			return err
		}
		attachments = append(attachments, spec)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	ctx, timeoutCancel := context.WithTimeout(ctx, o.timeout)
	defer timeoutCancel()

	// Reserve --operation atomically BEFORE launching the browser for a live send.
	var dispatched bool
	if store != nil && o.send {
		existing, err := store.Reserve(o.operationID)
		if err != nil {
			return err
		}
		if existing != nil {
			encoded, err := json.MarshalIndent(existing, "", "  ")
			if err != nil {
				return err
			}
			fmt.Println(string(encoded))
			return nil
		}
	}

	client := browser.NewClient(o.profile, 45)
	var beforeSend func() error
	if store != nil && o.send {
		beforeSend = func() error {
			if err := store.Transition(o.operationID, "dispatching", nil, nil); err != nil {
				return err
			}
			dispatched = true
			return nil
		}
	}

	receipt, err := gmail.Execute(ctx, client, gmail.SendRequest{
		Account:     o.account,
		To:          toAddrs,
		CC:          ccAddrs,
		BCC:         bccAddrs,
		Subject:     o.subject,
		Body:        bodyText,
		Attachments: attachments,
		Send:        o.send,
		KeepDraft:   o.keepDraft,
		CDPPort:     o.cdpPort,
		OperationID: o.operationID,
		BeforeSend:  beforeSend,
	})
	if err != nil {
		if store != nil && o.send {
			if dispatched {
				_ = store.Transition(o.operationID, "uncertain", nil, err)
			} else {
				store.ReleasePreSend(o.operationID)
			}
		}
		return err
	}

	if store != nil && receipt.Status == "sent" {
		if err := store.Transition(o.operationID, "sent", receipt, nil); err != nil {
			return fmt.Errorf("persist sent receipt: %w", err)
		}
	}

	encoded, err := json.MarshalIndent(receipt, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(encoded))
	return nil
}

func loadBody(inline, filePath string) (string, error) {
	if inline != "" && filePath != "" {
		return "", errors.New("specify only one of --body or --body-file")
	}
	if filePath == "" {
		return inline, nil
	}
	var b []byte
	var err error
	if filePath == "-" {
		b, err = io.ReadAll(os.Stdin)
	} else {
		b, err = os.ReadFile(filePath)
	}
	if err != nil {
		return "", fmt.Errorf("read body: %w", err)
	}
	return strings.TrimRight(string(b), "\r\n"), nil
}

func splitComma(values []string) []string {
	var out []string
	for _, v := range values {
		for _, part := range strings.Split(v, ",") {
			part = strings.TrimSpace(part)
			if part != "" {
				out = append(out, part)
			}
		}
	}
	return out
}

func defaultStateDir() (string, error) {
	if xdg := strings.TrimSpace(os.Getenv("XDG_STATE_HOME")); xdg != "" {
		return filepath.Join(xdg, "email-send"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve default state dir (set --state-dir or XDG_STATE_HOME): %w", err)
	}
	return filepath.Join(home, ".local", "state", "email-send"), nil
}

func defaultVaultRoot() string {
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		return filepath.Join(home, "projects", "work", "notes")
	}
	return ""
}
