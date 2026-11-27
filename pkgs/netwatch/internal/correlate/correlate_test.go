package correlate

import (
	"testing"
	"time"

	"faragao.net/netwatch/internal/feeds"
	"faragao.net/netwatch/internal/model"
)

func healthyStatuses(now time.Time) map[string]model.FeedStatus {
	return map[string]model.FeedStatus{
		feeds.FeedKEV:           {Name: feeds.FeedKEV, LastSuccess: now},
		feeds.FeedCoreGHSA:      {Name: feeds.FeedCoreGHSA, LastSuccess: now},
		feeds.FeedPluginsGHSA:   {Name: feeds.FeedPluginsGHSA, LastSuccess: now},
		feeds.FeedAnnouncements: {Name: feeds.FeedAnnouncements, LastSuccess: now},
	}
}

func baseSnapshot(now time.Time) *model.OPNsenseSnapshot {
	return &model.OPNsenseSnapshot{
		Host:            "chief-tui-opn.faragao.net",
		CollectedAt:     now.Add(-1 * time.Hour),
		Edition:         "community",
		ProductID:       "opnsense",
		ProductVersion:  "26.7.10",
		ProductSeries:   "26.7",
		FreeBSDKernel:   "15.1-RELEASE-p7",
		FreeBSDUserland: "15.1-RELEASE-p7",
		AuditOK:         true,
		Plugins: []model.PackageInfo{
			{Name: "os-acme-client", Version: "4.18"},
			{Name: "os-ddclient", Version: "1.34"},
		},
		Services: []string{"unbound", "dnsmasq", "sshd", "lighttpd", "ddclient"},
		Exposure: model.ExposureSummary{
			WANInterface: "igc1",
			WANPassRules: []string{"pass in on igc1 CloudflareIPs -> 192.168.40.3:443"},
			WANRDRRules:  []string{"rdr on igc1 proto tcp -> 192.168.40.3 port 443"},
		},
	}
}

