package model

import "time"

const (
	SeverityUrgent = "urgent"
	SeverityDaily  = "daily"
	SeverityDigest = "digest"

	StatusOpen     = "open"
	StatusAcked    = "acked"
	StatusResolved = "resolved"

	CategorySecurityEvent = "security_event"
	CategoryExposureDrift = "exposure_drift"
)

// OPNsenseSnapshot is the read-only inventory, audit, and exposure payload pushed by the firewall.
type OPNsenseSnapshot struct {
	Host            string          `json:"host"`
	CollectedAt     time.Time       `json:"collected_at"`
	Edition         string          `json:"edition"`
	ProductID       string          `json:"product_id"`
	ProductVersion  string          `json:"product_version"`
	ProductSeries   string          `json:"product_series"`
	ProductABI      string          `json:"product_abi"`
	ProductHash     string          `json:"product_hash"`
	FreeBSDKernel   string          `json:"freebsd_kernel"`
	FreeBSDUserland string          `json:"freebsd_userland"`
	FreeBSDRunning         string          `json:"freebsd_running"`
	PackageCount           int             `json:"package_count"`
	AuditOK                bool            `json:"audit_ok"`
	AuditError             string          `json:"audit_error"`
	WebGUICertNotAfterUnix int64           `json:"webgui_cert_not_after_unix,omitempty"`
	WebGUICertSubject      string          `json:"webgui_cert_subject,omitempty"`
	Plugins                []PackageInfo   `json:"plugins"`
	PkgAudit        PkgAuditResult  `json:"pkg_audit"`
	FirmwareCheck   FirmwareCheck   `json:"firmware_check"`
	Services        []string        `json:"services"`
	Exposure        ExposureSummary `json:"exposure"`
}

// PackageInfo describes an installed OPNsense plugin package.
type PackageInfo struct {
	Name    string `json:"name"`
	Version string `json:"version"`
	Origin  string `json:"origin"`
}

// ExposureSummary holds non-secret firewall WAN pass and DNAT rule summaries.
type ExposureSummary struct {
	WANInterface string   `json:"wan_interface"`
	WANPassRules []string `json:"wan_pass_rules"`
	WANRDRRules  []string `json:"wan_rdr_rules"`
}

// FirmwareCheck models passive firmware update check output from the firewall.
type FirmwareCheck struct {
	LastCheck           string           `json:"last_check"`
	ProductVersion      string           `json:"product_version"`
	NeedsReboot         string           `json:"needs_reboot"`
	UpgradeNeedsReboot  string           `json:"upgrade_needs_reboot"`
	UpgradeMajorVersion string           `json:"upgrade_major_version"`
	UpdateHint          string           `json:"update_hint"`
	UpgradePackages     []UpgradePackage `json:"upgrade_packages"`
	UpgradeSets         []UpgradeSet     `json:"upgrade_sets"`
}

// UpgradePackage represents a pending package upgrade entry.
type UpgradePackage struct {
	Name           string `json:"name"`
	CurrentVersion string `json:"current_version"`
	NewVersion     string `json:"new_version"`
	Version        string `json:"version"`
	Repository     string `json:"repository"`
}

// UpgradeSet represents a base or kernel set upgrade entry.
type UpgradeSet struct {
	Name           string `json:"name"`
	Size           string `json:"size"`
	CurrentVersion string `json:"current_version"`
	NewVersion     string `json:"new_version"`
	Repository     string `json:"repository"`
}

// PkgAuditResult matches `pkg audit --raw=json-compact` output on FreeBSD.
type PkgAuditResult struct {
	PkgCount int                        `json:"pkg_count"`
	Packages map[string]PkgAuditPackage `json:"packages"`
}

// PkgAuditPackage describes one vulnerable installed package and its reverse dependencies.
type PkgAuditPackage struct {
	Version             string          `json:"version"`
	IssueCount          int             `json:"issue_count"`
	Issues              []PkgAuditIssue `json:"issues"`
	ReverseDependencies []string        `json:"reverse dependencies"`
}

