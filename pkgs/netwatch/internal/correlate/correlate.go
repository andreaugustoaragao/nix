package correlate

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"faragao.net/netwatch/internal/feeds"
	"faragao.net/netwatch/internal/model"
	"faragao.net/netwatch/internal/version"
)

const (
	DefaultStaleAfter = 50 * time.Hour // >2 missed daily cycles
)

var exposedCorePackages = map[string]bool{
	"opnsense":         true,
	"opnsense-update":  true,
	"openssl":          true,
	"unbound":          true,
	"dnsmasq":          true,
	"openssh":          true,
	"openssh-portable": true,
	"curl":             true,
	"ca_root_nss":      true,
	"kernel":           true,
	"base":             true,
	"strongswan":       true,
	"suricata":         true,
	"php85":            true,
}

// EvaluateResult holds the correlated findings plus whether all sources are healthy enough
// for a clean recheck to resolve previously open findings.
type EvaluateResult struct {
	Findings     []model.Finding
	CleanRecheck bool
}

// Evaluate matches OPNsense inventory and package audit output against KEV, GHSAs, and forum notices.
func Evaluate(snap *model.OPNsenseSnapshot, bundle *feeds.FeedBundle, feedStatus map[string]model.FeedStatus, now time.Time, staleAfter time.Duration) EvaluateResult {
	if staleAfter <= 0 {
		staleAfter = DefaultStaleAfter
	}
	var out []model.Finding
	device := "chief-tui-opn"
	if snap != nil && strings.TrimSpace(snap.Host) != "" {
		device = snap.Host
	}

	snapshotFresh := false
	if snap == nil {
		out = append(out, model.Finding{
			ID:                "monitor:opnsense:no-snapshot",
			Category:          "stale_monitor",
			Severity:          model.SeverityUrgent,
			Device:            device,
			Title:             "No OPNsense security audit snapshot received yet",
			Summary:           "netwatch has not received a read-only audit snapshot from the firewall.",
			RunningVersion:    "unknown",
			FixedVersion:      "Verify OPNsense cron and /usr/local/sbin/opn-audit-export.sh",
			Exposure:          "Monitoring blind spot",
			RebootExpected:    "no",
			RecommendedTiming: "Immediate check",
			Sources:           []string{"local-ingest"},
			FirstSeen:         now,
			LastSeen:          now,
		})
	} else {
		age := now.Sub(snap.CollectedAt)
		if age > staleAfter {
			out = append(out, model.Finding{
				ID:                "monitor:opnsense:stale-audit",
				Category:          "stale_monitor",
				Severity:          model.SeverityUrgent,
				Device:            device,
				Title:             fmt.Sprintf("OPNsense security audit is stale (%s old)", age.Round(time.Minute)),
				Summary:           fmt.Sprintf("Last successful firewall snapshot was at %s (threshold %s).", snap.CollectedAt.UTC().Format(time.RFC3339), staleAfter),
				RunningVersion:    snap.ProductVersion,
				FixedVersion:      "Verify OPNsense cron job & HTTP reachability to tala:9400",
				Exposure:          summarizeExposure(snap),
				RebootExpected:    "no",
				RecommendedTiming: "Investigate within 24h",
				Sources:           []string{"local-ingest"},
				FirstSeen:         now,
				LastSeen:          now,
			})
		} else {
			snapshotFresh = true
		}

		if !snap.AuditOK {
			out = append(out, model.Finding{
				ID:                "monitor:opnsense:audit-failed",
				Category:          "stale_monitor",
				Severity:          model.SeverityUrgent,
				Device:            device,
				Title:             "Firewall pkg audit failed during export",
				Summary:           fmt.Sprintf("opn-audit-export reported audit_ok=false: %s", strings.TrimSpace(snap.AuditError)),
				RunningVersion:    snap.ProductVersion,
				FixedVersion:      "Inspect pkg audit -F on chief-tui-opn via Herdr",
				Exposure:          summarizeExposure(snap),
				RebootExpected:    "no",
				RecommendedTiming: "Investigate today",
				Sources:           []string{"local-pkg-audit"},
				FirstSeen:         now,
				LastSeen:          now,
			})
		}
	}

	criticalFeedsHealthy := true
	for _, feedName := range []string{feeds.FeedKEV, feeds.FeedCoreGHSA, feeds.FeedPluginsGHSA, feeds.FeedAnnouncements} {
		st, ok := feedStatus[feedName]
		staleFeed := !ok || st.LastSuccess.IsZero() || now.Sub(st.LastSuccess) > staleAfter
		if staleFeed {
			if feedName == feeds.FeedKEV || feedName == feeds.FeedCoreGHSA {
				criticalFeedsHealthy = false
			}
			lastGood := "never"
			if ok && !st.LastSuccess.IsZero() {
				lastGood = st.LastSuccess.UTC().Format(time.RFC3339)
			}
			out = append(out, model.Finding{
				ID:                "monitor:feed:" + feedName,
				Category:          "stale_monitor",
				Severity:          model.SeverityDaily,
				Device:            "tala-netwatch",
				Title:             fmt.Sprintf("Advisory feed %s refresh is stale or failing", feedName),
				Summary:           fmt.Sprintf("Last good refresh: %s. Last error: %s", lastGood, st.LastError),
				RunningVersion:    "feed-fetcher",
				FixedVersion:      "Check outbound HTTPS / DNS / rate limits on tala",
				Exposure:          "Advisory matching incomplete",
				RebootExpected:    "no",
				RecommendedTiming: "Investigate within 24h",
				Sources:           []string{st.URL},
				FirstSeen:         now,
				LastSeen:          now,
			})
		}
	}

	if snap != nil && bundle != nil {
		out = append(out, evalCoreGHSAs(snap, bundle, device, now)...)
		out = append(out, evalPluginGHSAs(snap, bundle, device, now)...)
		out = append(out, evalPkgAudit(snap, bundle, device, now)...)
		out = append(out, evalFirmwareAndForum(snap, bundle, device, now)...)
	}

	sort.Slice(out, func(i, j int) bool {
		if severityRank(out[i].Severity) != severityRank(out[j].Severity) {
			return severityRank(out[i].Severity) < severityRank(out[j].Severity)
		}
		return out[i].ID < out[j].ID
	})

	cleanRecheck := snapshotFresh && snap != nil && snap.AuditOK && criticalFeedsHealthy
	return EvaluateResult{
		Findings:     out,
		CleanRecheck: cleanRecheck,
	}
}