func TestEvaluateLiveOPNsenseAndFiltersUnsupportedMatches(t *testing.T) {
	now := time.Date(2026, 11, 27, 8, 0, 0, 0, time.UTC)
	snap := baseSnapshot(now)
	snap.PkgAudit = model.PkgAuditResult{
		PkgCount: 2,
		Packages: map[string]model.PkgAuditPackage{
			"python313": {
				Version: "3.13.18",
				Issues: []model.PkgAuditIssue{{
					Description: "Python -- poplib module command injection",
					CVE:         []string{"CVE-2025-15367"},
					URL:         "https://vuxml.FreeBSD.org/freebsd/6d3488ae.html",
				}},
				ReverseDependencies: []string{"opnsense", "unbound"},
			},
			"zstd": {
				Version: "1.5.7_2",
				Issues: []model.PkgAuditIssue{{
					Description: "zstd -- Information disclosure",
					CVE:         []string{"CVE-2026-124851"},
					URL:         "https://vuxml.FreeBSD.org/freebsd/99846c9e.html",
				}},
				ReverseDependencies: []string{"curl", "os-ddclient"},
			},
		},
	}

	bundle := &feeds.FeedBundle{
		KEVByCVE: map[string]feeds.KEVEntry{},
		CoreGHSAs: []feeds.GHSAAdvisory{
			{
				GHSAID:   "GHSA-89wp-xvvm-9pp4",
				Severity: "high",
				Summary:  "Authenticated Root Command Injection (incomplete fix of CVE\u20112026\u2011119409)",
				HTMLURL:  "https://github.com/opnsense/core/security/advisories/GHSA-89wp-xvvm-9pp4",
				Vulnerabilities: []feeds.GHSAVulnerability{{
					Package:                feeds.GHSAPackage{Name: "opnsense/core"},
					VulnerableVersionRange: "<= 26.7.9, 26.10.0p1",
					PatchedVersions:        "26.7.10, 26.10.0p2",
				}},
			},
			{
				GHSAID:   "GHSA-75fw-j788-j4hj",
				Severity: "medium",
				Summary:  "Stored XSS via Unsafe Attribute Construction and info Field HTML Insertion",
				HTMLURL:  "https://github.com/opnsense/core/security/advisories/GHSA-75fw-j788-j4hj",
				Vulnerabilities: []feeds.GHSAVulnerability{{
					Package:                feeds.GHSAPackage{Name: "opnsense/core "},
					VulnerableVersionRange: ">= 26.7.1",
					PatchedVersions:        "26.7.2",
				}},
			},
		},
		PluginGHSAs: []feeds.GHSAAdvisory{
			{
				GHSAID:   "GHSA-uninstalled-caddy",
				Severity: "critical",
				Summary:  "Caddy plugin flaw",
				Vulnerabilities: []feeds.GHSAVulnerability{{
					Package:                feeds.GHSAPackage{Name: "os-caddy"},
					VulnerableVersionRange: "<= 2.0.0",
					PatchedVersions:        "2.0.1",
				}},
			},
			{
				GHSAID:   "GHSA-ddclient-installed",
				Severity: "high",
				Summary:  "DDclient flaw",
				Vulnerabilities: []feeds.GHSAVulnerability{{
					Package:                feeds.GHSAPackage{Name: "plugins/os-ddclient"},
					VulnerableVersionRange: "<= 1.34",
					PatchedVersions:        "1.35",
				}},
			},
		},
		Announcements: []feeds.ForumItem{
			{
				Title:    "Re: OPNsense 26.10 business edition released",
				Version:  "26.10",
				Business: true,
				IsReply:  true,
			},
			{
				Title:       "OPNsense 26.7.10 released",
				Version:     "26.7.10",
				Description: "Already running",
			},
		},
	}

	res := Evaluate(snap, bundle, healthyStatuses(now), now, DefaultStaleAfter)
	if !res.CleanRecheck {
		t.Fatalf("expected CleanRecheck=true")
	}

	foundIDs := map[string]model.Finding{}
	for _, f := range res.Findings {
		foundIDs[f.ID] = f
	}

	if _, ok := foundIDs["ghsa:core:GHSA-89wp-xvvm-9pp4"]; ok {
		t.Fatalf("did not expect GHSA-89wp-xvvm-9pp4 to match patched 26.7.10")
	}
	if _, ok := foundIDs["ghsa:core:GHSA-75fw-j788-j4hj"]; ok {
		t.Fatalf("did not expect GHSA-75fw-j788-j4hj (>= 26.7.1 patched in 26.7.2) to match 26.7.10")
	}
	if _, ok := foundIDs["ghsa:plugin:GHSA-uninstalled-caddy:os-caddy"]; ok {
		t.Fatalf("did not expect uninstalled os-caddy advisory to match")
	}
	if _, ok := foundIDs["ghsa:plugin:GHSA-ddclient-installed:os-ddclient"]; !ok {
		t.Fatalf("expected installed os-ddclient advisory to match, got %v", foundIDs)
	}
	if f, ok := foundIDs["pkgaudit:python313:CVE-2025-15367"]; !ok || f.Severity != model.SeverityDaily {
		t.Fatalf("expected python313 as daily finding, got %+v", f)
	}
	if f, ok := foundIDs["pkgaudit:zstd:CVE-2026-124851"]; !ok || f.Severity != model.SeverityDaily {
		t.Fatalf("expected zstd as daily finding, got %+v", f)
	}
}

