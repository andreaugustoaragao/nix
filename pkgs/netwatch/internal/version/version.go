package version

import (
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

var (
	dashReplacer = strings.NewReplacer(
		"\u2010", "-",
		"\u2011", "-",
		"\u2012", "-",
		"\u2013", "-",
		"\u2014", "-",
		"\u2015", "-",
		"\u2212", "-",
	)
	cvePattern = regexp.MustCompile(`(?i)\bCVE-(\d{4})-(\d{4,})\b`)
)

// NormalizeDashes converts Unicode hyphens and minus signs to ASCII '-'.
func NormalizeDashes(s string) string {
	return dashReplacer.Replace(s)
}

// ExtractCVEs extracts deduplicated, sorted uppercase CVE IDs across the input strings.
func ExtractCVEs(texts ...string) []string {
	seen := make(map[string]struct{})
	for _, raw := range texts {
		norm := NormalizeDashes(raw)
		for _, m := range cvePattern.FindAllString(norm, -1) {
			seen[strings.ToUpper(m)] = struct{}{}
		}
	}
	if len(seen) == 0 {
		return nil
	}
	out := make([]string, 0, len(seen))
	for c := range seen {
		out = append(out, c)
	}
	sort.Strings(out)
	return out
}

type parsedOPN struct {
	major   int
	minor   int
	patch   int
	preRank int // negative for a/b/rc/r, 0 for normal, +N for pN
	portRev int // _N suffix
}

func parseOPNsense(raw string) (parsedOPN, bool) {
	s := strings.TrimSpace(NormalizeDashes(raw))
	s = strings.TrimPrefix(strings.ToLower(s), "v")
	if s == "" {
		return parsedOPN{}, false
	}

	var p parsedOPN
	if idx := strings.IndexByte(s, '_'); idx != -1 {
		revStr := s[idx+1:]
		s = s[:idx]
		rev, err := strconv.Atoi(revStr)
		if err != nil || rev < 0 {
			return parsedOPN{}, false
		}
		p.portRev = rev
	}

	// Check patch suffix on full string like 26.10.0p1
	if idx := strings.IndexByte(s, 'p'); idx != -1 {
		before := s[:idx]
		after := s[idx+1:]
		if pNum, err := strconv.Atoi(after); err == nil && pNum > 0 && before != "" {
			s = before
			p.preRank = pNum
		}
	}

	parts := strings.Split(s, ".")
	if len(parts) < 2 || len(parts) > 3 {
		return parsedOPN{}, false
	}
	maj, err := strconv.Atoi(parts[0])
	if err != nil {
		return parsedOPN{}, false
	}
	min, err := strconv.Atoi(parts[1])
	if err != nil {
		return parsedOPN{}, false
	}
	p.major = maj
	p.minor = min

	if len(parts) == 3 {
		seg := parts[2]
		switch {
		case strings.HasPrefix(seg, "rc"):
			n, err := strconv.Atoi(strings.TrimPrefix(seg, "rc"))
			if err != nil {
				return parsedOPN{}, false
			}
			p.preRank = -1000 + n
		case strings.HasPrefix(seg, "r"):
			n, err := strconv.Atoi(strings.TrimPrefix(seg, "r"))
			if err != nil {
				return parsedOPN{}, false
			}
			p.preRank = -1000 + n
		case strings.HasPrefix(seg, "b"):
			n, err := strconv.Atoi(strings.TrimPrefix(seg, "b"))
			if err != nil {
				return parsedOPN{}, false
			}
			p.preRank = -2000 + n
		case strings.HasPrefix(seg, "a"):
			n, err := strconv.Atoi(strings.TrimPrefix(seg, "a"))
			if err != nil {
				return parsedOPN{}, false
			}
			p.preRank = -3000 + n
		default:
			pat, err := strconv.Atoi(seg)
			if err != nil {
				return parsedOPN{}, false
			}
			p.patch = pat
		}
	}

	return p, true
}

// CompareOPNsense compares two OPNsense version strings (-1 if a<b, 0 if a==b, +1 if a>b).
func CompareOPNsense(a, b string) (int, error) {
	pa, okA := parseOPNsense(a)
	if !okA {
		return 0, fmt.Errorf("invalid OPNsense version %q", a)
	}
	pb, okB := parseOPNsense(b)
	if !okB {
		return 0, fmt.Errorf("invalid OPNsense version %q", b)
	}
	for _, pair := range [][2]int{
		{pa.major, pb.major},
		{pa.minor, pb.minor},
		{pa.patch, pb.patch},
		{pa.preRank, pb.preRank},
		{pa.portRev, pb.portRev},
	} {
		if pair[0] < pair[1] {
			return -1, nil
		}
		if pair[0] > pair[1] {
			return 1, nil
		}
	}
	return 0, nil
}

// SeriesOf extracts "major.minor" from an OPNsense version string.
func SeriesOf(v string) string {
	p, ok := parseOPNsense(v)
	if !ok {
		return ""
	}
	return fmt.Sprintf("%d.%d", p.major, p.minor)
}

func isBusinessSeries(minor int) bool {
	return minor == 4 || minor == 10
}

func isCommunitySeries(minor int) bool {
	return minor == 1 || minor == 7
}

func matchesEdition(clause parsedOPN, edition, runningSeries string) bool {
	ed := strings.ToLower(strings.TrimSpace(edition))
	clauseSeries := fmt.Sprintf("%d.%d", clause.major, clause.minor)
	switch ed {
	case "community":
		if isBusinessSeries(clause.minor) {
			return false
		}
	case "business":
		if runningSeries != "" && runningSeries != clauseSeries && isCommunitySeries(clause.minor) {
			return false
		}
	}
	return true
}

type clause struct {
	op  string
	ver string
	p   parsedOPN
}

func parseClause(raw string) (clause, bool) {
	s := strings.TrimSpace(NormalizeDashes(raw))
	if s == "" {
		return clause{}, false
	}
	op := "="
	ver := s
	for _, candidate := range []string{"<=", ">=", "<", ">", "="} {
		if strings.HasPrefix(s, candidate) {
			op = candidate
			ver = strings.TrimSpace(strings.TrimPrefix(s, candidate))
			break
		}
	}
	p, ok := parseOPNsense(ver)
	if !ok {
		return clause{}, false
	}
	return clause{op: op, ver: ver, p: p}, true
}

func evalClause(running parsedOPN, c clause) bool {
	cmp := 0
	for _, pair := range [][2]int{
		{running.major, c.p.major},
		{running.minor, c.p.minor},
		{running.patch, c.p.patch},
		{running.preRank, c.p.preRank},
		{running.portRev, c.p.portRev},
	} {
		if pair[0] < pair[1] {
			cmp = -1
			break
		}
		if pair[0] > pair[1] {
			cmp = 1
			break
		}
	}
	switch c.op {
	case "<=":
		return cmp <= 0
	case "<":
		return cmp < 0
	case ">=":
		return cmp >= 0
	case ">":
		return cmp > 0
	case "=":
		return cmp == 0
	default:
		return false
	}
}

// MatchesRange evaluates OPNsense GHSA vulnerable_version_range strings against a running version.
// It distinguishes interval pairs (e.g. ">= 26.7, <= 26.7.9") from cross-series branch lists
// (e.g. "<= 26.7.9, 26.10.0p1") and ignores clauses belonging to a different edition track.
func MatchesRange(running, series, edition, rangeExpr string) bool {
	return matchesRange(running, series, edition, rangeExpr, true)
}

// MatchesPackageRange evaluates version ranges for OPNsense plugins without applying
// YY.04/YY.10 community-vs-business release series filtering.
func MatchesPackageRange(running, rangeExpr string) bool {
	return matchesRange(running, "", "", rangeExpr, false)
}

func matchesRange(running, series, edition, rangeExpr string, filterSeries bool) bool {
	rp, ok := parseOPNsense(running)
	if !ok {
		return false
	}
	runSeries := strings.TrimSpace(series)
	if runSeries == "" {
		runSeries = fmt.Sprintf("%d.%d", rp.major, rp.minor)
	}
	if strings.TrimSpace(rangeExpr) == "" {
		return false
	}

	rawParts := strings.Split(rangeExpr, ",")
	clauses := make([]clause, 0, len(rawParts))
	for _, part := range rawParts {
		if c, ok := parseClause(part); ok {
			clauses = append(clauses, c)
		}
	}
	if len(clauses) == 0 {
		return false
	}

	// Group consecutive (> / >=) + (< / <=) bounds into AND intervals when lower <= upper.
	for i := 0; i < len(clauses); {
		c := clauses[i]
		if (c.op == ">" || c.op == ">=") && i+1 < len(clauses) && (clauses[i+1].op == "<" || clauses[i+1].op == "<=") {
			upper := clauses[i+1]
			cmp, err := CompareOPNsense(c.ver, upper.ver)
			if err == nil && cmp <= 0 {
				if (!filterSeries || matchesEdition(upper.p, edition, runSeries)) && evalClause(rp, c) && evalClause(rp, upper) {
					return true
				}
				i += 2
				continue
			}
		}
		if (!filterSeries || matchesEdition(c.p, edition, runSeries)) && evalClause(rp, c) {
			return true
		}
		i++
	}
	return false
}
