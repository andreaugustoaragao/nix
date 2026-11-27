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
}
