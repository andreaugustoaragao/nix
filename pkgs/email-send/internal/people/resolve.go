package people

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Person holds identity fields parsed from a vault people/*.md file.
type Person struct {
	Name  string `json:"name"`
	Email string `json:"email"`
	File  string `json:"file"`
}

var (
	emailFieldRe = regexp.MustCompile(`(?i)^\s*-\s*\*\*Email:\*\*\s*(.+?)\s*$`)
	emailAddrRe  = regexp.MustCompile(`[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}`)
)

// LoadDir reads all people/*.md files in dir and extracts name and email.
func LoadDir(dir string) ([]Person, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read people dir %s: %w", dir, err)
	}
	var out []Person
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".md") {
			continue
		}
		path := filepath.Join(dir, entry.Name())
		p, ok, err := parseFile(path)
		if err != nil {
			return nil, err
		}
		if ok {
			out = append(out, p)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].Name < out[j].Name
	})
	return out, nil
}

func parseFile(path string) (Person, bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return Person{}, false, fmt.Errorf("open %s: %w", path, err)
	}
	defer f.Close()

	var name, email string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if name == "" && strings.HasPrefix(line, "# ") {
			name = strings.TrimSpace(strings.TrimPrefix(line, "# "))
			continue
		}
		if email == "" {
			if m := emailFieldRe.FindStringSubmatch(line); m != nil {
				if addr := emailAddrRe.FindString(m[1]); addr != "" {
					email = strings.ToLower(addr)
				}
			}
		}
		if name != "" && email != "" {
			break
		}
	}
	if err := sc.Err(); err != nil {
		return Person{}, false, fmt.Errorf("scan %s: %w", path, err)
	}
	if email == "" {
		return Person{}, false, nil
	}
	if name == "" {
		base := strings.TrimSuffix(filepath.Base(path), ".md")
		name = strings.ReplaceAll(base, "_", " ")
	}
	return Person{Name: name, Email: email, File: path}, true, nil
}

// Resolve resolves an input string (either a raw email address or a person name)
// against the vault's people roster.
func Resolve(query string, roster []Person) (Person, error) {
	q := strings.TrimSpace(query)
	if q == "" {
		return Person{}, fmt.Errorf("empty recipient")
	}

	// Direct email address (or "Display Name <email@domain>").
	if addr := emailAddrRe.FindString(q); addr != "" {
		lower := strings.ToLower(addr)
		for _, p := range roster {
			if strings.EqualFold(p.Email, lower) {
				return p, nil
			}
		}
		return Person{Name: lower, Email: lower}, nil
	}

	nq := normalize(q)
	qTokens := strings.Fields(nq)
	if len(qTokens) == 0 {
		return Person{}, fmt.Errorf("invalid recipient query %q", query)
	}

	// Pass 1: exact normalized full name or filename stem match.
	var exact []Person
	for _, p := range roster {
		if normalize(p.Name) == nq || normalize(stem(p.File)) == nq {
			exact = append(exact, p)
		}
	}
	if len(exact) == 1 {
		return exact[0], nil
	}
	if len(exact) > 1 {
		return Person{}, ambiguousErr(query, exact)
	}

	// Pass 2: all query tokens appear as prefix/substring of person name tokens.
	var tokenMatches []Person
	for _, p := range roster {
		if allTokensMatch(qTokens, strings.Fields(normalize(p.Name)), 0) {
			tokenMatches = append(tokenMatches, p)
		}
	}
	if len(tokenMatches) == 1 {
		return tokenMatches[0], nil
	}
	if len(tokenMatches) > 1 {
		return Person{}, ambiguousErr(query, tokenMatches)
	}

	// Pass 3: typo-tolerant token match (edit distance <= 2 per token of len >= 4).
	var fuzzy []Person
	for _, p := range roster {
		if allTokensMatch(qTokens, strings.Fields(normalize(p.Name)), 2) {
			fuzzy = append(fuzzy, p)
		}
	}
	if len(fuzzy) == 1 {
		return fuzzy[0], nil
	}
	if len(fuzzy) > 1 {
		return Person{}, ambiguousErr(query, fuzzy)
	}

	return Person{}, fmt.Errorf("recipient %q not found in vault people roster (%d entries)", query, len(roster))
}

func allTokensMatch(queryTokens, nameTokens []string, maxDist int) bool {
	if len(queryTokens) == 0 || len(nameTokens) == 0 {
		return false
	}
	for _, qt := range queryTokens {
		matched := false
		for _, nt := range nameTokens {
			if strings.HasPrefix(nt, qt) {
				matched = true
				break
			}
			if maxDist > 0 && len(qt) >= 4 && len(nt) >= 4 {
				limit := maxDist
				if len(qt) <= 5 && limit > 1 {
					limit = 1
				}
				if damerauLevenshtein(qt, nt) <= limit {
					matched = true
					break
				}
			}
		}
		if !matched {
			return false
		}
	}
	return true
}

func damerauLevenshtein(a, b string) int {
	ra, rb := []rune(a), []rune(b)
	la, lb := len(ra), len(rb)
	d := make([][]int, la+1)
	for i := range d {
		d[i] = make([]int, lb+1)
		d[i][0] = i
	}
	for j := 0; j <= lb; j++ {
		d[0][j] = j
	}
	for i := 1; i <= la; i++ {
		for j := 1; j <= lb; j++ {
			cost := 1
			if ra[i-1] == rb[j-1] {
				cost = 0
			}
			m := min(d[i-1][j]+1, d[i][j-1]+1, d[i-1][j-1]+cost)
			if i > 1 && j > 1 && ra[i-1] == rb[j-2] && ra[i-2] == rb[j-1] {
				if t := d[i-2][j-2] + cost; t < m {
					m = t
				}
			}
			d[i][j] = m
		}
	}
	return d[la][lb]
}

func normalize(s string) string {
	s = strings.ToLower(s)
	var b strings.Builder
	b.Grow(len(s))
	lastSpace := false
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			lastSpace = false
		} else if !lastSpace {
			b.WriteByte(' ')
			lastSpace = true
		}
	}
	return strings.TrimSpace(b.String())
}

func stem(path string) string {
	return strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
}

func ambiguousErr(query string, matches []Person) error {
	parts := make([]string, 0, len(matches))
	for _, m := range matches {
		parts = append(parts, fmt.Sprintf("%s <%s>", m.Name, m.Email))
	}
	return fmt.Errorf("ambiguous recipient %q matches %d people: %s", query, len(matches), strings.Join(parts, ", "))
}
