package correlate

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"faragao.net/netwatch/internal/feeds"
	"faragao.net/netwatch/internal/model"
	"faragao.net/netwatch/internal/version"
)

const (
	nixosStaleAfter = 21 * 24 * time.Hour
)

var (
	nixosBuildRe = regexp.MustCompile(`^([0-9]{2}\.[0-9]{2})\.([0-9]{8})\.([0-9a-fA-F]{7,40})\b`)
	dsmVerRe     = regexp.MustCompile(`([0-9]+)\.([0-9]+)(?:\.([0-9]+))?(?:-([0-9]+))?`)
	dsmUpdateRe  = regexp.MustCompile(`(?i)update\s*([0-9]+)`)
	ruckusVerRe  = regexp.MustCompile(`([0-9]+)\.([0-9]+)(?:\.[0-9]+)*`)
)

// LoadFleetManifest loads baseline device posture entries from JSON array or {"devices":[...]} manifest.
// Missing or empty path returns nil, nil so netwatch degrades gracefully without a manifest.
func LoadFleetManifest(path string) ([]model.FleetDevicePosture, error) {
	p := strings.TrimSpace(path)
	if p == "" {
		return nil, nil
	}
	raw, err := os.ReadFile(p)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("read fleet manifest %s: %w", p, err)
	}
	trimmed := strings.TrimSpace(string(raw))
	if trimmed == "" {
		return nil, nil
	}
	if strings.HasPrefix(trimmed, "[") {
		var list []model.FleetDevicePosture
		if err := json.Unmarshal(raw, &list); err != nil {
			return nil, fmt.Errorf("decode fleet manifest %s: %w", p, err)
		}
		return list, nil
	}
	var wrapper struct {
		Devices []model.FleetDevicePosture `json:"devices"`
	}
	if err := json.Unmarshal(raw, &wrapper); err != nil {
		return nil, fmt.Errorf("decode fleet manifest %s: %w", p, err)
	}
	return wrapper.Devices, nil
}

