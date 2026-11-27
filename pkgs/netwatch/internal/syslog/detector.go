package syslog

import (
	"fmt"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"faragao.net/netwatch/internal/model"
)

// Policy defines expected firewall/admin baselines and anomaly thresholds.
type Policy struct {
	Device                      string
	AllowedAdminUsers           []string
	AllowedAdminCIDRs           []string
	WANInterface                string
	AllowedWANInboundPorts      []int
	HighRiskOutboundPorts       []int
	AuthFailThreshold           int
	OutboundScanPortThreshold   int
	OutboundBlockBurstThreshold int
	DNSBlockBurstThreshold      int
	Window                      time.Duration
}

// StatsDelta summarizes counters emitted from a processed syslog line.
type StatsDelta struct {
	WANBlockedIn            int64
	InternalOutboundBlocked int64
	ExpectedAdminLogins     int64
	IDSAlertsUrgent         int64
	IDSAlertsDigest         int64
	BlockedPort             string
}

type portSample struct {
	ts   time.Time
	port int
}

// Detector correlates parsed OPNsense syslog/IDS messages against expected baselines.
type Detector struct {
	mu               sync.Mutex
	device           string
	allowedUsers     map[string]bool
	allowedCIDRs     []netip.Prefix
	wanInterface     string
	allowedWANPorts  map[int]bool
	highRiskOutPorts map[int]bool
	authFailThresh   int
	scanPortThresh   int
	blockBurstThresh int
	dnsBurstThresh   int
	window           time.Duration

	authFails      map[string][]time.Time
	outboundPorts  map[string][]portSample
	outboundBlocks map[string][]time.Time
	dnsBlocks      map[string][]time.Time
}

var (
	sshAcceptedRe = regexp.MustCompile(`\bAccepted\s+(\S+)\s+for\s+(?:invalid\s+user\s+)?(\S+)\s+from\s+([0-9A-Fa-f:.]+)`)
	sshFailedRe   = regexp.MustCompile(`(?:\bFailed\s+\S+|\bInvalid\s+user)\s+(?:for\s+(?:invalid\s+user\s+)?)?\S*\s*from\s+([0-9A-Fa-f:.]+)`)
	webLoginRe    = regexp.MustCompile(`(?i)Successful login for user '([^']+)' from:\s*([0-9A-Fa-f:.]+)`)
	opnAuditOKRe  = regexp.MustCompile(`(?i)\buser\s+(\S+)\s+authenticated successfully for\s+([^\s\[]+)(?:.*?\bat\s+([0-9A-Fa-f:.]+|-))?`)
	opnAuditErrRe = regexp.MustCompile(`(?i)(?:authentication error|failed login|error authenticating).*?(?:from|at)\s+([0-9A-Fa-f:.]+)`)
	sudoLineRe    = regexp.MustCompile(`^\s*([A-Za-z0-9._-]+)\s*:\s*TTY=.*;\s*COMMAND=(.+)$`)

	suricataFullRe  = regexp.MustCompile(`\[(\d+):(\d+):(\d+)\]\s+(.+?)\s+\[Classification:\s*([^\]]+)\]\s*\[Priority:\s*(\d+)\]\s*\{([^}]+)\}\s*([0-9A-Fa-f:.]+)(?::\d+)?\s*->\s*([0-9A-Fa-f:.]+)(?::\d+)?`)
	suricataShortRe = regexp.MustCompile(`\[(\d+):(\d+):(\d+)\]\s+(.+?)\s+\[Priority:\s*(\d+)\]\s*\{([^}]+)\}\s*([0-9A-Fa-f:.]+)(?::\d+)?\s*->\s*([0-9A-Fa-f:.]+)(?::\d+)?`)
)