func evalCoreGHSAs(snap *model.OPNsenseSnapshot, bundle *feeds.FeedBundle, device string, now time.Time) []model.Finding {
	var out []model.Finding
	exposure := summarizeExposure(snap)
	series := strings.TrimSpace(snap.ProductSeries)
	if series == "" {
		series = version.SeriesOf(snap.ProductVersion)
	}

	for _, adv := range bundle.CoreGHSAs {
		matched := false
		fixedSet := make(map[string]struct{})
		for _, v := range adv.Vulnerabilities {
			if version.MatchesRange(snap.ProductVersion, series, snap.Edition, v.VulnerableVersionRange) {
				matched = true
				if strings.TrimSpace(v.PatchedVersions) != "" {
					fixedSet[strings.TrimSpace(v.PatchedVersions)] = struct{}{}
				}
			}
		}
		if !matched {
			continue
		}

		cves := version.ExtractCVEs(adv.CVEID, adv.Summary, adv.Description)
		isKEV, kevReq := checkKEV(cves, bundle.KEVByCVE)
		sev := model.SeverityDaily
		timing := "Apply in next daily/planned window"
		if isKEV || strings.EqualFold(adv.Severity, "critical") || strings.EqualFold(adv.Severity, "high") {
			sev = model.SeverityUrgent
			timing = "Immediate review / patch promptly"
		}
		if isKEV {
			timing = "URGENT (CISA KEV) — patch or mitigate immediately"
		}
		fixed := joinKeys(fixedSet)
		if fixed == "" {
			fixed = "Check vendor mitigation (no patched release listed)"
		}
		out = append(out, model.Finding{
			ID:                "ghsa:core:" + adv.GHSAID,
			Category:          "advisory",
			Severity:          sev,
			Device:            device,
			Title:             fmt.Sprintf("OPNsense %s: %s", adv.GHSAID, adv.Summary),
			Summary:           fmt.Sprintf("Severity=%s; %s", adv.Severity, firstLine(adv.Summary)),
			RunningVersion:    fmt.Sprintf("opnsense %s (%s)", snap.ProductVersion, snap.Edition),
			FixedVersion:      fixed,
			Mitigation:        kevReq,
			Exposure:          exposure,
			RebootExpected:    "Check release notes (usually GUI/service restart unless kernel/base)",
			RecommendedTiming: timing,
			CVEs:              cves,
			KEV:               isKEV,
			Sources:           compactStrings([]string{adv.HTMLURL}),
			FirstSeen:         now,
			LastSeen:          now,
		})
	}
	return out
}