func TestEvaluateKEVEscaltionCoreGHSAAndStaleSnapshot(t *testing.T) {
	now := time.Date(2026, 11, 27, 8, 0, 0, 0, time.UTC)
	snap := baseSnapshot(now)
	snap.ProductVersion = "26.7.9"
	snap.CollectedAt = now.Add(-60 * time.Hour) // stale > 50h
	snap.PkgAudit = model.PkgAuditResult{
		PkgCount: 1,
		Packages: map[string]model.PkgAuditPackage{
			"zstd": {
				Version: "1.5.7_2",
				Issues: []model.PkgAuditIssue{{
					Description: "zstd KEV test",
					CVE:         []string{"CVE-2026-124851"},
				}},
			},
		},
	}

	bundle := &feeds.FeedBundle{
		KEVByCVE: map[string]feeds.KEVEntry{
			"CVE-2026-124851": {
				CVEID:          "CVE-2026-124851",
				DueDate:        "2026-12-01",
				RequiredAction: "Upgrade zstd",
			},
		},
		CoreGHSAs: []feeds.GHSAAdvisory{{
			GHSAID:   "GHSA-89wp-xvvm-9pp4",
			Severity: "high",
			Summary:  "Command injection CVE\u20112026\u2011119409",
			Vulnerabilities: []feeds.GHSAVulnerability{{
				Package:                feeds.GHSAPackage{Name: "opnsense/core"},
				VulnerableVersionRange: "<= 26.7.9, 26.10.0p1",
				PatchedVersions:        "26.7.10",
			}},
		}},
	}

	res := Evaluate(snap, bundle, healthyStatuses(now), now, DefaultStaleAfter)
	if res.CleanRecheck {
		t.Fatalf("expected CleanRecheck=false when snapshot is stale")
	}

	m := map[string]model.Finding{}
	for _, f := range res.Findings {
		m[f.ID] = f
	}
	if f, ok := m["monitor:opnsense:stale-audit"]; !ok || f.Severity != model.SeverityUrgent {
		t.Fatalf("expected urgent stale-audit finding, got %+v", f)
	}
	if f, ok := m["pkgaudit:zstd:CVE-2026-124851"]; !ok || f.Severity != model.SeverityUrgent || !f.KEV {
		t.Fatalf("expected KEV escalation on zstd, got %+v", f)
	}
	if f, ok := m["ghsa:core:GHSA-89wp-xvvm-9pp4"]; !ok || f.Severity != model.SeverityUrgent {
		t.Fatalf("expected core GHSA match on 26.7.9, got %+v", f)
	}
}

func TestEvaluateTelemetryAndExposure(t *testing.T) {
	now := time.Date(2026, 11, 27, 20, 0, 0, 0, time.UTC)
	snap := baseSnapshot(now)

	// 1. Silent syslog -> monitor:opnsense:syslog-silent (distinct from stale-audit)
	st := model.State{
		LatestSnapshot: snap,
		BaselineExposure: &model.ExposureSummary{
			WANInterface: snap.Exposure.WANInterface,
			WANPassRules: append([]string(nil), snap.Exposure.WANPassRules...),
			WANRDRRules:  append([]string(nil), snap.Exposure.WANRDRRules...),
		},
		Syslog: model.SyslogStats{
			LastReceived: now.Add(-20 * time.Minute),
		},
	}
	findings := EvaluateTelemetryAndExposure(st, now, true, 15*time.Minute, now.Add(-1*time.Hour))
	if len(findings) != 1 || findings[0].ID != "monitor:opnsense:syslog-silent" {
		t.Fatalf("expected monitor:opnsense:syslog-silent, got %+v", findings)
	}

	// 2. Resumed syslog + drifted WAN RDR rule -> sec:opnsense:exposure-drift
	st.Syslog.LastReceived = now.Add(-1 * time.Minute)
	st.LatestSnapshot.Exposure.WANRDRRules = append(st.LatestSnapshot.Exposure.WANRDRRules, "rdr on igc1 proto tcp port 2222 -> 192.168.10.50")
	findings = EvaluateTelemetryAndExposure(st, now, true, 15*time.Minute, now.Add(-1*time.Hour))
	if len(findings) != 1 || findings[0].ID != "sec:opnsense:exposure-drift" {
		t.Fatalf("expected sec:opnsense:exposure-drift, got %+v", findings)
	}

	// 3. Maintenance window active suppresses exposure-drift
	until := now.Add(30 * time.Minute)
	st.MaintenanceUntil = &until
	findings = EvaluateTelemetryAndExposure(st, now, true, 15*time.Minute, now.Add(-1*time.Hour))
	if len(findings) != 0 {
		t.Fatalf("expected maintenance window to suppress exposure-drift, got %+v", findings)
	}
}