// NewDetector constructs a thread-safe syslog anomaly detector with sane defaults.
func NewDetector(p Policy) *Detector {
	dev := strings.TrimSpace(p.Device)
	if dev == "" {
		dev = "chief-tui-opn.faragao.net"
	}
	wanIf := strings.TrimSpace(p.WANInterface)
	if wanIf == "" {
		wanIf = "igc1"
	}
	users := make(map[string]bool)
	for _, u := range p.AllowedAdminUsers {
		if t := strings.ToLower(strings.TrimSpace(u)); t != "" {
			users[t] = true
		}
	}
	if len(users) == 0 {
		users["andre"] = true
	}

	var prefixes []netip.Prefix
	for _, raw := range p.AllowedAdminCIDRs {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		if pfx, err := netip.ParsePrefix(raw); err == nil {
			prefixes = append(prefixes, pfx)
		} else if addr, err := netip.ParseAddr(raw); err == nil {
			bits := 32
			if addr.Is6() {
				bits = 128
			}
			prefixes = append(prefixes, netip.PrefixFrom(addr, bits))
		}
	}

	allowedWAN := make(map[int]bool)
	for _, port := range p.AllowedWANInboundPorts {
		if port > 0 {
			allowedWAN[port] = true
		}
	}
	if len(allowedWAN) == 0 {
		allowedWAN[443] = true
	}

	highRisk := make(map[int]bool)
	ports := p.HighRiskOutboundPorts
	if len(ports) == 0 {
		ports = []int{23, 445, 3389, 4444, 5900, 6667, 9001, 9050}
	}
	for _, port := range ports {
		if port > 0 {
			highRisk[port] = true
		}
	}

	authThresh := p.AuthFailThreshold
	if authThresh <= 0 {
		authThresh = 5
	}
	scanThresh := p.OutboundScanPortThreshold
	if scanThresh <= 0 {
		scanThresh = 20
	}
	blockThresh := p.OutboundBlockBurstThreshold
	if blockThresh <= 0 {
		blockThresh = 30
	}
	dnsThresh := p.DNSBlockBurstThreshold
	if dnsThresh <= 0 {
		dnsThresh = 50
	}
	win := p.Window
	if win <= 0 {
		win = 10 * time.Minute
	}

	return &Detector{
		device:           dev,
		allowedUsers:     users,
		allowedCIDRs:     prefixes,
		wanInterface:     wanIf,
		allowedWANPorts:  allowedWAN,
		highRiskOutPorts: highRisk,
		authFailThresh:   authThresh,
		scanPortThresh:   scanThresh,
		blockBurstThresh: blockThresh,
		dnsBurstThresh:   dnsThresh,
		window:           win,
		authFails:        make(map[string][]time.Time),
		outboundPorts:    make(map[string][]portSample),
		outboundBlocks:   make(map[string][]time.Time),
		dnsBlocks:        make(map[string][]time.Time),
	}
}

// Process evaluates one parsed syslog message and returns an optional finding + stats delta.
func (d *Detector) Process(msg Message, maintenanceActive bool) (*model.Finding, StatsDelta) {
	now := msg.ReceivedAt
	if now.IsZero() {
		now = time.Now().UTC()
	}
	device := d.device
	if strings.TrimSpace(msg.Host) != "" && msg.Host != "unknown" {
		device = msg.Host
	}
	app := strings.ToLower(strings.TrimSpace(msg.AppName))

	var f *model.Finding
	var delta StatsDelta

	switch app {
	case "filterlog":
		f, delta = d.processFilterLog(msg, device, now)
	case "sshd":
		f, delta = d.processSSHD(msg, device, now)
	case "audit", "opnsense", "lighttpd", "sudo", "configd.py":
		f, delta = d.processAuditOrConfig(app, msg, device, now, maintenanceActive)
	case "suricata":
		f, delta = d.processSuricata(msg, device, now)
	}

	if f != nil && msg.Synthetic {
		f.Synthetic = true
		if !strings.HasPrefix(f.ID, "synthetic:") {
			f.ID = "synthetic:" + f.ID
		}
	}
	return f, delta
}

