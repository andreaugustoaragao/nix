package notify

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"faragao.net/netwatch/internal/model"
)

// FormatUrgent formats an immediate actionable email for a single urgent finding.
func FormatUrgent(f model.TrackedFinding, now time.Time) (string, string) {
	prefix := "[faragao-netwatch] URGENT"
	if f.Synthetic {
		prefix = "[SYNTHETIC TEST] [faragao-netwatch] URGENT"
	}
	if f.KEV {
		prefix += " [CISA KEV]"
	}
	subject := fmt.Sprintf("%s: %s (%s)", prefix, f.Title, f.Device)

	var b strings.Builder
	if f.Synthetic {
		b.WriteString("*** SYNTHETIC TEST MESSAGE — SAFE TO IGNORE AS PRODUCTION INCIDENT ***\n\n")
	}
	writeFindingDetails(&b, f)
	b.WriteString(fmt.Sprintf("\nAlert generated: %s\n", now.UTC().Format(time.RFC3339)))
	b.WriteString(fmt.Sprintf("Acknowledge reminder without closing:\n  sudo netwatch-ctl ack --id %q --note \"scheduled maintenance\"\n", f.ID))
	b.WriteString("\nClosure happens automatically only after a clean audit recheck confirms the issue is absent.\n")
	return subject, b.String()
}

// FormatDailyAction formats a grouped daily notice for non-urgent applicable security fixes.
func FormatDailyAction(findings []model.TrackedFinding, st model.State, now time.Time) (string, string) {
	subject := fmt.Sprintf("[faragao-netwatch] Daily Security Action (%d open)", len(findings))

	var b strings.Builder
	b.WriteString(fmt.Sprintf("Daily Security Action Summary (%s)\n", now.UTC().Format("2006-01-02")))
	b.WriteString(strings.Repeat("=", 44) + "\n\n")
	writeFreshnessHeader(&b, st)
	b.WriteString("\n")
	for i, f := range findings {
		b.WriteString(fmt.Sprintf("--- Item %d of %d ---\n", i+1, len(findings)))
		writeFindingDetails(&b, f)
		b.WriteString("\n")
	}
	b.WriteString("Pre-patch procedure:\n")
	b.WriteString("  1. Review release notes & reboot expectation above.\n")
	b.WriteString("  2. Export backup: ./bin/netctl backup capture opnsense --pane t2r --suffix pre-patch\n")
	b.WriteString("  3. Apply update manually in maintenance window; run /usr/local/sbin/opn-audit-export.sh to auto-close.\n")
	return subject, b.String()
}