// PkgAuditIssue describes a single VuXML issue for an installed package.
type PkgAuditIssue struct {
	AffectedVersions []string `json:"Affected versions"`
	Description      string   `json:"description"`
	CVE              []string `json:"cve"`
	URL              string   `json:"url"`
}

// Finding is a correlated, deduplicatable actionable or informational finding.
type Finding struct {
	ID                string    `json:"id"`
	Category          string    `json:"category"` // advisory | pkg_audit | firmware | forum | stale_monitor
	Severity          string    `json:"severity"` // urgent | daily | digest
	Device            string    `json:"device"`
	Title             string    `json:"title"`
	Summary           string    `json:"summary"`
	RunningVersion    string    `json:"running_version"`
	FixedVersion      string    `json:"fixed_version"`
	Mitigation        string    `json:"mitigation"`
	Exposure          string    `json:"exposure"`
	RebootExpected    string    `json:"reboot_expected"`
	RecommendedTiming string    `json:"recommended_timing"`
	CVEs              []string  `json:"cves"`
	KEV               bool      `json:"kev"`
	Sources           []string  `json:"sources"`
	Synthetic         bool      `json:"synthetic,omitempty"`
	FirstSeen         time.Time `json:"first_seen"`
	LastSeen          time.Time `json:"last_seen"`
}

// TrackedFinding persists notification, acknowledgement, and resolution lifecycle state.
type TrackedFinding struct {
	Finding
	Status         string     `json:"status"` // open | acked | resolved
	NotifiedCount  int        `json:"notified_count"`
	LastNotified   time.Time  `json:"last_notified,omitempty"`
	AcknowledgedAt *time.Time `json:"acknowledged_at,omitempty"`
	AckNote        string     `json:"ack_note,omitempty"`
	ResolvedAt     *time.Time `json:"resolved_at,omitempty"`
	LastSeverity   string     `json:"last_severity"`
}

// FeedStatus records refresh health and freshness for each external advisory feed.
type FeedStatus struct {
	Name        string    `json:"name"`
	URL         string    `json:"url"`
	LastAttempt time.Time `json:"last_attempt,omitempty"`
	LastSuccess time.Time `json:"last_success,omitempty"`
	LastError   string    `json:"last_error,omitempty"`
	ItemCount   int       `json:"item_count"`
}

// SyslogStats aggregates private firewall/IDS syslog activity without storing PII or raw log storms.
type SyslogStats struct {
	LastReceived            time.Time        `json:"last_received,omitempty"`
	TotalReceived           int64            `json:"total_received"`
	WANBlockedIn            int64            `json:"wan_blocked_in"`
	InternalOutboundBlocked int64            `json:"internal_outbound_blocked"`
	ExpectedAdminLogins     int64            `json:"expected_admin_logins"`
	IDSAlertsUrgent         int64            `json:"ids_alerts_urgent"`
	IDSAlertsDigest         int64            `json:"ids_alerts_digest"`
	TopBlockedPorts         map[string]int64 `json:"top_blocked_ports,omitempty"`
	LastReset               time.Time        `json:"last_reset,omitempty"`
}

// State is the atomic JSON state persisted by netwatch.
type State struct {
	LastUpdated      time.Time                  `json:"last_updated"`
	LatestSnapshot   *OPNsenseSnapshot          `json:"latest_snapshot,omitempty"`
	BaselineExposure *ExposureSummary           `json:"baseline_exposure,omitempty"`
	Syslog           SyslogStats                `json:"syslog"`
	MaintenanceUntil *time.Time                 `json:"maintenance_until,omitempty"`
	MaintenanceNote  string                     `json:"maintenance_note,omitempty"`
	FeedStatus       map[string]FeedStatus      `json:"feed_status"`
	Findings         map[string]*TrackedFinding `json:"findings"`
	LastDailySent    time.Time                  `json:"last_daily_sent,omitempty"`
	LastDigestSent   time.Time                  `json:"last_digest_sent,omitempty"`
	LastHeartbeatOK  time.Time                  `json:"last_heartbeat_ok,omitempty"`
	LastHeartbeatErr string                     `json:"last_heartbeat_err,omitempty"`
}