func (d *Detector) processFilterLog(msg Message, device string, now time.Time) (*model.Finding, StatsDelta) {
	fl, ok := ParseFilterLog(msg.Body)
	if !ok {
		return nil, StatsDelta{}
	}
	portNum, _ := strconv.Atoi(fl.DstPort)
	isTransport := fl.Proto == "tcp" || fl.Proto == "udp"

	// 1. Routine WAN inbound blocks are aggregated into digest counters only.
	if fl.Interface == d.wanInterface && fl.Action == "block" && fl.Dir == "in" {
		bp := fl.Proto
		if fl.DstPort != "" {
			bp += "/" + fl.DstPort
		}
		return nil, StatsDelta{WANBlockedIn: 1, BlockedPort: bp}
	}

	// 2. Unexpected WAN inbound pass rule match on non-allowed port.
	if fl.Interface == d.wanInterface && fl.Action == "pass" && fl.Dir == "in" && isTransport && portNum > 0 && !d.allowedWANPorts[portNum] {
		return d.newSecurityFinding(
			fmt.Sprintf("sec:opnsense:wan-pass:%s:%d", fl.Proto, portNum),
			model.SeverityUrgent,
			device,
			fmt.Sprintf("Unexpected WAN inbound %s/%d pass detected", strings.ToUpper(fl.Proto), portNum),
			fmt.Sprintf("filterlog matched pass-in on WAN %s (%s -> %s:%d). Evidence: %s",
				fl.Interface, fl.SrcIP, fl.DstIP, portNum, RedactEvidence(msg.Body)),
			"Verify OPNsense Firewall -> Rules -> WAN & NAT Port Forward",
			"Immediate inspection — unexpected WAN ingress pass",
			[]string{"opnsense-filterlog"},
			now,
		), StatsDelta{}
	}

	// 3. High-risk outbound port pass to public IP.
	if fl.Action == "pass" && isTransport && d.highRiskOutPorts[portNum] && isPublicIP(fl.DstIP) {
		return d.newSecurityFinding(
			fmt.Sprintf("sec:opnsense:outbound-highrisk:%s:%d", fl.SrcIP, portNum),
			model.SeverityUrgent,
			device,
			fmt.Sprintf("High-risk outbound connection %s -> port %d (%s)", fl.SrcIP, portNum, strings.ToUpper(fl.Proto)),
			fmt.Sprintf("filterlog allowed outbound %s:%s -> %s:%d on %s. Evidence: %s",
				fl.SrcIP, fl.SrcPort, fl.DstIP, portNum, fl.Interface, RedactEvidence(msg.Body)),
			fmt.Sprintf("Isolate host %s and inspect active connections/processes", fl.SrcIP),
			"Immediate investigation",
			[]string{"opnsense-filterlog"},
			now,
		), StatsDelta{}
	}

	// 4. Outbound port-scan burst from internal RFC1918 host to public targets.
	if isPrivateRFC1918(fl.SrcIP) && isPublicIP(fl.DstIP) && isTransport && portNum > 0 && !isStandardOutboundPort(portNum) {
		distinctCount := d.recordOutboundPort(windowKey(msg.Synthetic, fl.SrcIP), portNum, now)
		if distinctCount >= d.scanPortThresh {
			return d.newSecurityFinding(
				fmt.Sprintf("sec:opnsense:outbound-scan:%s", fl.SrcIP),
				model.SeverityUrgent,
				device,
				fmt.Sprintf("Suspicious internal outbound port scan from %s (%d distinct ports)", fl.SrcIP, distinctCount),
				fmt.Sprintf("Internal host %s probed %d distinct non-standard public destination ports within %s (latest %s:%d). Evidence: %s",
					fl.SrcIP, distinctCount, d.window, fl.DstIP, portNum, RedactEvidence(msg.Body)),
				fmt.Sprintf("Inspect internal host %s for malware/unauthorized scanner", fl.SrcIP),
				"Immediate check",
				[]string{"opnsense-filterlog"},
				now,
			), StatsDelta{}
		}
	}

	// 5. Internal outbound blocked burst (e.g. blocked hardcoded DNS or botnet egress).
	if fl.Action == "block" && isPrivateRFC1918(fl.SrcIP) {
		delta := StatsDelta{InternalOutboundBlocked: 1}
		if isTransport && (portNum == 53 || portNum == 853) {
			count := d.recordBurst(d.dnsBlocks, windowKey(msg.Synthetic, fl.SrcIP), now)
			if count >= d.dnsBurstThresh {
				return d.newSecurityFinding(
					fmt.Sprintf("sec:opnsense:outbound-blocked-burst:%s", fl.SrcIP),
					model.SeverityDaily,
					device,
					fmt.Sprintf("Repeated blocked DNS egress from %s (%d attempts)", fl.SrcIP, count),
					fmt.Sprintf("Internal host %s hit %d blocked outbound DNS (%d) attempts in %s. Evidence: %s",
						fl.SrcIP, count, portNum, d.window, RedactEvidence(msg.Body)),
					fmt.Sprintf("Check DNS configuration on %s (or expected IoT telemetry block)", fl.SrcIP),
					"Review in daily security notice",
					[]string{"opnsense-filterlog"},
					now,
				), delta
			}
		} else {
			count := d.recordBurst(d.outboundBlocks, windowKey(msg.Synthetic, fl.SrcIP), now)
			if count >= d.blockBurstThresh {
				return d.newSecurityFinding(
					fmt.Sprintf("sec:opnsense:outbound-blocked-burst:%s", fl.SrcIP),
					model.SeverityDaily,
					device,
					fmt.Sprintf("Repeated blocked outbound traffic from %s (%d attempts)", fl.SrcIP, count),
					fmt.Sprintf("Internal host %s hit %d blocked outbound attempts in %s (latest %s:%s). Evidence: %s",
						fl.SrcIP, count, d.window, fl.DstIP, fl.DstPort, RedactEvidence(msg.Body)),
					fmt.Sprintf("Review firewall filter logs and host %s", fl.SrcIP),
					"Review in daily security notice",
					[]string{"opnsense-filterlog"},
					now,
				), delta
			}
		}
		return nil, delta
	}

	return nil, StatsDelta{}
}

