package syslog

import (
	"context"
	"fmt"
	"net"
	"strings"
	"testing"
	"time"

	"faragao.net/netwatch/internal/model"
)

func testPolicy() Policy {
	return Policy{
		Device:                      "chief-tui-opn.faragao.net",
		AllowedAdminUsers:           []string{"andre"},
		AllowedAdminCIDRs:           []string{"192.168.10.75/32", "192.168.50.0/24"},
		WANInterface:                "igc1",
		AllowedWANInboundPorts:      []int{443},
		AuthFailThreshold:           5,
		OutboundScanPortThreshold:   20,
		OutboundBlockBurstThreshold: 30,
		Window:                      10 * time.Minute,
	}
}

func TestParseRealOPNsenseMessagesAndRedaction(t *testing.T) {
	now := time.Date(2026, 11, 27, 19, 0, 0, 0, time.UTC)

	filterLine := `<134>1 2026-11-27T11:51:42-07:00 chief-tui-opn.faragao.net filterlog 96679 - [meta sequenceId="66684"] 5,,,02f4bab031b57d1e30553ce08e0ec131,igc1,match,block,in,4,0x0,,248,54321,0,none,6,tcp,44,162.216.149.98,174.16.196.251,51919,56332,0,S,3573921890,,65535,,mss`
	msg, ok := ParseLine(filterLine, now)
	if !ok || msg.AppName != "filterlog" || msg.Host != "chief-tui-opn.faragao.net" {
		t.Fatalf("ParseLine filterlog failed: ok=%v msg=%+v", ok, msg)
	}
	fl, ok := ParseFilterLog(msg.Body)
	if !ok || fl.Interface != "igc1" || fl.Action != "block" || fl.Dir != "in" || fl.Proto != "tcp" || fl.DstPort != "56332" {
		t.Fatalf("ParseFilterLog mismatch: ok=%v fl=%+v", ok, fl)
	}

	auditSudo := `<37>1 2026-11-27T11:51:43-07:00 chief-tui-opn.faragao.net audit 54993 - [meta sequenceId="54646"] user andre authenticated successfully for sudo [using OPNsense\Auth\Services\System + OPNsense\Auth\LocalTOTP] at -`
	m2, ok := ParseLine(auditSudo, now)
	if !ok || m2.AppName != "audit" {
		t.Fatalf("ParseLine audit failed: %+v", m2)
	}

	redacted := RedactEvidence("Accepted publickey token=abc123SECRET password: \"hunter2\" Bearer eyJfoo.bar.baz PHPSESSID=xyz999\nline2")
	for _, secret := range []string{"abc123SECRET", "hunter2", "eyJfoo", "xyz999"} {
		if strings.Contains(redacted, secret) {
			t.Fatalf("secret %q leaked after RedactEvidence: %q", secret, redacted)
		}
	}
	if !strings.Contains(redacted, "Accepted publickey") {
		t.Fatalf("expected non-secret content preserved: %q", redacted)
	}
}

