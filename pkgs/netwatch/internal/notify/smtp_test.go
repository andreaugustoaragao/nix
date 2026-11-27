package notify

import (
	"bufio"
	"context"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"faragao.net/netwatch/internal/model"
)

func TestSMTPSendPlainAndFormatRedaction(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen err: %v", err)
	}
	defer ln.Close()

	var mu sync.Mutex
	var captured strings.Builder
	done := make(chan struct{})

	go func() {
		defer close(done)
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		r := bufio.NewReader(conn)
		write := func(s string) { _, _ = conn.Write([]byte(s + "\r\n")) }
		write("220 mock.smtp.local ESMTP")
		inData := false
		for {
			line, err := r.ReadString('\n')
			if err != nil {
				return
			}
			trimmed := strings.TrimRight(line, "\r\n")
			mu.Lock()
			captured.WriteString(trimmed + "\n")
			mu.Unlock()
			if inData {
				if trimmed == "." {
					inData = false
					write("250 2.0.0 OK")
				}
				continue
			}
			upper := strings.ToUpper(trimmed)
			switch {
			case strings.HasPrefix(upper, "EHLO") || strings.HasPrefix(upper, "HELO"):
				write("250-mock.smtp.local")
				write("250 AUTH PLAIN")
			case strings.HasPrefix(upper, "AUTH "):
				write("235 2.7.0 Authentication successful")
			case strings.HasPrefix(upper, "MAIL FROM:"):
				write("250 2.1.0 Ok")
			case strings.HasPrefix(upper, "RCPT TO:"):
				write("250 2.1.5 Ok")
			case upper == "DATA":
				inData = true
				write("354 End data with <CR><LF>.<CR><LF>")
			case upper == "QUIT":
				write("221 2.0.0 Bye")
				return
			default:
				write("250 Ok")
			}
		}
	}()

	host, portStr, _ := net.SplitHostPort(ln.Addr().String())
	port := 0
	for _, r := range portStr {
		port = port*10 + int(r-'0')
	}

	now := time.Date(2026, 11, 27, 8, 0, 0, 0, time.UTC)
	subj, body := FormatUrgent(model.TrackedFinding{
		Finding: model.Finding{
			ID:                "synthetic:urgent-1",
			Severity:          model.SeverityUrgent,
			Device:            "chief-tui-opn",
			Title:             "Test Advisory",
			Summary:           "Test summary",
			RunningVersion:    "26.7.10",
			FixedVersion:      "26.7.11",
			Exposure:          "WAN=igc1",
			RebootExpected:    "no",
			RecommendedTiming: "Immediate",
			Synthetic:         true,
		},
		Status: model.StatusOpen,
	}, now)

	if !strings.Contains(subj, "[SYNTHETIC TEST]") || !strings.Contains(body, "SYNTHETIC TEST MESSAGE") {
		t.Fatalf("expected synthetic banner in subject/body")
	}

	cfg := Config{
		Host:     host,
		Port:     port,
		TLSMode:  "plain",
		Username: "api_token",
		Password: "super-secret-smtp-password",
		From:     "faragao netwatch <ops@alerts.faragao.net>",
		To:       []string{"andre@example.com"},
		Timeout:  5 * time.Second,
	}
	if err := Send(context.Background(), cfg, subj, body); err != nil {
		t.Fatalf("Send() err: %v", err)
	}
	<-done

	mu.Lock()
	transcript := captured.String()
	mu.Unlock()

	for _, want := range []string{
		"MAIL FROM:<ops@alerts.faragao.net>",
		"RCPT TO:<andre@example.com>",
		"Subject: [SYNTHETIC TEST] [faragao-netwatch] URGENT: Test Advisory (chief-tui-opn)",
		"SYNTHETIC TEST MESSAGE",
	} {
		if !strings.Contains(transcript, want) {
			t.Fatalf("SMTP transcript missing %q:\n%s", want, transcript)
		}
	}
}
