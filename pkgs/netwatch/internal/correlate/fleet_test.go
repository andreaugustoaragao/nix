package correlate

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"faragao.net/netwatch/internal/feeds"
	"faragao.net/netwatch/internal/model"
)

func TestMergeAndEvaluateFleetPostureNixOSChannels(t *testing.T) {
	now := time.Date(2026, 11, 27, 12, 0, 0, 0, time.UTC)

	manifest := []model.FleetDevicePosture{
		{
			Device:             "maui",
			Role:               "services-hub",
			Vendor:             "NixOS",
			Product:            "NixOS 26.11 (Zokor) + Grafana 13.3.1",
			UpdateChannel:      "nixos-26.11",
			AutoUpdate:         true,
			ReviewIntervalDays: 30,
			LastVerifiedAt:     now.Add(-24 * time.Hour),
		},
		{
			Device:             "tala",
			Role:               "security-host",
			Vendor:             "NixOS",
			Product:            "NixOS 26.05 (Yarara)",
			UpdateChannel:      "nixos-26.05",
			AutoUpdate:         true,
			ReviewIntervalDays: 30,
			LastVerifiedAt:     now.Add(-24 * time.Hour),
		},
		{
			Device:         "workstation",
			Role:           "admin-workstation",
			Vendor:         "NixOS",
			Product:        "NixOS 26.05 (Yarara)",
			RunningVersion: "26.05.20261101.deadbee",
			VersionSource:  "verified_inventory",
			UpdateChannel:  "nixos-26.05",
		},
	}

	st := model.State{
		FleetDevices: map[string]model.FleetDevicePosture{
			"maui": {
				Device:         "maui",
				RunningVersion: "26.11.20261127.3068c73",
				VersionSource:  "live_prometheus_node",
				LastCheckedAt:  now,
			},
		},
	}
	localTala := &model.FleetDevicePosture{
		Device:         "tala",
		RunningVersion: "26.05.20261125.1111111",
		VersionSource:  "live_local_nixos",
		LastCheckedAt:  now,
	}
	bundle := &feeds.FeedBundle{
		NixOSChannelRevs: map[string]string{
			"nixos-26.11": "3068c73a96a6979ee8e72e7196577d0bd842d412",
			"nixos-26.05": "5b31ff946309736077f0c4ee23bb85d0a0a1c181",
		},
	}

	merged := MergeFleetPosture(manifest, st, localTala, bundle, now)
	byID := make(map[string]model.FleetDevicePosture, len(merged))
	for _, d := range merged {
		byID[d.Device] = d
	}

	if byID["maui"].UpdateStatus != "current" {
		t.Fatalf("expected maui current, got %+v", byID["maui"])
	}
	if byID["tala"].UpdateStatus != "update_available" {
		t.Fatalf("expected tala update_available, got %+v", byID["tala"])
	}
	if byID["workstation"].UpdateStatus != "stale" {
		t.Fatalf("expected >21d workstation stale, got %+v", byID["workstation"])
	}

	findings := EvaluateFleetPosture(merged, bundle, now)
	fByID := make(map[string]model.Finding, len(findings))
	for _, f := range findings {
		fByID[f.ID] = f
	}
	if _, ok := fByID["fleet:update:maui"]; ok {
		t.Fatalf("did not expect finding for current maui")
	}
	if fByID["fleet:update:tala"].Severity != model.SeverityDigest {
		t.Fatalf("expected digest finding for tala minor rev diff, got %+v", fByID["fleet:update:tala"])
	}
	if fByID["fleet:update:workstation"].Severity != model.SeverityDaily {
		t.Fatalf("expected daily finding for stale workstation, got %+v", fByID["fleet:update:workstation"])
	}
}