// FormatWeeklyDigest formats a concise weekly operational digest with freshness, open findings, and routine updates.
func FormatWeeklyDigest(st model.State, digestItems []model.TrackedFinding, synthetic bool, now time.Time) (string, string) {
	subject := fmt.Sprintf("[faragao-netwatch] Weekly Firewall Security & Update Digest (%s)", now.UTC().Format("2006-01-02"))
	if synthetic {
		subject = "[SYNTHETIC TEST] " + subject
	}

	var b strings.Builder
	if synthetic {
		b.WriteString("*** SYNTHETIC TEST DIGEST — VERIFYING DELIVERY PIPELINE ***\n\n")
	}
	b.WriteString("faragao.net Weekly Firewall Security & Update Digest\n")
	b.WriteString(strings.Repeat("=", 52) + "\n\n")

	if st.LatestSnapshot != nil {
		s := st.LatestSnapshot
		b.WriteString(fmt.Sprintf("Device:          %s\n", s.Host))
		b.WriteString(fmt.Sprintf("OPNsense:        %s (%s, series %s)\n", s.ProductVersion, s.Edition, s.ProductSeries))
		b.WriteString(fmt.Sprintf("FreeBSD:         kernel %s / userland %s\n", s.FreeBSDKernel, s.FreeBSDUserland))
		b.WriteString(fmt.Sprintf("Packages:        %d installed (%d plugins)\n", s.PackageCount, len(s.Plugins)))
		b.WriteString(fmt.Sprintf("WAN Exposure:    %s (%d pass rules, %d NAT rdr)\n",
			s.Exposure.WANInterface, len(s.Exposure.WANPassRules), len(s.Exposure.WANRDRRules)))
		b.WriteString("\n")
	} else {
		b.WriteString("Device:          chief-tui-opn (NO SNAPSHOT RECEIVED YET)\n\n")
	}

	writeFreshnessHeader(&b, st)

	var openUrgent, openDaily, acked []model.TrackedFinding
	for _, tf := range st.Findings {
		if tf.Synthetic && !synthetic {
			continue
		}
		if tf.Status == model.StatusResolved {
			continue
		}
		if tf.Status == model.StatusAcked {
			acked = append(acked, *tf)
			continue
		}
		switch tf.Severity {
		case model.SeverityUrgent:
			openUrgent = append(openUrgent, *tf)
		case model.SeverityDaily:
			openDaily = append(openDaily, *tf)
		}
	}
	sort.Slice(openUrgent, func(i, j int) bool { return openUrgent[i].ID < openUrgent[j].ID })
	sort.Slice(openDaily, func(i, j int) bool { return openDaily[i].ID < openDaily[j].ID })
	sort.Slice(acked, func(i, j int) bool { return acked[i].ID < acked[j].ID })

	b.WriteString(fmt.Sprintf("\nOutstanding Findings: urgent=%d, daily=%d, acknowledged=%d\n",
		len(openUrgent), len(openDaily), len(acked)))
	for _, tf := range append(openUrgent, append(openDaily, acked...)...) {
		ackTag := ""
		if tf.Status == model.StatusAcked {
			ackTag = fmt.Sprintf(" [ACKED: %s]", tf.AckNote)
		}
		b.WriteString(fmt.Sprintf("  - [%s] %s (%s)%s | running=%s -> fixed=%s\n",
			tf.Severity, tf.Title, tf.ID, ackTag, tf.RunningVersion, tf.FixedVersion))
	}

	b.WriteString(fmt.Sprintf("\nRoutine Releases / Updates (%d):\n", len(digestItems)))
	if len(digestItems) == 0 {
		b.WriteString("  - None pending.\n")
	} else {
		for _, tf := range digestItems {
			b.WriteString(fmt.Sprintf("  - %s | %s -> %s (reboot: %s)\n", tf.Title, tf.RunningVersion, tf.FixedVersion, tf.RebootExpected))
		}
	}

	b.WriteString("\nKnown Monitoring Scope & Visibility Limits (TRK-30 + TRK-31):\n")
	b.WriteString("  - Audit/advisories: OPNsense edition/build/plugins, pkg audit VuXML, CISA KEV, Core/Plugins GHSA, Forum RSS, Healthchecks.io heartbeat.\n")
	b.WriteString("  - Live North-South telemetry (chief-tui-opn): WAN igc1 (post-NAT) & LAN ix0 (pre-NAT) filterlog/admin/config/Suricata IDS leads via private TCP :5514.\n")
	b.WriteString("  - Visibility gap (East-West): inter-VLAN traffic routed/switched locally on Brocade tamatoa (192.168.0.0/16 -> 192.168.100.1) bypasses chief-tui-opn unless it hits WAN/OPNsense or Wave 10 host logging.\n")
	writeSyslogDigestSection(&b, st)
	return subject, b.String()
}

// FormatResolution formats an email confirming one or more previously reported findings resolved on a clean recheck.
func FormatResolution(resolved []model.TrackedFinding, now time.Time) (string, string) {
	synthetic := len(resolved) > 0 && resolved[0].Synthetic
	subject := fmt.Sprintf("[faragao-netwatch] RESOLVED (%d finding(s))", len(resolved))
	if synthetic {
		subject = "[SYNTHETIC TEST] " + subject
	}
	var b strings.Builder
	if synthetic {
		b.WriteString("*** SYNTHETIC TEST RESOLUTION ***\n\n")
	}
	b.WriteString(fmt.Sprintf("Verified resolved after clean recheck at %s:\n\n", now.UTC().Format(time.RFC3339)))
	for _, f := range resolved {
		b.WriteString(fmt.Sprintf("- %s (%s)\n", f.Title, f.ID))
		b.WriteString(fmt.Sprintf("  Device:   %s\n", f.Device))
		b.WriteString(fmt.Sprintf("  Previous: %s\n", f.RunningVersion))
		b.WriteString(fmt.Sprintf("  Expected: %s\n", f.FixedVersion))
		if f.AckNote != "" {
			b.WriteString(fmt.Sprintf("  Ack Note: %s\n", f.AckNote))
		}
		b.WriteString("\n")
	}
	return subject, b.String()
}

