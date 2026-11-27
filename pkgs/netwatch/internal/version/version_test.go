package version

import (
	"reflect"
	"testing"
)

func TestExtractCVEsUnicodeDashes(t *testing.T) {
	got := ExtractCVEs(
		"incomplete fix of CVE\u20112026\u2011119409 and cve-2025-15367",
		"duplicate CVE-2026-119409 plus CVE\u20132026\u2014124851",
	)
	want := []string{"CVE-2025-15367", "CVE-2026-119409", "CVE-2026-124851"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ExtractCVEs() = %v, want %v", got, want)
	}
}

func TestCompareOPNsenseOrdering(t *testing.T) {
	ordered := []string{
		"26.1.9",
		"26.7.a1",
		"26.7.r1",
		"26.7.r2",
		"26.7",
		"26.7.1",
		"26.7.8",
		"26.7.9",
		"26.7.10",
		"26.7.10_1",
		"26.10.0",
		"26.10.0p1",
		"26.10.0p2",
	}
	for i := 0; i < len(ordered)-1; i++ {
		cmp, err := CompareOPNsense(ordered[i], ordered[i+1])
		if err != nil {
			t.Fatalf("CompareOPNsense(%q, %q) unexpected err: %v", ordered[i], ordered[i+1], err)
		}
		if cmp != -1 {
			t.Fatalf("CompareOPNsense(%q, %q) = %d, want -1", ordered[i], ordered[i+1], cmp)
		}
	}
}

func TestMatchesRange(t *testing.T) {
	tests := []struct {
		name      string
		running   string
		series    string
		edition   string
		rangeExpr string
		want      bool
	}{
		{
			name:      "GHSA-89wp-xvvm-9pp4 on patched 26.7.10",
			running:   "26.7.10",
			series:    "26.7",
			edition:   "community",
			rangeExpr: "<= 26.7.9, 26.10.0p1",
			want:      false,
		},
		{
			name:      "GHSA-89wp-xvvm-9pp4 on vulnerable 26.7.9",
			running:   "26.7.9",
			series:    "26.7",
			edition:   "community",
			rangeExpr: "<= 26.7.9, 26.10.0p1",
			want:      true,
		},
		{
			name:      "interval match inside 26.7.x",
			running:   "26.7.8",
			series:    "26.7",
			edition:   "community",
			rangeExpr: ">= 26.7, <= 26.7.9",
			want:      true,
		},
		{
			name:      "interval excludes 26.7.10",
			running:   "26.7.10",
			series:    "26.7",
			edition:   "community",
			rangeExpr: ">= 26.7, <= 26.7.9",
			want:      false,
		},
		{
			name:      "interval excludes older series 26.1.5",
			running:   "26.1.5",
			series:    "26.1",
			edition:   "community",
			rangeExpr: ">= 26.7, <= 26.7.9",
			want:      false,
		},
		{
			name:      "business clause does not match community 26.7.10",
			running:   "26.7.10",
			series:    "26.7",
			edition:   "community",
			rangeExpr: "<= 26.10.0p1",
			want:      false,
		},
		{
			name:      "business host matches business clause",
			running:   "26.10.0p1",
			series:    "26.10",
			edition:   "business",
			rangeExpr: "<= 26.7.9, 26.10.0p1",
			want:      true,
		},
		{
			name:      "exact version match",
			running:   "26.7.10",
			series:    "26.7",
			edition:   "community",
			rangeExpr: "26.7.10",
			want:      true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := MatchesRange(tc.running, tc.series, tc.edition, tc.rangeExpr)
			if got != tc.want {
				t.Fatalf("MatchesRange(%q, %q, %q, %q) = %v, want %v",
					tc.running, tc.series, tc.edition, tc.rangeExpr, got, tc.want)
			}
		})
	}

	if MatchesPackageRange("4.4", ">= 1.0, <= 1.2") {
		t.Fatalf("expected plugin interval >= 1.0, <= 1.2 NOT to match 4.4")
	}
	if !MatchesPackageRange("4.10", "<= 4.10.1") {
		t.Fatalf("expected plugin 4.10 to match <= 4.10.1")
	}
}