func TestFleetSNMPReviewDueEoLAndCISAKEVMatching(t *testing.T) {
	now := time.Date(2026, 11, 27, 12, 0, 0, 0, time.UTC)

	manifest := []model.FleetDevicePosture{
		{
			Device:             "teka",
			Role:               "nas",
			Vendor:             "Synology",
			Product:            "DS218+",
			RunningVersion:     "DSM 7.1.1-42962 Update 9",
			VersionSource:      "verified_inventory",
			ReviewIntervalDays: 14,
			LastVerifiedAt:     now.Add(-48 * time.Hour),
		},
		{
			Device:             "tamatoa",
			Role:               "core-switch",
			Vendor:             "Brocade",
			Product:            "ICX6450-48",
			RunningVersion:     "08.0.30uT313",
			EOLStatus:          "EoL mitigated by ACLs",
			VersionSource:      "live_snmp",
			ReviewIntervalDays: 30,
			LastVerifiedAt:     now.Add(-48 * time.Hour),
		},
		{
			Device:             "chief-tui",
			Role:               "cold-standby",
			Vendor:             "Ubiquiti",
			Product:            "EdgeRouter 6P",
			RunningVersion:     "EdgeOS v3.0.1",
			VersionSource:      "verified_inventory",
			ReviewIntervalDays: 30,
			LastVerifiedAt:     now.Add(-40 * 24 * time.Hour), // overdue > 30d
		},
		{
			Device:             "ruckus-secondfloor",
			Role:               "ap-master",
			Vendor:             "Ruckus",
			Product:            "Unleashed R550",
			RunningVersion:     "200.19.7.112.291",
			VersionSource:      "verified_inventory",
			ReviewIntervalDays: 30,
			LastVerifiedAt:     now.Add(-24 * time.Hour),
		},
		{
			Device:             "maui",
			Role:               "services-hub",
			Vendor:             "NixOS",
			Product:            "NixOS 26.11 + Grafana 13.3.1",
			RunningVersion:     "26.11.20261127.3068c73",
			UpdateChannel:      "nixos-26.11",
			ReviewIntervalDays: 30,
			LastVerifiedAt:     now.Add(-24 * time.Hour),
		},
	}

	st := model.State{
		FleetDevices: map[string]model.FleetDevicePosture{
			"teka": {
				Device:               "teka",
				SNMPUpgradeAvailable: 1,
				VersionSource:        "live_snmp",
				LastCheckedAt:        now,
			},
		},
	}

	bundle := &feeds.FeedBundle{
		NixOSChannelRevs: map[string]string{
			"nixos-26.11": "3068c73a96a6979ee8e72e7196577d0bd842d412",
		},
		KEVByCVE: map[string]feeds.KEVEntry{
			// Patched historical KEVs that must NOT fire false positives:
			"CVE-2024-10441": {CVEID: "CVE-2024-10441", VendorProject: "Synology", Product: "DiskStation Manager (DSM)"},
			"CVE-2023-25717": {CVEID: "CVE-2023-25717", VendorProject: "Ruckus Wireless", Product: "Unleashed"},
			"CVE-2021-43798": {CVEID: "CVE-2021-43798", VendorProject: "Grafana Labs", Product: "Grafana"},
			// Unrelated products from same vendors that must NOT fire false positives:
			"CVE-2026-34910": {CVEID: "CVE-2026-34910", VendorProject: "Ubiquiti", Product: "UniFi OS"},
			"CVE-2025-1976":  {CVEID: "CVE-2025-1976", VendorProject: "Broadcom", Product: "Brocade Fabric OS"},
			// True active non-OPNsense KEV affecting EdgeOS:
			"CVE-2026-99999": {CVEID: "CVE-2026-99999", VendorProject: "Ubiquiti", Product: "EdgeOS", VulnerabilityName: "EdgeRouter auth bypass", DueDate: "2026-12-10", RequiredAction: "Apply vendor hotfix"},
		},
	}

	merged := MergeFleetPosture(manifest, st, nil, bundle, now)
	byID := make(map[string]model.FleetDevicePosture, len(merged))
	for _, d := range merged {
		byID[d.Device] = d
	}

	if byID["teka"].UpdateStatus != "update_available" {
		t.Fatalf("expected teka update_available via SNMP, got %+v", byID["teka"])
	}
	if byID["tamatoa"].UpdateStatus != "eol_mitigated" {
		t.Fatalf("expected tamatoa eol_mitigated, got %+v", byID["tamatoa"])
	}
	if byID["chief-tui"].UpdateStatus != "review_due" {
		t.Fatalf("expected chief-tui review_due, got %+v", byID["chief-tui"])
	}

	findings := EvaluateFleetPosture(merged, bundle, now)
	gotIDs := make(map[string]model.Finding, len(findings))
	for _, f := range findings {
		gotIDs[f.ID] = f
	}

	if _, ok := gotIDs["fleet:kev:chief-tui:CVE-2026-99999"]; !ok {
		t.Fatalf("expected urgent EdgeOS KEV finding, got %+v", findings)
	}
	if gotIDs["fleet:kev:chief-tui:CVE-2026-99999"].Severity != model.SeverityUrgent || !gotIDs["fleet:kev:chief-tui:CVE-2026-99999"].KEV {
		t.Fatalf("unexpected KEV finding metadata: %+v", gotIDs["fleet:kev:chief-tui:CVE-2026-99999"])
	}
	if gotIDs["fleet:update:teka"].Severity != model.SeverityDaily {
		t.Fatalf("expected daily update finding for teka, got %+v", gotIDs["fleet:update:teka"])
	}
	if gotIDs["fleet:review-due:chief-tui"].Severity != model.SeverityDigest {
		t.Fatalf("expected digest review-due finding for chief-tui, got %+v", gotIDs["fleet:review-due:chief-tui"])
	}

	// Ensure no false positives triggered.
	for _, bad := range []string{
		"fleet:kev:teka:CVE-2024-10441",
		"fleet:kev:ruckus-secondfloor:CVE-2023-25717",
		"fleet:kev:maui:CVE-2021-43798",
		"fleet:kev:chief-tui:CVE-2026-34910",
		"fleet:kev:tamatoa:CVE-2025-1976",
	} {
		if _, ok := gotIDs[bad]; ok {
			t.Fatalf("unexpected false-positive KEV finding %s", bad)
		}
	}
}