func evalPluginGHSAs(snap *model.OPNsenseSnapshot, bundle *feeds.FeedBundle, device string, now time.Time) []model.Finding {
	if len(snap.Plugins) == 0 {
		return nil
	}
	installed := make(map[string]string, len(snap.Plugins))
	for _, p := range snap.Plugins {
		installed[strings.ToLower(strings.TrimSpace(p.Name))] = p.Version
	}

	var out []model.Finding
	exposure := summarizeExposure(snap)
	for _, adv := range bundle.PluginGHSAs {
		var matchedPkg, runningVer, fixedVer string
		for _, v := range adv.Vulnerabilities {
			pkgName := normalizePluginName(v.Package.Name)
			curVer, ok := installed[pkgName]
			if !ok {
				continue // strictly filter out uninstalled plugins
			}
			if v.VulnerableVersionRange != "" && !version.MatchesPackageRange(curVer, v.VulnerableVersionRange) {
				continue
			}
			matchedPkg = pkgName
			runningVer = curVer
			fixedVer = strings.TrimSpace(v.PatchedVersions)
			break
		}
		if matchedPkg == "" {
			continue
		}
		cves := version.ExtractCVEs(adv.CVEID, adv.Summary, adv.Description)
		isKEV, kevReq := checkKEV(cves, bundle.KEVByCVE)
		sev := model.SeverityDaily
		timing := "Update plugin via System -> Firmware"
		if isKEV || strings.EqualFold(adv.Severity, "critical") || strings.EqualFold(adv.Severity, "high") {
			sev = model.SeverityUrgent
			timing = "Immediate review — installed plugin affected"
		}
		if fixedVer == "" {
			fixedVer = "See plugin advisory"
		}
		out = append(out, model.Finding{
			ID:                fmt.Sprintf("ghsa:plugin:%s:%s", adv.GHSAID, matchedPkg),
			Category:          "advisory",
			Severity:          sev,
			Device:            device,
			Title:             fmt.Sprintf("Plugin %s %s: %s", matchedPkg, adv.GHSAID, adv.Summary),
			Summary:           fmt.Sprintf("Installed plugin %s (%s) matches %s.", matchedPkg, runningVer, adv.GHSAID),
			RunningVersion:    fmt.Sprintf("%s %s", matchedPkg, runningVer),
			FixedVersion:      fixedVer,
			Mitigation:        kevReq,
			Exposure:          exposure,
			RebootExpected:    "no (plugin restart)",
			RecommendedTiming: timing,
			CVEs:              cves,
			KEV:               isKEV,
			Sources:           compactStrings([]string{adv.HTMLURL}),
			FirstSeen:         now,
			LastSeen:          now,
		})
	}
	return out
}