func (d *Detector) processSSHD(msg Message, device string, now time.Time) (*model.Finding, StatsDelta) {
	if m := sshAcceptedRe.FindStringSubmatch(msg.Body); len(m) == 4 {
		method, user, srcIP := m[1], m[2], m[3]
		if !d.allowedUsers[strings.ToLower(user)] || strings.EqualFold(method, "password") || !d.isAllowedAdminIP(srcIP) {
			return d.newSecurityFinding(
				fmt.Sprintf("sec:opnsense:admin-ssh:%s:%s", user, srcIP),
				model.SeverityUrgent,
				device,
				fmt.Sprintf("Unexpected SSH admin login: %s from %s (%s)", user, srcIP, method),
				fmt.Sprintf("sshd accepted %s for %s from %s (allowed users=%s, sources=%s). Evidence: %s",
					method, user, srcIP, d.usersSummary(), d.cidrsSummary(), RedactEvidence(msg.Body)),
				"Verify operator SSH session; if unauthorized rotate keys and review /var/log/audit/latest.log",
				"Immediate verification required",
				[]string{"opnsense-sshd"},
				now,
			), StatsDelta{}
		}
		return nil, StatsDelta{ExpectedAdminLogins: 1}
	}

	if m := sshFailedRe.FindStringSubmatch(msg.Body); len(m) == 2 {
		srcIP := m[1]
		count := d.recordBurst(d.authFails, windowKey(msg.Synthetic, srcIP), now)
		if count >= d.authFailThresh {
			return d.newSecurityFinding(
				fmt.Sprintf("sec:opnsense:auth-bruteforce:%s", srcIP),
				model.SeverityUrgent,
				device,
				fmt.Sprintf("Repeated firewall authentication failures from %s (%d in %s)", srcIP, count, d.window),
				fmt.Sprintf("%d failed SSH/admin login attempts from %s within %s. Evidence: %s",
					count, srcIP, d.window, RedactEvidence(msg.Body)),
				fmt.Sprintf("Verify source IP %s and ensure sshd/WebGUI stays key/2FA-only", srcIP),
				"Immediate check",
				[]string{"opnsense-sshd"},
				now,
			), StatsDelta{}
		}
	}

	return nil, StatsDelta{}
}