// MergeFleetPosture combines static manifest defaults with live OPNsense, local tala,
// and maui-reported Prometheus/SNMP version observations, then evaluates update_status.
func MergeFleetPosture(
	manifest []model.FleetDevicePosture,
	st model.State,
	localTala *model.FleetDevicePosture,
	bundle *feeds.FeedBundle,
	now time.Time,
) []model.FleetDevicePosture {
	byDevice := make(map[string]model.FleetDevicePosture, len(manifest)+len(st.FleetDevices)+2)
	for _, m := range manifest {
		id := strings.TrimSpace(m.Device)
		if id == "" {
			continue
		}
		m.Device = id
		byDevice[id] = m
	}

	if st.LatestSnapshot != nil {
		d := byDevice["chief-tui-opn"]
		d.Device = "chief-tui-opn"
		if d.Role == "" {
			d.Role = "primary-firewall"
		}
		if d.Vendor == "" {
			d.Vendor = "OPNsense"
		}
		if d.Product == "" {
			d.Product = "OPNsense Community Edition"
		}
		d.RunningVersion = fmt.Sprintf("OPNsense %s (%s)", st.LatestSnapshot.ProductVersion, st.LatestSnapshot.Edition)
		kernel := strings.TrimSpace(st.LatestSnapshot.FreeBSDRunning)
		if kernel == "" {
			kernel = strings.TrimSpace(st.LatestSnapshot.FreeBSDKernel)
		}
		d.KernelVersion = kernel
		d.VersionSource = "live_opnsense"
		d.LastCheckedAt = st.LatestSnapshot.CollectedAt
		pending := len(st.LatestSnapshot.FirmwareCheck.UpgradePackages) + len(st.LatestSnapshot.FirmwareCheck.UpgradeSets)
		if pending > 0 {
			d.UpdateStatus = "update_available"
			d.AvailableVersion = fmt.Sprintf("%d package/set update(s)", pending)
		} else {
			d.UpdateStatus = "current"
			d.AvailableVersion = ""
		}
		byDevice["chief-tui-opn"] = d
	}

	for id, pushed := range st.FleetDevices {
		key := strings.TrimSpace(id)
		if key == "" {
			key = strings.TrimSpace(pushed.Device)
		}
		if key == "" {
			continue
		}
		cur := byDevice[key]
		cur.Device = key
		mergeLiveDevice(&cur, pushed)
		byDevice[key] = cur
	}

	if localTala != nil {
		cur := byDevice["tala"]
		cur.Device = "tala"
		mergeLiveDevice(&cur, *localTala)
		byDevice["tala"] = cur
	}

	ids := make([]string, 0, len(byDevice))
	for id := range byDevice {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	out := make([]model.FleetDevicePosture, 0, len(ids))
	for _, id := range ids {
		d := byDevice[id]
		evaluateDeviceStatus(&d, bundle, now)
		out = append(out, d)
	}
	return out
}

func mergeLiveDevice(dst *model.FleetDevicePosture, live model.FleetDevicePosture) {
	if live.Role != "" {
		dst.Role = live.Role
	}
	if live.Vendor != "" {
		dst.Vendor = live.Vendor
	}
	if live.Product != "" {
		dst.Product = live.Product
	}
	if live.RunningVersion != "" && !shouldPreserveMoreSpecificDSM(dst.RunningVersion, live.RunningVersion) {
		dst.RunningVersion = live.RunningVersion
	}
	if live.KernelVersion != "" {
		dst.KernelVersion = live.KernelVersion
	}
	if live.VersionSource != "" {
		dst.VersionSource = live.VersionSource
	}
	if live.UpdateChannel != "" {
		dst.UpdateChannel = live.UpdateChannel
	}
	if live.Cadence != "" {
		dst.Cadence = live.Cadence
	}
	if live.AvailableVersion != "" {
		dst.AvailableVersion = live.AvailableVersion
	}
	if live.SNMPUpgradeAvailable != 0 {
		dst.SNMPUpgradeAvailable = live.SNMPUpgradeAvailable
	}
	if live.UpgradeLastResult != "" {
		dst.UpgradeLastResult = live.UpgradeLastResult
	}
	if live.UpgradeLastRun != "" {
		dst.UpgradeLastRun = live.UpgradeLastRun
	}
	if !live.LastCheckedAt.IsZero() {
		dst.LastCheckedAt = live.LastCheckedAt
	}
}

func shouldPreserveMoreSpecificDSM(existing, incoming string) bool {
	em := dsmVerRe.FindStringSubmatch(existing)
	im := dsmVerRe.FindStringSubmatch(incoming)
	if len(em) < 5 || len(im) < 5 {
		return false
	}
	if em[1] != im[1] || em[2] != im[2] || em[4] == "" || em[4] != im[4] {
		return false
	}
	existingHasPatch := em[3] != ""
	incomingHasPatch := im[3] != ""
	existingHasUpdate := dsmUpdateRe.MatchString(existing)
	incomingHasUpdate := dsmUpdateRe.MatchString(incoming)
	return (existingHasPatch && !incomingHasPatch) || (existingHasUpdate && !incomingHasUpdate)
}

func evaluateDeviceStatus(d *model.FleetDevicePosture, bundle *feeds.FeedBundle, now time.Time) {
	reviewOverdue := d.ReviewIntervalDays > 0 && !d.LastVerifiedAt.IsZero() &&
		now.Sub(d.LastVerifiedAt) > time.Duration(d.ReviewIntervalDays)*24*time.Hour

	if d.Device == "chief-tui-opn" {
		if d.VersionSource == "live_opnsense" {
			return
		}
		if reviewOverdue {
			d.UpdateStatus = "review_due"
		} else if d.UpdateStatus == "" {
			d.UpdateStatus = "unknown"
		}
		return
	}

	if strings.EqualFold(d.Vendor, "Authentik") || d.Device == "authentik" {
		if bundle != nil && bundle.AuthentikLatestRelease != "" && d.RunningVersion != "" {
			if cmp, err := version.CompareOPNsense(d.RunningVersion, bundle.AuthentikLatestRelease); err == nil {
				if cmp < 0 {
					d.UpdateStatus = "update_available"
					d.AvailableVersion = bundle.AuthentikLatestRelease
					return
				}
				d.UpdateStatus = "current"
				d.AvailableVersion = ""
				return
			}
		}
		if reviewOverdue {
			d.UpdateStatus = "review_due"
		} else if d.RunningVersion == "" {
			d.UpdateStatus = "unknown"
		} else {
			d.UpdateStatus = "current"
		}
		return
	}

	if strings.HasPrefix(d.UpdateChannel, "nixos-") {
		buildDate, shortRev, ok := parseNixOSVersion(d.RunningVersion)
		var chanRev string
		if bundle != nil {
			chanRev = bundle.NixOSChannelRevs[d.UpdateChannel]
		}
		if ok && chanRev != "" {
			if strings.HasPrefix(strings.ToLower(chanRev), strings.ToLower(shortRev)) {
				d.UpdateStatus = "current"
				d.AvailableVersion = ""
				return
			}
			shortChan := chanRev
			if len(shortChan) > 7 {
				shortChan = shortChan[:7]
			}
			d.AvailableVersion = fmt.Sprintf("%s.%s", d.UpdateChannel, shortChan)
			if !buildDate.IsZero() && now.Sub(buildDate) > nixosStaleAfter {
				d.UpdateStatus = "stale"
			} else {
				d.UpdateStatus = "update_available"
			}
			return
		}
		if d.RunningVersion != "" {
			if reviewOverdue {
				d.UpdateStatus = "review_due"
			} else {
				d.UpdateStatus = "current"
			}
			return
		}
		d.UpdateStatus = "unknown"
		return
	}

	if strings.EqualFold(d.Vendor, "Synology") || d.Device == "teka" {
		if d.SNMPUpgradeAvailable == 1 {
			d.UpdateStatus = "update_available"
			if d.AvailableVersion == "" {
				d.AvailableVersion = "DSM update available (SNMP)"
			}
			return
		}
		if reviewOverdue {
			d.UpdateStatus = "review_due"
			return
		}
		if d.RunningVersion == "" {
			d.UpdateStatus = "unknown"
		} else {
			d.UpdateStatus = "current"
		}
		return
	}

	if strings.Contains(strings.ToLower(d.EOLStatus), "eol") {
		if reviewOverdue {
			d.UpdateStatus = "review_due"
		} else {
			d.UpdateStatus = "eol_mitigated"
		}
		return
	}

	if reviewOverdue {
		d.UpdateStatus = "review_due"
		return
	}
	if d.RunningVersion == "" {
		d.UpdateStatus = "unknown"
		return
	}
	d.UpdateStatus = "current"
}

func parseNixOSVersion(raw string) (time.Time, string, bool) {
	fields := strings.Fields(strings.TrimSpace(raw))
	if len(fields) == 0 {
		return time.Time{}, "", false
	}
	m := nixosBuildRe.FindStringSubmatch(fields[0])
	if len(m) != 4 {
		return time.Time{}, "", false
	}
	dt, err := time.Parse("20060102", m[2])
	if err != nil {
		return time.Time{}, m[3], true
	}
	return dt, m[3], true
}

// EvaluateFleetPosture emits update, stale-host, review-due, and non-OPNsense CISA KEV findings.
func EvaluateFleetPosture(devices []model.FleetDevicePosture, bundle *feeds.FeedBundle, now time.Time) []model.Finding {
	var out []model.Finding

	for _, d := range devices {
		if d.Device != "chief-tui-opn" {
			switch d.UpdateStatus {
			case "stale":
				out = append(out, model.Finding{
					ID:                "fleet:update:" + d.Device,
					Category:          "firmware",
					Severity:          model.SeverityDaily,
					Device:            d.Device,
					Title:             fmt.Sprintf("NixOS host %s is >21d behind %s", d.Device, d.UpdateChannel),
					Summary:           fmt.Sprintf("Running %s while channel %s is at %s.", d.RunningVersion, d.UpdateChannel, d.AvailableVersion),
					RunningVersion:    d.RunningVersion,
					FixedVersion:      d.AvailableVersion,
					Exposure:          d.Role,
					RebootExpected:    "only on kernel upgrade",
					RecommendedTiming: "Check flake-update timer and next maintenance window",
					Sources:           []string{"channels.nixos.org/" + d.UpdateChannel},
					FirstSeen:         now,
					LastSeen:          now,
				})
			case "update_available":
				sev := model.SeverityDaily
				timing := "Review vendor release notes and apply in maintenance window"
				if strings.HasPrefix(d.UpdateChannel, "nixos-") {
					sev = model.SeverityDigest
					timing = "Applied by scheduled nix flake-update / auto-upgrade cycle"
				}
				fixed := d.AvailableVersion
				if fixed == "" {
					fixed = "Vendor update available"
				}
				out = append(out, model.Finding{
					ID:                "fleet:update:" + d.Device,
					Category:          "firmware",
					Severity:          sev,
					Device:            d.Device,
					Title:             fmt.Sprintf("Update available on %s (%s)", d.Device, d.Product),
					Summary:           fmt.Sprintf("%s running %s has update %s.", d.Product, d.RunningVersion, fixed),
					RunningVersion:    d.RunningVersion,
					FixedVersion:      fixed,
					Exposure:          d.Role,
					RebootExpected:    "check release notes",
					RecommendedTiming: timing,
					Sources:           compactStrings([]string{d.AdvisoryURL, d.VersionSource}),
					FirstSeen:         now,
					LastSeen:          now,
				})
			case "review_due":
				out = append(out, model.Finding{
					ID:                "fleet:review-due:" + d.Device,
					Category:          "firmware",
					Severity:          model.SeverityDigest,
					Device:            d.Device,
					Title:             fmt.Sprintf("Manual advisory/firmware review due on %s", d.Device),
					Summary:           fmt.Sprintf("%s (%s) exceeded %d-day review interval since %s.", d.Product, d.RunningVersion, d.ReviewIntervalDays, d.LastVerifiedAt.Format("2006-01-02")),
					RunningVersion:    d.RunningVersion,
					FixedVersion:      "Verify vendor advisory page & update last_verified_at",
					Exposure:          d.Role,
					RebootExpected:    "no",
					RecommendedTiming: "Review before weekly check closes",
					Sources:           compactStrings([]string{d.AdvisoryURL}),
					FirstSeen:         now,
					LastSeen:          now,
				})
			}
		}
	}

	if bundle != nil && len(bundle.KEVByCVE) > 0 {
		cveIDs := make([]string, 0, len(bundle.KEVByCVE))
		for k := range bundle.KEVByCVE {
			cveIDs = append(cveIDs, k)
		}
		sort.Strings(cveIDs)

		for _, d := range devices {
			if d.Device == "chief-tui-opn" {
				continue // OPNsense CISA KEV matching is already owned by evalCoreGHSAs/PluginGHSAs/PkgAudit
			}
			for _, cve := range cveIDs {
				entry := bundle.KEVByCVE[cve]
				if !kevMatchesDevice(d, entry) {
					continue
				}
				out = append(out, model.Finding{
					ID:                fmt.Sprintf("fleet:kev:%s:%s", d.Device, entry.CVEID),
					Category:          "advisory",
					Severity:          model.SeverityUrgent,
					Device:            d.Device,
					Title:             fmt.Sprintf("CISA KEV %s affects %s (%s)", entry.CVEID, d.Device, d.Product),
					Summary:           fmt.Sprintf("%s — %s", entry.VulnerabilityName, entry.ShortDescription),
					RunningVersion:    d.RunningVersion,
					FixedVersion:      fmt.Sprintf("Review %s vendor advisory immediately", d.Vendor),
					Mitigation:        fmt.Sprintf("CISA KEV %s (due %s): %s", entry.CVEID, entry.DueDate, entry.RequiredAction),
					Exposure:          d.Role,
					RebootExpected:    "yes (firmware update likely)",
					RecommendedTiming: "URGENT (CISA KEV) — inspect vendor advisory & patch promptly",
					CVEs:              []string{entry.CVEID},
					KEV:               true,
					Sources:           compactStrings([]string{feeds.DefaultKEVURL, d.AdvisoryURL}),
					FirstSeen:         now,
					LastSeen:          now,
				})
			}
		}
	}

	if bundle != nil && len(bundle.AuthentikGHSAs) > 0 {
		for _, d := range devices {
			if !(strings.EqualFold(d.Vendor, "Authentik") || d.Device == "authentik") || strings.TrimSpace(d.RunningVersion) == "" {
				continue
			}
			for _, adv := range bundle.AuthentikGHSAs {
				matched, fixedVersions := matchesAuthentikAdvisory(d.RunningVersion, adv)
				if !matched {
					continue
				}
				cves := version.ExtractCVEs(adv.CVEID, adv.Summary, adv.Description)
				inKEV := false
				for _, cve := range cves {
					if _, ok := bundle.KEVByCVE[cve]; ok {
						inKEV = true
						break
					}
				}
				sev := model.SeverityDaily
				timing := "Review Authentik GHSA and bump pinned image tag on tala"
				if inKEV || strings.EqualFold(adv.Severity, "critical") {
					sev = model.SeverityUrgent
					timing = "URGENT — bump pinned Authentik OCI tag on tala promptly"
				}
				fixed := "Bump pinned Authentik OCI tag"
				if len(fixedVersions) > 0 {
					fixed = strings.Join(fixedVersions, ", ")
				}
				out = append(out, model.Finding{
					ID:                fmt.Sprintf("fleet:ghsa:%s:%s", d.Device, adv.GHSAID),
					Category:          "advisory",
					Severity:          sev,
					Device:            d.Device,
					Title:             fmt.Sprintf("Authentik %s: %s", adv.GHSAID, adv.Summary),
					Summary:           fmt.Sprintf("Authentik %s matches GHSA %s (%s).", d.RunningVersion, adv.GHSAID, adv.Severity),
					RunningVersion:    d.RunningVersion,
					FixedVersion:      fixed,
					Exposure:          d.Role,
					RebootExpected:    "container restart only (~15s)",
					RecommendedTiming: timing,
					CVEs:              cves,
					KEV:               inKEV,
					Sources:           compactStrings([]string{adv.HTMLURL, feeds.DefaultAuthentikGHSAURL}),
					FirstSeen:         now,
					LastSeen:          now,
				})
			}
		}
	}

	sort.Slice(out, func(i, j int) bool {
		if severityRank(out[i].Severity) != severityRank(out[j].Severity) {
			return severityRank(out[i].Severity) < severityRank(out[j].Severity)
		}
		return out[i].ID < out[j].ID
	})
	return out
}

func kevMatchesDevice(d model.FleetDevicePosture, entry feeds.KEVEntry) bool {
	vp := strings.ToLower(entry.VendorProject + " " + entry.Product)
	prod := strings.ToLower(entry.Product)
	cve := strings.ToUpper(strings.TrimSpace(entry.CVEID))

	switch {
	case strings.EqualFold(d.Vendor, "Authentik") || d.Device == "authentik":
		return strings.Contains(vp, "authentik") || strings.Contains(vp, "goauthentik")

	case strings.EqualFold(d.Vendor, "Synology") || d.Device == "teka":
		if !strings.Contains(vp, "synology") || (!strings.Contains(prod, "diskstation manager") && !strings.Contains(prod, "dsm")) {
			return false
		}
		if cve == "CVE-2024-10441" && isDSM711Update7OrLater(d.RunningVersion) {
			return false
		}
		return true

	case d.Device == "chief-tui" || (strings.EqualFold(d.Vendor, "Ubiquiti") && strings.Contains(strings.ToLower(d.Product), "edgerouter")):
		if !strings.Contains(vp, "ubiquiti") {
			return false
		}
		if strings.Contains(prod, "unifi") || strings.Contains(prod, "airos") {
			return false
		}
		return strings.Contains(prod, "edgeos") || strings.Contains(prod, "edgerouter")

	case strings.EqualFold(d.Vendor, "Ruckus") || strings.HasPrefix(d.Device, "ruckus-"):
		if !strings.Contains(vp, "ruckus") && !strings.Contains(prod, "unleashed") {
			return false
		}
		if cve == "CVE-2023-25717" && isRuckus20014OrLater(d.RunningVersion) {
			return false
		}
		return true

	case d.Device == "tamatoa" || strings.Contains(strings.ToLower(d.Product), "icx6450"):
		if strings.Contains(prod, "fabric os") {
			return false
		}
		return (strings.Contains(vp, "brocade") || strings.Contains(vp, "commscope")) &&
			(strings.Contains(prod, "fastiron") || strings.Contains(prod, "icx"))

	case strings.EqualFold(d.Device, "maui") && strings.Contains(strings.ToLower(d.Product), "grafana"):
		if !strings.Contains(vp, "grafana") {
			return false
		}
		if cve == "CVE-2021-43798" || cve == "CVE-2021-39226" {
			return false // Patched well before Grafana 13.3.1
		}
		return true
	}

	return false
}

func matchesAuthentikAdvisory(running string, adv feeds.GHSAAdvisory) (bool, []string) {
	runSeries := version.SeriesOf(running)
	var vulns []feeds.GHSAVulnerability
	for _, v := range adv.Vulnerabilities {
		pkg := strings.ToLower(strings.TrimSpace(v.Package.Name))
		if pkg != "" && !strings.Contains(pkg, "authentik") {
			continue
		}
		vulns = append(vulns, v)
		if runSeries != "" {
			for _, part := range strings.Split(v.PatchedVersions, ",") {
				cand := strings.TrimSpace(part)
				for _, prefix := range []string{">=", ">", "="} {
					if strings.HasPrefix(cand, prefix) {
						cand = strings.TrimSpace(strings.TrimPrefix(cand, prefix))
						break
					}
				}
				if cand == "" {
					continue
				}
				if version.SeriesOf(cand) == runSeries {
					if cmp, err := version.CompareOPNsense(running, cand); err == nil && cmp >= 0 {
						return false, nil
					}
				}
			}
		}
	}

	fixedSet := make(map[string]struct{})
	matched := false
	for _, v := range vulns {
		if version.MatchesPackageVulnerability(running, v.VulnerableVersionRange, v.PatchedVersions) {
			matched = true
			if p := strings.TrimSpace(v.PatchedVersions); p != "" {
				fixedSet[p] = struct{}{}
			}
		}
	}
	if !matched {
		return false, nil
	}
	fixed := make([]string, 0, len(fixedSet))
	for p := range fixedSet {
		fixed = append(fixed, p)
	}
	sort.Strings(fixed)
	return true, fixed
}

func isDSM711Update7OrLater(ver string) bool {
	m := dsmVerRe.FindStringSubmatch(ver)
	if len(m) < 4 {
		return false
	}
	maj, _ := strconv.Atoi(m[1])
	min, _ := strconv.Atoi(m[2])
	patch, _ := strconv.Atoi(m[3])
	if maj > 7 || (maj == 7 && min >= 2) {
		return true
	}
	if maj == 7 && min == 1 && patch >= 1 {
		if um := dsmUpdateRe.FindStringSubmatch(ver); len(um) == 2 {
			upd, _ := strconv.Atoi(um[1])
			return upd >= 7
		}
	}
	return false
}

func isRuckus20014OrLater(ver string) bool {
	m := ruckusVerRe.FindStringSubmatch(ver)
	if len(m) < 3 {
		return false
	}
	maj, _ := strconv.Atoi(m[1])
	min, _ := strconv.Atoi(m[2])
	return maj > 200 || (maj == 200 && min >= 14)
}