func writeFindingDetails(b *strings.Builder, f model.TrackedFinding) {
	b.WriteString(fmt.Sprintf("ID:                 %s\n", f.ID))
	b.WriteString(fmt.Sprintf("Device:             %s\n", f.Device))
	b.WriteString(fmt.Sprintf("Severity:           %s (KEV=%v)\n", strings.ToUpper(f.Severity), f.KEV))
	b.WriteString(fmt.Sprintf("Status:             %s\n", f.Status))
	b.WriteString(fmt.Sprintf("Title:              %s\n", f.Title))
	b.WriteString(fmt.Sprintf("Running Version:    %s\n", f.RunningVersion))
	b.WriteString(fmt.Sprintf("Fixed / Action:     %s\n", f.FixedVersion))
	if f.Mitigation != "" {
		b.WriteString(fmt.Sprintf("Mitigation / KEV:   %s\n", f.Mitigation))
	}
	b.WriteString(fmt.Sprintf("Exposure:           %s\n", f.Exposure))
	b.WriteString(fmt.Sprintf("Reboot Expected:    %s\n", f.RebootExpected))
	b.WriteString(fmt.Sprintf("Recommended Timing: %s\n", f.RecommendedTiming))
	if len(f.CVEs) > 0 {
		b.WriteString(fmt.Sprintf("CVEs:               %s\n", strings.Join(f.CVEs, ", ")))
	}
	if len(f.Sources) > 0 {
		b.WriteString(fmt.Sprintf("Sources:            %s\n", strings.Join(f.Sources, ", ")))
	}
	b.WriteString(fmt.Sprintf("Summary:            %s\n", f.Summary))
}

func writeFreshnessHeader(b *strings.Builder, st model.State) {
	b.WriteString("Freshness:\n")
	if st.LatestSnapshot != nil {
		b.WriteString(fmt.Sprintf("  - OPNsense audit snapshot: %s (audit_ok=%v)\n",
			st.LatestSnapshot.CollectedAt.UTC().Format(time.RFC3339), st.LatestSnapshot.AuditOK))
	} else {
		b.WriteString("  - OPNsense audit snapshot: NEVER\n")
	}
	if !st.LastHeartbeatOK.IsZero() {
		b.WriteString(fmt.Sprintf("  - Last good Healthchecks ping: %s\n", st.LastHeartbeatOK.UTC().Format(time.RFC3339)))
	} else {
		b.WriteString("  - Last good Healthchecks ping: NEVER\n")
	}
	if !st.Syslog.LastReceived.IsZero() {
		b.WriteString(fmt.Sprintf("  - Last firewall syslog event:   %s (total=%d)\n",
			st.Syslog.LastReceived.UTC().Format(time.RFC3339), st.Syslog.TotalReceived))
	} else {
		b.WriteString("  - Last firewall syslog event:   NEVER\n")
	}
	keys := make([]string, 0, len(st.FeedStatus))
	for k := range st.FeedStatus {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		fs := st.FeedStatus[k]
		lastOK := "never"
		if !fs.LastSuccess.IsZero() {
			lastOK = fs.LastSuccess.UTC().Format(time.RFC3339)
		}
		errNote := ""
		if fs.LastError != "" {
			errNote = fmt.Sprintf(" [ERR: %s]", fs.LastError)
		}
		b.WriteString(fmt.Sprintf("  - Feed %-24s last_ok=%s (%d items)%s\n", fs.Name+":", lastOK, fs.ItemCount, errNote))
	}
}

func writeSyslogDigestSection(b *strings.Builder, st model.State) {
	b.WriteString("\nFirewall Telemetry & Aggregated Routine Scans (TRK-31):\n")
	b.WriteString(fmt.Sprintf("  - Total syslog events:       %d\n", st.Syslog.TotalReceived))
	b.WriteString(fmt.Sprintf("  - Routine WAN blocks (in):   %d (aggregated)\n", st.Syslog.WANBlockedIn))
	b.WriteString(fmt.Sprintf("  - Internal outbound blocks:  %d\n", st.Syslog.InternalOutboundBlocked))
	b.WriteString(fmt.Sprintf("  - Expected admin logins:     %d\n", st.Syslog.ExpectedAdminLogins))
	b.WriteString(fmt.Sprintf("  - IDS alerts (urgent/digest): %d / %d\n", st.Syslog.IDSAlertsUrgent, st.Syslog.IDSAlertsDigest))
	if len(st.Syslog.TopBlockedPorts) > 0 {
		type portCnt struct {
			port string
			cnt  int64
		}
		top := make([]portCnt, 0, len(st.Syslog.TopBlockedPorts))
		for p, c := range st.Syslog.TopBlockedPorts {
			top = append(top, portCnt{port: p, cnt: c})
		}
		sort.Slice(top, func(i, j int) bool {
			if top[i].cnt != top[j].cnt {
				return top[i].cnt > top[j].cnt
			}
			return top[i].port < top[j].port
		})
		limit := len(top)
		if limit > 5 {
			limit = 5
		}
		parts := make([]string, 0, limit)
		for i := 0; i < limit; i++ {
			parts = append(parts, fmt.Sprintf("%s=%d", top[i].port, top[i].cnt))
		}
		b.WriteString(fmt.Sprintf("  - Top blocked WAN ports:     %s\n", strings.Join(parts, ", ")))
	}
}