func (d *Detector) processAuditOrConfig(app string, msg Message, device string, now time.Time, maintenanceActive bool) (*model.Finding, StatsDelta) {
	body := msg.Body
	lower := strings.ToLower(body)

	// Ignore normal read-only OPNsense configd health/export actions.
	if app == "configd.py" {
		if strings.Contains(lower, "action allowed interface.") ||
			strings.Contains(lower, "action allowed system.status") ||
			strings.Contains(lower, "action allowed firmware.status") ||
			strings.Contains(lower, "action allowed opn_audit_export") {
			return nil, StatsDelta{}
		}
	}

	// WebGUI explicit login patterns
	if m := webLoginRe.FindStringSubmatch(body); len(m) == 3 {
		user, srcIP := m[1], m[2]
		if !d.allowedUsers[strings.ToLower(user)] || !d.isAllowedAdminIP(srcIP) {
			return d.newSecurityFinding(
				fmt.Sprintf("sec:opnsense:admin-webgui:%s:%s", user, srcIP),
				model.SeverityUrgent,
				device,
				fmt.Sprintf("Unexpected WebGUI login: %s from %s", user, srcIP),
				fmt.Sprintf("OPNsense WebGUI login succeeded for %s from %s (allowed sources=%s). Evidence: %s",
					user, srcIP, d.cidrsSummary(), RedactEvidence(body)),
				"Confirm WebGUI access path and TOTP session; check firewall rules on :443",
				"Immediate verification required",
				[]string{"opnsense-audit"},
				now,
			), StatsDelta{}
		}
		return nil, StatsDelta{ExpectedAdminLogins: 1}
	}

	if m := opnAuditOKRe.FindStringSubmatch(body); len(m) == 4 {
		user, svc, src := m[1], m[2], m[3]
		svcLower := strings.ToLower(svc)
		if strings.Contains(svcLower, "webgui") {
			if !d.allowedUsers[strings.ToLower(user)] || (src != "" && src != "-" && !d.isAllowedAdminIP(src)) {
				srcLabel := src
				if srcLabel == "" || srcLabel == "-" {
					srcLabel = "unknown"
				}
				return d.newSecurityFinding(
					fmt.Sprintf("sec:opnsense:admin-webgui:%s:%s", user, srcLabel),
					model.SeverityUrgent,
					device,
					fmt.Sprintf("Unexpected WebGUI login: %s from %s", user, srcLabel),
					fmt.Sprintf("OPNsense audit recorded %s WebGUI authentication from %s. Evidence: %s",
						user, srcLabel, RedactEvidence(body)),
					"Verify WebGUI session and allowed admin IPs",
					"Immediate verification required",
					[]string{"opnsense-audit"},
					now,
				), StatsDelta{}
			}
			return nil, StatsDelta{ExpectedAdminLogins: 1}
		}
		if strings.Contains(svcLower, "sudo") {
			if !d.allowedUsers[strings.ToLower(user)] && !strings.EqualFold(user, "root") {
				return d.newSecurityFinding(
					fmt.Sprintf("sec:opnsense:admin-sudo:%s", user),
					model.SeverityUrgent,
					device,
					fmt.Sprintf("Unexpected user %s authenticated for sudo on firewall", user),
					fmt.Sprintf("OPNsense audit recorded sudo authentication for non-allowlisted user %s. Evidence: %s",
						user, RedactEvidence(body)),
					"Verify operator session and /etc/sudoers on OPNsense",
					"Immediate verification required",
					[]string{"opnsense-audit"},
					now,
				), StatsDelta{}
			}
			return nil, StatsDelta{ExpectedAdminLogins: 1}
		}
	}

	if app == "sudo" {
		if m := sudoLineRe.FindStringSubmatch(body); len(m) == 3 {
			user := m[1]
			if !d.allowedUsers[strings.ToLower(user)] && !strings.EqualFold(user, "root") {
				return d.newSecurityFinding(
					fmt.Sprintf("sec:opnsense:admin-sudo:%s", user),
					model.SeverityUrgent,
					device,
					fmt.Sprintf("Unexpected sudo execution by user %s on firewall", user),
					fmt.Sprintf("Non-allowlisted user %s invoked sudo. Evidence: %s", user, RedactEvidence(body)),
					"Inspect SSH/auth logs on chief-tui-opn via Herdr",
					"Immediate verification required",
					[]string{"opnsense-sudo"},
					now,
				), StatsDelta{}
			}
		}
		return nil, StatsDelta{}
	}

	// Failed audit logins
	if strings.Contains(lower, "authentication error") || strings.Contains(lower, "failed login") || strings.Contains(lower, "error authenticating") {
		srcIP := "unknown"
		if m := opnAuditErrRe.FindStringSubmatch(body); len(m) == 2 {
			srcIP = m[1]
		}
		count := d.recordBurst(d.authFails, windowKey(msg.Synthetic, srcIP), now)
		if count >= d.authFailThresh {
			return d.newSecurityFinding(
				fmt.Sprintf("sec:opnsense:auth-bruteforce:%s", srcIP),
				model.SeverityUrgent,
				device,
				fmt.Sprintf("Repeated firewall authentication failures from %s (%d in %s)", srcIP, count, d.window),
				fmt.Sprintf("%d failed OPNsense authentication attempts from %s within %s. Evidence: %s",
					count, srcIP, d.window, RedactEvidence(body)),
				"Verify source IP and review /var/log/audit/latest.log",
				"Immediate check",
				[]string{"opnsense-audit"},
				now,
			), StatsDelta{}
		}
		return nil, StatsDelta{}
	}

	// Unplanned config/firewall/user changes outside declared maintenance
	if isConfigMutation(lower) && !maintenanceActive {
		return d.newSecurityFinding(
			fmt.Sprintf("sec:opnsense:config-change:%s", app),
			model.SeverityUrgent,
			device,
			fmt.Sprintf("Unplanned OPNsense configuration change detected (%s)", app),
			fmt.Sprintf("Configuration/rule mutation logged outside maintenance window. Evidence: %s", RedactEvidence(body)),
			"Verify config diff on chief-tui-opn via System -> Configuration -> History; capture backup if intentional",
			"Immediate check unless declared maintenance",
			[]string{"opnsense-" + app},
			now,
		), StatsDelta{}
	}

	return nil, StatsDelta{}
}

