package config

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestLoadFromEnvFileAndOverrides(t *testing.T) {
	dir := t.TempDir()
	envPath := filepath.Join(dir, "netwatch.env")
	err := os.WriteFile(envPath, []byte(`
# comment
NETWATCH_INGEST_TOKEN="tok-from-file"
NETWATCH_SMTP_PORT=587
NETWATCH_SMTP_TLS=starttls
NETWATCH_MAIL_TO='andre@example.com, second@example.com'
NETWATCH_DIGEST_WEEKDAY=Monday
`), 0o600)
	if err != nil {
		t.Fatalf("write env file: %v", err)
	}

	t.Setenv("NETWATCH_SMTP_PORT", "465")
	cfg, err := Load(envPath)
	if err != nil {
		t.Fatalf("Load() err: %v", err)
	}
	if cfg.IngestToken != "tok-from-file" {
		t.Fatalf("expected token from file, got %q", cfg.IngestToken)
	}
	if cfg.SMTP.Port != 465 {
		t.Fatalf("expected env override SMTP port 465, got %d", cfg.SMTP.Port)
	}
	if len(cfg.SMTP.To) != 2 || cfg.SMTP.To[1] != "second@example.com" {
		t.Fatalf("unexpected recipients: %v", cfg.SMTP.To)
	}
	if cfg.DigestWeekday != time.Monday {
		t.Fatalf("expected Monday digest weekday, got %v", cfg.DigestWeekday)
	}
	if cfg.SyslogAddr != "" || cfg.SyslogStaleAfter != 15*time.Minute || cfg.WANInterface != "igc1" {
		t.Fatalf("unexpected syslog defaults: addr=%q stale=%v wan=%q", cfg.SyslogAddr, cfg.SyslogStaleAfter, cfg.WANInterface)
	}
	if len(cfg.AllowedWANInboundPorts) != 1 || cfg.AllowedWANInboundPorts[0] != 443 {
		t.Fatalf("unexpected default allowed WAN ports: %v", cfg.AllowedWANInboundPorts)
	}

	t.Setenv("NETWATCH_SYSLOG_ADDR", "0.0.0.0:5514")
	t.Setenv("NETWATCH_SYSLOG_STALE_AFTER", "20m")
	t.Setenv("NETWATCH_ADMIN_USERS", "andre,ops")
	t.Setenv("NETWATCH_ADMIN_SOURCES", "192.168.10.75/32")
	t.Setenv("NETWATCH_ALLOWED_WAN_PORTS", "443,8443")
	cfg2, err := Load(envPath)
	if err != nil {
		t.Fatalf("Load() override err: %v", err)
	}
	if cfg2.SyslogAddr != "0.0.0.0:5514" || cfg2.SyslogStaleAfter != 20*time.Minute {
		t.Fatalf("expected syslog env overrides, got addr=%q stale=%v", cfg2.SyslogAddr, cfg2.SyslogStaleAfter)
	}
	if len(cfg2.AdminUsers) != 2 || len(cfg2.AllowedWANInboundPorts) != 2 || cfg2.AllowedWANInboundPorts[1] != 8443 {
		t.Fatalf("unexpected CSV overrides: users=%v ports=%v", cfg2.AdminUsers, cfg2.AllowedWANInboundPorts)
	}
}
