package people

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolve(t *testing.T) {
	dir := t.TempDir()
	files := map[string]string{
		"pier_angelo_tognini_filho.md": "# Pier Angelo Tognini Filho\n\n## Profile\n- **Email:** ptognini@avaya.com\n",
		"steve_whynot.md":              "# Steve Whynot\n\n## Profile\n- **Email:** steverw@avaya.com\n",
		"steve_mcintyre.md":            "# Steve McIntyre\n\n## Profile\n- **Email:** stevepm@avaya.com\n",
		"no_email.md":                  "# Missing Email\n\n## Profile\n- **Role:** Test\n",
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	roster, err := LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	if len(roster) != 3 {
		t.Fatalf("expected 3 people with emails, got %d", len(roster))
	}

	cases := []struct {
		query string
		want  string
	}{
		{"ptognini@avaya.com", "ptognini@avaya.com"},
		{"Someone Else <other@example.com>", "other@example.com"},
		{"Pier Angelo Tognini Filho", "ptognini@avaya.com"},
		{"Pier Angelo", "ptognini@avaya.com"},
		{"Pier Agenlo", "ptognini@avaya.com"},
		{"pier_angelo_tognini_filho", "ptognini@avaya.com"},
		{"Steve Whynot", "steverw@avaya.com"},
	}
	for _, tc := range cases {
		got, err := Resolve(tc.query, roster)
		if err != nil {
			t.Errorf("Resolve(%q) unexpected err: %v", tc.query, err)
			continue
		}
		if got.Email != tc.want {
			t.Errorf("Resolve(%q) = %q, want %q", tc.query, got.Email, tc.want)
		}
	}

	if _, err := Resolve("Steve", roster); err == nil || !strings.Contains(err.Error(), "ambiguous") {
		t.Fatalf("expected ambiguous error for 'Steve', got %v", err)
	}
	if _, err := Resolve("Nonexistent Person", roster); err == nil {
		t.Fatalf("expected not-found error for unknown person")
	}
}