func (d *Detector) processSuricata(msg Message, device string, now time.Time) (*model.Finding, StatsDelta) {
	body := msg.Body
	var sid, sig, class, priStr, proto, srcIP, dstIP string
	if m := suricataFullRe.FindStringSubmatch(body); len(m) == 10 {
		sid, sig, class, priStr, proto, srcIP, dstIP = m[2], m[4], m[5], m[6], m[7], m[8], m[9]
	} else if m := suricataShortRe.FindStringSubmatch(body); len(m) == 9 {
		sid, sig, priStr, proto, srcIP, dstIP = m[2], m[4], m[5], m[6], m[7], m[8]
	} else {
		return nil, StatsDelta{}
	}
	srcIP = stripEndpointPort(srcIP)
	dstIP = stripEndpointPort(dstIP)
	priNum, _ := strconv.Atoi(priStr)

	if priNum == 1 || isHighConfidenceIDSClass(class) {
		title := fmt.Sprintf("IDS lead (uncorroborated): %s [SID %s]", strings.TrimSpace(sig), sid)
		summary := fmt.Sprintf("IDS lead (uncorroborated) %s %s -> %s (Class=%q, Priority=%s). Redacted line: %s",
			strings.ToUpper(proto), srcIP, dstIP, class, priStr, RedactEvidence(body))
		return d.newSecurityFinding(
			fmt.Sprintf("sec:opnsense:ids-lead:%s:%s", sid, srcIP),
			model.SeverityUrgent,
			device,
			title,
			summary,
			fmt.Sprintf("Corroborate SID %s against filterlog/host processes before blocking; ack if verified benign/false positive", sid),
			"Corroborate IDS lead promptly",
			[]string{"opnsense-suricata-ids"},
			now,
		), StatsDelta{IDSAlertsUrgent: 1}
	}

	return nil, StatsDelta{IDSAlertsDigest: 1}
}

func (d *Detector) newSecurityFinding(id, sev, device, title, summary, fixedAction, timing string, sources []string, now time.Time) *model.Finding {
	return &model.Finding{
		ID:                id,
		Category:          model.CategorySecurityEvent,
		Severity:          sev,
		Device:            device,
		Title:             title,
		Summary:           summary,
		RunningVersion:    "live-syslog",
		FixedVersion:      fixedAction,
		Exposure:          fmt.Sprintf("WAN=%s (OPNsense pre-NAT ix0 / post-NAT igc1; tamatoa East-West bypasses OPNsense)", d.wanInterface),
		RebootExpected:    "no",
		RecommendedTiming: timing,
		Sources:           sources,
		FirstSeen:         now,
		LastSeen:          now,
	}
}