func evalPkgAudit(snap *model.OPNsenseSnapshot, bundle *feeds.FeedBundle, device string, now time.Time) []model.Finding {
	if len(snap.PkgAudit.Packages) == 0 {
		return nil
	}
	var out []model.Finding
	exposure := summarizeExposure(snap)

	pkgNames := make([]string, 0, len(snap.PkgAudit.Packages))
	for k := range snap.PkgAudit.Packages {
		pkgNames = append(pkgNames, k)
	}
	sort.Strings(pkgNames)

	for _, pkgName := range pkgNames {
		pkgInfo := snap.PkgAudit.Packages[pkgName]
		var cves []string
		var descs []string
		var urls []string
		for _, iss := range pkgInfo.Issues {
			cves = append(cves, version.ExtractCVEs(strings.Join(iss.CVE, " "), iss.Description)...)
			if iss.Description != "" {
				descs = append(descs, iss.Description)
			}
			if iss.URL != "" {
				urls = append(urls, iss.URL)
			}
		}
		cves = dedupSorted(cves)
		isKEV, kevReq := checkKEV(cves, bundle.KEVByCVE)
		coreExposed := exposedCorePackages[strings.ToLower(pkgName)] || containsAny(pkgInfo.ReverseDependencies, "unbound", "dnsmasq", "suricata", "strongswan")

		sev := model.SeverityDaily
		timing := "Included in next OPNsense point release (daily security notice)"
		if isKEV {
			sev = model.SeverityUrgent
			timing = "URGENT (CISA KEV) — update or mitigate immediately"
		} else if exposedCorePackages[strings.ToLower(pkgName)] {
			sev = model.SeverityUrgent
			timing = "Urgent — network-facing/core package affected"
		}

		rdeps := "none"
		if len(pkgInfo.ReverseDependencies) > 0 {
			limit := len(pkgInfo.ReverseDependencies)
			if limit > 8 {
				rdeps = fmt.Sprintf("%s (+%d more)", strings.Join(pkgInfo.ReverseDependencies[:8], ", "), limit-8)
			} else {
				rdeps = strings.Join(pkgInfo.ReverseDependencies, ", ")
			}
		}
		_ = coreExposed

		summary := fmt.Sprintf("%s | reverse deps: %s", strings.Join(descs, "; "), rdeps)
		idSuffix := pkgInfo.Version
		if len(cves) > 0 {
			idSuffix = cves[0]
		}
		out = append(out, model.Finding{
			ID:                fmt.Sprintf("pkgaudit:%s:%s", pkgName, idSuffix),
			Category:          "pkg_audit",
			Severity:          sev,
			Device:            device,
			Title:             fmt.Sprintf("pkg audit: %s %s (%s)", pkgName, pkgInfo.Version, strings.Join(cves, ", ")),
			Summary:           summary,
			RunningVersion:    fmt.Sprintf("%s %s", pkgName, pkgInfo.Version),
			FixedVersion:      "Awaiting OPNsense package rebuild or next point release (check upgrade_packages)",
			Mitigation:        kevReq,
			Exposure:          exposure,
			RebootExpected:    "no (unless bundled with kernel/base update)",
			RecommendedTiming: timing,
			CVEs:              cves,
			KEV:               isKEV,
			Sources:           compactStrings(urls),
			FirstSeen:         now,
			LastSeen:          now,
		})
	}
	return out
}

func evalFirmwareAndForum(snap *model.OPNsenseSnapshot, bundle *feeds.FeedBundle, device string, now time.Time) []model.Finding {
	var out []model.Finding
	exposure := summarizeExposure(snap)
	reboot := "no"
	if snap.FirmwareCheck.NeedsReboot == "1" || snap.FirmwareCheck.UpgradeNeedsReboot == "1" {
		reboot = "yes"
	}
	for _, s := range snap.FirmwareCheck.UpgradeSets {
		if strings.EqualFold(s.Name, "kernel") || strings.EqualFold(s.Name, "base") {
			reboot = "yes"
		}
	}

	var updateItems []string
	hasCoreOrSetUpdate := len(snap.FirmwareCheck.UpgradeSets) > 0
	for _, s := range snap.FirmwareCheck.UpgradeSets {
		updateItems = append(updateItems, fmt.Sprintf("set %s: %s -> %s", s.Name, s.CurrentVersion, s.NewVersion))
	}
	opnNewVer := ""
	for _, p := range snap.FirmwareCheck.UpgradePackages {
		cur := p.CurrentVersion
		nxt := p.NewVersion
		if nxt == "" {
			nxt = p.Version
		}
		updateItems = append(updateItems, fmt.Sprintf("%s: %s -> %s", p.Name, cur, nxt))
		if p.Name == "opnsense" {
			hasCoreOrSetUpdate = true
			opnNewVer = nxt
		}
	}
	if len(updateItems) > 0 {
		sev := model.SeverityDigest
		timing := "Routine maintenance window"
		if hasCoreOrSetUpdate || reboot == "yes" {
			sev = model.SeverityDaily
			timing = "Schedule maintenance window & review release notes"
		}
		fixed := opnNewVer
		if fixed == "" {
			fixed = strings.Join(updateItems, "; ")
		}
		out = append(out, model.Finding{
			ID:                fmt.Sprintf("firmware:pending:%s->%s", snap.ProductVersion, fixed),
			Category:          "firmware",
			Severity:          sev,
			Device:            device,
			Title:             fmt.Sprintf("OPNsense updates available (%d items, reboot=%s)", len(updateItems), reboot),
			Summary:           strings.Join(updateItems, "; "),
			RunningVersion:    fmt.Sprintf("opnsense %s (kernel %s)", snap.ProductVersion, snap.FreeBSDKernel),
			FixedVersion:      fixed,
			Exposure:          exposure,
			RebootExpected:    reboot,
			RecommendedTiming: timing,
			Sources:           []string{"opnsense-pkg-check"},
			FirstSeen:         now,
			LastSeen:          now,
		})
	}

	series := strings.TrimSpace(snap.ProductSeries)
	if series == "" {
		series = version.SeriesOf(snap.ProductVersion)
	}
	for _, it := range bundle.Announcements {
		if it.IsReply || it.Version == "" {
			continue
		}
		if strings.EqualFold(snap.Edition, "community") && it.Business {
			continue
		}
		if version.SeriesOf(it.Version) != series {
			continue
		}
		cmp, err := version.CompareOPNsense(it.Version, snap.ProductVersion)
		if err != nil || cmp <= 0 {
			continue
		}
		lowerDesc := strings.ToLower(it.Description)
		isSecurity := strings.Contains(lowerDesc, "security") || strings.Contains(lowerDesc, "freebsd-sa-") ||
			strings.Contains(lowerDesc, "cve-") || strings.Contains(lowerDesc, "advisories")
		sev := model.SeverityDigest
		timing := "Review in weekly digest"
		if isSecurity {
			sev = model.SeverityDaily
			timing = "Schedule patch window after reviewing release notes"
		}
		rebootHint := "unknown (check announcement; yes if kernel/base)"
		if strings.Contains(lowerDesc, "reboot") || strings.Contains(lowerDesc, "freebsd-sa-") || strings.Contains(lowerDesc, "kernel") {
			rebootHint = "likely yes (kernel/src advisories mentioned)"
		}
		out = append(out, model.Finding{
			ID:                "forum:release:" + it.Version,
			Category:          "forum",
			Severity:          sev,
			Device:            device,
			Title:             fmt.Sprintf("New OPNsense announcement: %s", it.Title),
			Summary:           truncate(it.Description, 400),
			RunningVersion:    snap.ProductVersion,
			FixedVersion:      it.Version,
			Exposure:          exposure,
			RebootExpected:    rebootHint,
			RecommendedTiming: timing,
			CVEs:              version.ExtractCVEs(it.Description),
			Sources:           compactStrings([]string{it.Link}),
			FirstSeen:         now,
			LastSeen:          now,
		})
	}

	return out
}

