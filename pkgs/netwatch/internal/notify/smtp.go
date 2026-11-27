package notify

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"fmt"
	"net"
	"net/mail"
	"net/smtp"
	"strconv"
	"strings"
	"time"
)

const defaultSMTPTimeout = 20 * time.Second

// Config defines authenticated SMTP delivery settings (e.g. Cloudflare Email Sending or Gmail).
type Config struct {
	Host     string
	Port     int
	TLSMode  string // implicit | starttls | plain (tests only)
	Username string
	Password string
	From     string
	To       []string
	Timeout  time.Duration
}

// Validate checks required SMTP parameters before sending.
func (c Config) Validate() error {
	if strings.TrimSpace(c.Host) == "" {
		return fmt.Errorf("SMTP host is empty")
	}
	if c.Port <= 0 || c.Port > 65535 {
		return fmt.Errorf("invalid SMTP port %d", c.Port)
	}
	if _, err := envelopeAddress(c.From); err != nil {
		return fmt.Errorf("invalid SMTP from %q: %w", c.From, err)
	}
	if len(c.To) == 0 {
		return fmt.Errorf("SMTP recipient list is empty")
	}
	for _, r := range c.To {
		if _, err := envelopeAddress(r); err != nil {
			return fmt.Errorf("invalid SMTP recipient %q: %w", r, err)
		}
	}
	switch strings.ToLower(strings.TrimSpace(c.TLSMode)) {
	case "", "implicit", "starttls", "plain":
	default:
		return fmt.Errorf("unsupported SMTP TLS mode %q", c.TLSMode)
	}
	return nil
}

// Send delivers a UTF-8 plain-text email over authenticated SMTP.
func Send(ctx context.Context, cfg Config, subject, body string) error {
	if err := cfg.Validate(); err != nil {
		return err
	}
	timeout := cfg.Timeout
	if timeout <= 0 {
		timeout = defaultSMTPTimeout
	}

	addr := net.JoinHostPort(cfg.Host, strconv.Itoa(cfg.Port))
	tlsMode := strings.ToLower(strings.TrimSpace(cfg.TLSMode))
	if tlsMode == "" {
		if cfg.Port == 465 {
			tlsMode = "implicit"
		} else {
			tlsMode = "starttls"
		}
	}

	dialCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	tlsCfg := &tls.Config{
		ServerName: cfg.Host,
		MinVersion: tls.VersionTLS12,
	}

	dialer := &net.Dialer{Timeout: timeout}
	var conn net.Conn
	var err error
	if tlsMode == "implicit" {
		tlsDialer := &tls.Dialer{NetDialer: dialer, Config: tlsCfg}
		conn, err = tlsDialer.DialContext(dialCtx, "tcp", addr)
	} else {
		conn, err = dialer.DialContext(dialCtx, "tcp", addr)
	}
	if err != nil {
		return fmt.Errorf("smtp dial %s: %w", addr, err)
	}
	defer conn.Close()

	if dl, ok := dialCtx.Deadline(); ok {
		_ = conn.SetDeadline(dl)
	}

	client, err := smtp.NewClient(conn, cfg.Host)
	if err != nil {
		return fmt.Errorf("smtp client init: %w", err)
	}
	defer func() { _ = client.Quit() }()

	if tlsMode == "starttls" {
		if ok, _ := client.Extension("STARTTLS"); !ok {
			return fmt.Errorf("smtp server %s does not advertise STARTTLS", addr)
		}
		if err := client.StartTLS(tlsCfg); err != nil {
			return fmt.Errorf("smtp STARTTLS: %w", err)
		}
	}

	if strings.TrimSpace(cfg.Username) != "" {
		auth := smtp.PlainAuth("", cfg.Username, cfg.Password, cfg.Host)
		if err := client.Auth(auth); err != nil {
			return fmt.Errorf("smtp auth: %w", err)
		}
	}

	fromEnv, err := envelopeAddress(cfg.From)
	if err != nil {
		return err
	}
	if err := client.Mail(fromEnv); err != nil {
		return fmt.Errorf("smtp MAIL FROM: %w", err)
	}
	toEnvs := make([]string, 0, len(cfg.To))
	for _, r := range cfg.To {
		rcpt, err := envelopeAddress(r)
		if err != nil {
			return err
		}
		if err := client.Rcpt(rcpt); err != nil {
			return fmt.Errorf("smtp RCPT TO %s: %w", rcpt, err)
		}
		toEnvs = append(toEnvs, rcpt)
	}

	wc, err := client.Data()
	if err != nil {
		return fmt.Errorf("smtp DATA: %w", err)
	}
	msg := buildMessage(cfg.From, toEnvs, subject, body, time.Now().UTC())
	if _, err := wc.Write([]byte(msg)); err != nil {
		_ = wc.Close()
		return fmt.Errorf("smtp write body: %w", err)
	}
	if err := wc.Close(); err != nil {
		return fmt.Errorf("smtp close data: %w", err)
	}
	return nil
}

func envelopeAddress(raw string) (string, error) {
	addr, err := mail.ParseAddress(strings.TrimSpace(raw))
	if err != nil {
		return "", err
	}
	return addr.Address, nil
}

func sanitizeHeader(s string) string {
	s = strings.ReplaceAll(s, "\r", " ")
	s = strings.ReplaceAll(s, "\n", " ")
	return strings.TrimSpace(s)
}

func buildMessage(from string, to []string, subject, body string, now time.Time) string {
	domain := "alerts.faragao.net"
	if addr, err := envelopeAddress(from); err == nil {
		if at := strings.LastIndexByte(addr, '@'); at != -1 {
			domain = addr[at+1:]
		}
	}
	var rnd [8]byte
	_, _ = rand.Read(rnd[:])
	msgID := fmt.Sprintf("<%d.%s@%s>", now.UnixNano(), hex.EncodeToString(rnd[:]), sanitizeHeader(domain))

	normBody := strings.ReplaceAll(body, "\r\n", "\n")
	normBody = strings.ReplaceAll(normBody, "\n", "\r\n")
	if !strings.HasSuffix(normBody, "\r\n") {
		normBody += "\r\n"
	}

	var b strings.Builder
	b.WriteString("From: " + sanitizeHeader(from) + "\r\n")
	b.WriteString("To: " + sanitizeHeader(strings.Join(to, ", ")) + "\r\n")
	b.WriteString("Subject: " + sanitizeHeader(subject) + "\r\n")
	b.WriteString("Date: " + now.Format(time.RFC1123Z) + "\r\n")
	b.WriteString("Message-ID: " + msgID + "\r\n")
	b.WriteString("MIME-Version: 1.0\r\n")
	b.WriteString("Content-Type: text/plain; charset=utf-8\r\n")
	b.WriteString("Content-Transfer-Encoding: 8bit\r\n")
	b.WriteString("\r\n")
	b.WriteString(normBody)
	return b.String()
}