func (d *Detector) isAllowedAdminIP(raw string) bool {
	addr, err := netip.ParseAddr(strings.TrimSpace(raw))
	if err != nil {
		return false
	}
	for _, pfx := range d.allowedCIDRs {
		if pfx.Contains(addr) {
			return true
		}
	}
	return false
}

func (d *Detector) recordBurst(store map[string][]time.Time, key string, now time.Time) int {
	d.mu.Lock()
	defer d.mu.Unlock()
	cutoff := now.Add(-d.window)
	prev := store[key]
	kept := prev[:0]
	for _, ts := range prev {
		if !ts.Before(cutoff) {
			kept = append(kept, ts)
		}
	}
	kept = append(kept, now)
	store[key] = kept
	return len(kept)
}

func (d *Detector) recordOutboundPort(key string, port int, now time.Time) int {
	d.mu.Lock()
	defer d.mu.Unlock()
	cutoff := now.Add(-d.window)
	prev := d.outboundPorts[key]
	kept := prev[:0]
	distinct := make(map[int]struct{})
	for _, s := range prev {
		if !s.ts.Before(cutoff) {
			kept = append(kept, s)
			distinct[s.port] = struct{}{}
		}
	}
	kept = append(kept, portSample{ts: now, port: port})
	distinct[port] = struct{}{}
	d.outboundPorts[key] = kept
	return len(distinct)
}

func (d *Detector) usersSummary() string {
	out := make([]string, 0, len(d.allowedUsers))
	for u := range d.allowedUsers {
		out = append(out, u)
	}
	return strings.Join(out, ",")
}

func (d *Detector) cidrsSummary() string {
	out := make([]string, 0, len(d.allowedCIDRs))
	for _, p := range d.allowedCIDRs {
		out = append(out, p.String())
	}
	return strings.Join(out, ",")
}

func windowKey(synthetic bool, key string) string {
	if synthetic {
		return "syn:" + key
	}
	return "real:" + key
}

func isPrivateRFC1918(raw string) bool {
	addr, err := netip.ParseAddr(strings.TrimSpace(raw))
	if err != nil {
		return false
	}
	return addr.IsPrivate()
}

func isPublicIP(raw string) bool {
	addr, err := netip.ParseAddr(strings.TrimSpace(raw))
	if err != nil {
		return false
	}
	return !addr.IsPrivate() && !addr.IsLoopback() && !addr.IsLinkLocalUnicast() && !addr.IsLinkLocalMulticast() && !addr.IsMulticast() && !addr.IsUnspecified()
}

func stripEndpointPort(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if ap, err := netip.ParseAddrPort(trimmed); err == nil {
		return ap.Addr().String()
	}
	if addr, err := netip.ParseAddr(trimmed); err == nil {
		return addr.String()
	}
	return trimmed
}

func isStandardOutboundPort(port int) bool {
	return port == 53 || port == 80 || port == 123 || port == 443 || port == 853
}

func isConfigMutation(lowerBody string) bool {
	if strings.Contains(lowerBody, "configuration changed") ||
		strings.Contains(lowerBody, "config.xml") ||
		strings.Contains(lowerBody, "firewall_rules") ||
		strings.Contains(lowerBody, "firewall_nat") ||
		strings.Contains(lowerBody, "system_usermanager") ||
		strings.Contains(lowerBody, "opnsense-config") {
		return true
	}
	if strings.Contains(lowerBody, "sshd") && (strings.Contains(lowerBody, "reconfig") || strings.Contains(lowerBody, "saved") || strings.Contains(lowerBody, "apply")) {
		return true
	}
	if strings.Contains(lowerBody, "filter.reload") && (strings.Contains(lowerBody, "save") || strings.Contains(lowerBody, "edit") || strings.Contains(lowerBody, "apply")) {
		return true
	}
	return false
}

func isHighConfidenceIDSClass(class string) bool {
	lc := strings.ToLower(class)
	for _, needle := range []string{
		"trojan",
		"malware",
		"exploit",
		"command and control",
		"botnet",
		"c2",
		"compromised",
		"web application attack",
	} {
		if strings.Contains(lc, needle) {
			return true
		}
	}
	return false
}