func TestLoadFleetManifestWrapperAndMissing(t *testing.T) {
	if list, err := LoadFleetManifest(""); err != nil || list != nil {
		t.Fatalf("empty path should return nil, nil: got %v, %v", list, err)
	}
	if list, err := LoadFleetManifest("/nonexistent/manifest.json"); err != nil || list != nil {
		t.Fatalf("missing path should return nil, nil: got %v, %v", list, err)
	}

	dir := t.TempDir()
	p := filepath.Join(dir, "fleet.json")
	if err := os.WriteFile(p, []byte(`{"devices":[{"device":"tamatoa","running_version":"08.0.30uT313"}]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	list, err := LoadFleetManifest(p)
	if err != nil || len(list) != 1 || list[0].Device != "tamatoa" {
		t.Fatalf("unexpected wrapper parse: %+v, err=%v", list, err)
	}
}

func TestSynologySNMP2PartVersionMergeAndKEV(t *testing.T) {
	now := time.Date(2026, 11, 27, 12, 0, 0, 0, time.UTC)

	manifest := []model.FleetDevicePosture{
		{
			Device:             "teka",
			Role:               "nas",
			Vendor:             "Synology",
			Product:            "DS218+",
			RunningVersion:     "DSM 7.1.1-42962 Update 9",
			VersionSource:      "verified_inventory",
			UpdateChannel:      "DSM 7.x",
			ReviewIntervalDays: 14,
			LastVerifiedAt:     now.Add(-24 * time.Hour),
		},
	}

	bundle := &feeds.FeedBundle{
		KEVByCVE: map[string]feeds.KEVEntry{
			"CVE-2024-10441": {
				CVEID:             "CVE-2024-10441",
				VendorProject:     "Synology",
				Product:           "DiskStation Manager (DSM)",
				VulnerabilityName: "Synology DSM Improper Auth",
			},
		},
	}

	// Case 1: Same build reported as coarser 2-part SNMP string preserves specific manifest detail.
	stSame := model.State{
		FleetDevices: map[string]model.FleetDevicePosture{
			"teka": {
				Device:         "teka",
				Product:        "DS218+",
				RunningVersion: "DSM 7.1-42962",
				VersionSource:  "live_snmp",
				LastCheckedAt:  now,
			},
		},
	}
	mergedSame := MergeFleetPosture(manifest, stSame, nil, bundle, now)
	if len(mergedSame) != 1 {
		t.Fatalf("expected 1 device, got %d", len(mergedSame))
	}
	if mergedSame[0].RunningVersion != "DSM 7.1.1-42962 Update 9" ||
		mergedSame[0].VersionSource != "live_snmp" ||
		!mergedSame[0].LastCheckedAt.Equal(now) {
		t.Fatalf("unexpected merged teka posture: %+v", mergedSame[0])
	}
	for _, f := range EvaluateFleetPosture(mergedSame, bundle, now) {
		if f.ID == "fleet:kev:teka:CVE-2024-10441" {
			t.Fatalf("unexpected false-positive KEV finding after 2-part SNMP merge: %+v", f)
		}
	}

	// Case 2: Newer DSM 7.2+ SNMP 2-part string overwrites older manifest version and clears CVE-2024-10441.
	stUpgrade := model.State{
		FleetDevices: map[string]model.FleetDevicePosture{
			"teka": {
				Device:         "teka",
				Product:        "DS218+",
				RunningVersion: "DSM 7.2-72806",
				VersionSource:  "live_snmp",
				LastCheckedAt:  now,
			},
		},
	}
	mergedUpgrade := MergeFleetPosture(manifest, stUpgrade, nil, bundle, now)
	if mergedUpgrade[0].RunningVersion != "DSM 7.2-72806" {
		t.Fatalf("expected DSM 7.2-72806 overwrite, got %+v", mergedUpgrade[0])
	}
	for _, f := range EvaluateFleetPosture(mergedUpgrade, bundle, now) {
		if f.ID == "fleet:kev:teka:CVE-2024-10441" {
			t.Fatalf("unexpected KEV finding on DSM 7.2-72806: %+v", f)
		}
	}

	// Case 3: Direct unit checks on isDSM711Update7OrLater helper.
	for _, v := range []string{"DSM 7.2-72806", "DSM 7.3-86009", "DSM 7.4-90080"} {
		if !isDSM711Update7OrLater(v) {
			t.Fatalf("expected %q to satisfy >= DSM 7.1.1 Update 7", v)
		}
	}
	for _, v := range []string{"DSM 7.1.1-42962 Update 6", "DSM 7.1-42962"} {
		if isDSM711Update7OrLater(v) {
			t.Fatalf("expected %q not to satisfy >= DSM 7.1.1 Update 7", v)
		}
	}
}

func TestAuthentikReleaseAndGHSAMatching(t *testing.T) {
	now := time.Date(2026, 11, 27, 12, 0, 0, 0, time.UTC)
	bundle := &feeds.FeedBundle{
		AuthentikLatestRelease: "2026.8.7",
		AuthentikGHSAs: []feeds.GHSAAdvisory{
			{
				GHSAID:   "GHSA-jw8g-8f5p-9pwm",
				Severity: "critical",
				Summary:  "Flow stages skipped on errors",
				HTMLURL:  "https://github.com/goauthentik/authentik/security/advisories/GHSA-jw8g-8f5p-9pwm",
				Vulnerabilities: []feeds.GHSAVulnerability{
					{
						Package:                feeds.GHSAPackage{Name: "authentik"},
						VulnerableVersionRange: "<= 2026.5.8",
						PatchedVersions:        "2026.5.9",
					},
					{
						Package:                feeds.GHSAPackage{Name: "authentik"},
						VulnerableVersionRange: "<= 2026.8.6",
						PatchedVersions:        "2026.8.7",
					},
				},
			},
		},
	}

	makeManifest := func(ver string) []model.FleetDevicePosture {
		return []model.FleetDevicePosture{
			{
				Device:             "authentik",
				Role:               "identity-provider",
				Vendor:             "Authentik",
				Product:            "Authentik OCI (tala)",
				RunningVersion:     ver,
				VersionSource:      "declared_oci_pin",
				UpdateChannel:      "ghcr.io/goauthentik/server",
				ReviewIntervalDays: 14,
				LastVerifiedAt:     now.Add(-24 * time.Hour),
			},
		}
	}

	// Case 1: 2026.8.7 is current with 0 findings.
	cur := MergeFleetPosture(makeManifest("2026.8.7"), model.State{}, nil, bundle, now)
	if len(cur) != 1 || cur[0].UpdateStatus != "current" || cur[0].AvailableVersion != "" {
		t.Fatalf("expected authentik 2026.8.7 current, got %+v", cur)
	}
	if fs := EvaluateFleetPosture(cur, bundle, now); len(fs) != 0 {
		t.Fatalf("expected 0 findings for patched 2026.8.7, got %+v", fs)
	}

	// Case 2: 2026.8.6 triggers update_available AND urgent critical GHSA finding.
	old := MergeFleetPosture(makeManifest("2026.8.6"), model.State{}, nil, bundle, now)
	if old[0].UpdateStatus != "update_available" || old[0].AvailableVersion != "2026.8.7" {
		t.Fatalf("expected authentik 2026.8.6 update_available=2026.8.7, got %+v", old[0])
	}
	oldFindings := EvaluateFleetPosture(old, bundle, now)
	var sawUpdate, sawGHSA bool
	for _, f := range oldFindings {
		if f.ID == "fleet:update:authentik" && f.Severity == model.SeverityDaily {
			sawUpdate = true
		}
		if f.ID == "fleet:ghsa:authentik:GHSA-jw8g-8f5p-9pwm" && f.Severity == model.SeverityUrgent {
			sawGHSA = true
		}
	}
	if !sawUpdate || !sawGHSA {
		t.Fatalf("expected update + urgent GHSA finding for 2026.8.6, got %+v", oldFindings)
	}

	// Case 3: 2026.5.9 (patched LTS branch) must NOT false-positive against <= 2026.8.6.
	lts := MergeFleetPosture(makeManifest("2026.5.9"), model.State{}, nil, bundle, now)
	for _, f := range EvaluateFleetPosture(lts, bundle, now) {
		if strings.HasPrefix(f.ID, "fleet:ghsa:authentik:") {
			t.Fatalf("unexpected false-positive GHSA on patched LTS branch 2026.5.9: %+v", f)
		}
	}
}