func checkKEV(cves []string, kev map[string]feeds.KEVEntry) (bool, string) {
	for _, c := range cves {
		if entry, ok := kev[strings.ToUpper(c)]; ok {
			return true, fmt.Sprintf("CISA KEV %s (due %s): %s", entry.CVEID, entry.DueDate, entry.RequiredAction)
		}
	}
	return false, ""
}

func summarizeExposure(snap *model.OPNsenseSnapshot) string {
	if snap == nil {
		return "unknown"
	}
	wanIf := snap.Exposure.WANInterface
	if wanIf == "" {
		wanIf = "wan"
	}
	svcs := strings.Join(snap.Services, ", ")
	if svcs == "" {
		svcs = "none recorded"
	}
	return fmt.Sprintf("WAN=%s (%d pass rules, %d NAT rdr); active services: %s",
		wanIf, len(snap.Exposure.WANPassRules), len(snap.Exposure.WANRDRRules), svcs)
}

func normalizePluginName(raw string) string {
	s := strings.ToLower(strings.TrimSpace(raw))
	if idx := strings.LastIndex(s, "/"); idx != -1 {
		s = s[idx+1:]
	}
	return s
}

func containsAny(list []string, targets ...string) bool {
	for _, item := range list {
		for _, tgt := range targets {
			if strings.EqualFold(item, tgt) {
				return true
			}
		}
	}
	return false
}

func severityRank(s string) int {
	switch s {
	case model.SeverityUrgent:
		return 0
	case model.SeverityDaily:
		return 1
	default:
		return 2
	}
}

func joinKeys(m map[string]struct{}) string {
	if len(m) == 0 {
		return ""
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return strings.Join(keys, ", ")
}

func compactStrings(in []string) []string {
	seen := make(map[string]struct{}, len(in))
	var out []string
	for _, s := range in {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		if _, ok := seen[s]; !ok {
			seen[s] = struct{}{}
			out = append(out, s)
		}
	}
	return out
}

func dedupSorted(in []string) []string {
	out := compactStrings(in)
	sort.Strings(out)
	return out
}

func firstLine(s string) string {
	if idx := strings.IndexByte(s, '\n'); idx != -1 {
		return strings.TrimSpace(s[:idx])
	}
	return strings.TrimSpace(s)
}

func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "..."
}