func TestDetectorPoliciesAndSyntheticIsolation(t *testing.T) {
	now := time.Date(2026, 11, 27, 19, 0, 0, 0, time.UTC)
	det := NewDetector(testPolicy())

	// 1. Expected SSH login from andre @ 192.168.10.75 -> NO finding, ExpectedAdminLogins=1
	m, _ := ParseLine(`<38>1 2026-11-27T19:00:00Z chief-tui-opn sshd 100 - - Accepted publickey for andre from 192.168.10.75 port 50000 ssh2`, now)
	m.ReceivedAt = now
	f, delta := det.Process(m, false)
	if f != nil || delta.ExpectedAdminLogins != 1 {
		t.Fatalf("expected allowlisted sshd login to produce 0 findings and 1 login counter, got f=%+v delta=%+v", f, delta)
	}

	// 2. Unexpected SSH login (wrong IP + root + token redaction + synthetic marker)
	synLine := `<38>1 2026-11-27T19:00:01Z chief-tui-opn sshd 101 - - Accepted publickey for root from 192.168.30.99 port 51234 ssh2 [SYNTHETIC TEST] token=secret123`
	ms, _ := ParseLine(synLine, now)
	ms.ReceivedAt = now
	fs, _ := det.Process(ms, false)
	if fs == nil || !fs.Synthetic || fs.ID != "synthetic:sec:opnsense:admin-ssh:root:192.168.30.99" {
		t.Fatalf("expected synthetic urgent sshd finding, got %+v", fs)
	}
	if strings.Contains(fs.Summary, "secret123") {
		t.Fatalf("token leaked into finding summary: %q", fs.Summary)
	}

	// 3. Routine WAN inbound block -> 0 findings, aggregated counter
	wanBlock, _ := ParseLine(`<134>1 2026-11-27T19:00:02Z chief-tui-opn filterlog 10 - - 5,,,aa,igc1,match,block,in,4,0x0,,248,1,0,none,6,tcp,44,198.51.100.77,174.16.196.251,51919,56332`, now)
	wanBlock.ReceivedAt = now
	fw, dw := det.Process(wanBlock, false)
	if fw != nil || dw.WANBlockedIn != 1 || dw.BlockedPort != "tcp/56332" {
		t.Fatalf("unexpected WAN block handling: f=%+v delta=%+v", fw, dw)
	}

	// 4. Unexpected WAN inbound pass (:2222) -> Urgent
	wanPass, _ := ParseLine(`<134>1 2026-11-27T19:00:03Z chief-tui-opn filterlog 10 - - 99,,,bb,igc1,match,pass,in,4,0x0,,64,1,0,DF,6,tcp,60,198.51.100.5,174.16.196.251,44000,2222`, now)
	wanPass.ReceivedAt = now
	fwp, _ := det.Process(wanPass, false)
	if fwp == nil || fwp.Severity != model.SeverityUrgent || fwp.ID != "sec:opnsense:wan-pass:tcp:2222" {
		t.Fatalf("expected unexpected WAN pass urgent finding, got %+v", fwp)
	}

	// 5. High-risk outbound port (:4444) -> Urgent
	outHR, _ := ParseLine(`<134>1 2026-11-27T19:00:04Z chief-tui-opn filterlog 10 - - 40,,,cc,ix0,match,pass,in,4,0x0,,64,1,0,DF,6,tcp,60,192.168.30.44,203.0.113.88,55000,4444`, now)
	outHR.ReceivedAt = now
	fhr, _ := det.Process(outHR, false)
	if fhr == nil || fhr.ID != "sec:opnsense:outbound-highrisk:192.168.30.44:4444" {
		t.Fatalf("expected high-risk outbound urgent finding, got %+v", fhr)
	}

	// 6. Outbound port-scan burst (>=20 distinct ports in 10m)
	var scanFinding *model.Finding
	for p := 0; p < 20; p++ {
		port := 10000 + p
		line := fmt.Sprintf(`<134>1 2026-11-27T19:01:00Z chief-tui-opn filterlog 10 - - 40,,,dd,ix0,match,pass,out,4,0x0,,64,1,0,DF,6,tcp,60,192.168.20.55,203.0.113.99,55123,%d`, port)
		sm, _ := ParseLine(line, now)
		sm.ReceivedAt = now
		scanFinding, _ = det.Process(sm, false)
	}
	if scanFinding == nil || scanFinding.ID != "sec:opnsense:outbound-scan:192.168.20.55" {
		t.Fatalf("expected outbound scan alert at 20th distinct port, got %+v", scanFinding)
	}

	// 7. Suricata Priority-1 IDS lead vs Priority-3 digest
	idsP1, _ := ParseLine(`<134>1 2026-11-27T19:02:00Z chief-tui-opn suricata 900 - - [1:2010935:4] ET MALWARE Suspect C2 Beacon [Classification: A Network Trojan was detected] [Priority: 1] {TCP} 192.168.30.50:49152 -> 203.0.113.10:8080`, now)
	idsP1.ReceivedAt = now
	fids1, dids1 := det.Process(idsP1, false)
	if fids1 == nil || !strings.Contains(fids1.Title, "IDS lead (uncorroborated)") || dids1.IDSAlertsUrgent != 1 || fids1.ID != "sec:opnsense:ids-lead:2010935:192.168.30.50" {
		t.Fatalf("expected Priority 1 IDS lead urgent finding on bare IP, got f=%+v delta=%+v", fids1, dids1)
	}

	idsP3, _ := ParseLine(`<134>1 2026-11-27T19:02:01Z chief-tui-opn suricata 900 - - [1:2100498:7] GPL ATTACK_RESPONSE id check [Classification: Potentially Bad Traffic] [Priority: 3] {TCP} 192.168.10.75:443 -> 203.0.113.11:51000`, now)
	idsP3.ReceivedAt = now
	fids3, dids3 := det.Process(idsP3, false)
	if fids3 != nil || dids3.IDSAlertsDigest != 1 {
		t.Fatalf("expected Priority 3 IDS alert to stay digest-only, got f=%+v delta=%+v", fids3, dids3)
	}

	// 8. Config change during maintenance is suppressed, outside maintenance is URGENT
	cfgMsg, _ := ParseLine(`<37>1 2026-11-27T19:03:00Z chief-tui-opn audit 100 - - configuration changed on /conf/config.xml`, now)
	cfgMsg.ReceivedAt = now
	if fc, _ := det.Process(cfgMsg, true); fc != nil {
		t.Fatalf("expected config change suppressed during maintenance, got %+v", fc)
	}
	if fc, _ := det.Process(cfgMsg, false); fc == nil || fc.ID != "sec:opnsense:config-change:audit" {
		t.Fatalf("expected unplanned config change urgent finding, got %+v", fc)
	}
}

func TestTCPReceiverOctetCountingAndLineDelimited(t *testing.T) {
	got := make(chan Message, 4)
	rec, err := Listen("127.0.0.1:0", []string{"127.0.0.1"}, func(m Message) {
		got <- m
	})
	if err != nil {
		t.Fatalf("Listen() err: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		done <- rec.Serve(ctx)
	}()

	// Frame 1: RFC 6587 octet-counted via SendFixture
	line1 := `<38>1 2026-11-27T19:00:00Z chief-tui-opn sshd 1 - - Accepted publickey for root from 192.168.30.99 port 1234 ssh2 [SYNTHETIC TEST]`
	if err := SendFixture(rec.Addr(), line1); err != nil {
		t.Fatalf("SendFixture err: %v", err)
	}

	// Frame 2: newline-delimited RFC 5424
	conn, err := net.Dial("tcp", rec.Addr())
	if err != nil {
		t.Fatalf("Dial err: %v", err)
	}
	line2 := "<134>1 2026-11-27T19:00:01Z chief-tui-opn filterlog 2 - - 5,,,aa,igc1,match,block,in,4,0x0,,248,1,0,none,6,tcp,44,198.51.100.2,174.16.196.251,1234,80\n"
	_, _ = conn.Write([]byte(line2))
	_ = conn.Close()

	for i := 0; i < 2; i++ {
		select {
		case msg := <-got:
			if msg.AppName != "sshd" && msg.AppName != "filterlog" {
				t.Fatalf("unexpected app %q", msg.AppName)
			}
		case <-time.After(3 * time.Second):
			t.Fatalf("timed out waiting for syslog message %d", i+1)
		}
	}
	cancel()
	<-done
}
