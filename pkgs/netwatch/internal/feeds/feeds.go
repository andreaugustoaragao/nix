package feeds

import (
	"context"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"html"
	"io"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	"faragao.net/netwatch/internal/model"
)

const (
	FeedKEV           = "cisa_kev"
	FeedCoreGHSA      = "opnsense_core_ghsa"
	FeedPluginsGHSA   = "opnsense_plugins_ghsa"
	FeedAnnouncements = "opnsense_forum_rss"

	DefaultKEVURL          = "https://raw.githubusercontent.com/cisagov/kev-data/main/known_exploited_vulnerabilities.json"
	DefaultKEVFallbackURL  = "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
	DefaultCoreGHSAURL     = "https://api.github.com/repos/opnsense/core/security-advisories?per_page=30"
	DefaultPluginsGHSAURL  = "https://api.github.com/repos/opnsense/plugins/security-advisories?per_page=30"
	DefaultForumRSSURL     = "https://forum.opnsense.org/index.php?type=rss;action=.xml;board=11.0"
	maxFeedResponseBytes   = 32 << 20 // 32 MiB cap
	defaultRequestTimeout  = 25 * time.Second
)

var (
	verInTitleRe = regexp.MustCompile(`(?i)\bOPNsense\s+([0-9]+\.[0-9]+(?:\.[0-9]+(?:p[0-9]+)?|\.[abrc0-9]+)?)\b`)
	htmlTagRe    = regexp.MustCompile(`<[^>]+>`)
)

// KEVEntry mirrors one entry in the CISA KEV catalog.
type KEVEntry struct {
	CVEID             string `json:"cveID"`
	VendorProject     string `json:"vendorProject"`
	Product           string `json:"product"`
	VulnerabilityName string `json:"vulnerabilityName"`
	DateAdded         string `json:"dateAdded"`
	ShortDescription  string `json:"shortDescription"`
	RequiredAction    string `json:"requiredAction"`
	DueDate           string `json:"dueDate"`
	Notes             string `json:"notes"`
}

// KEVCatalog represents the full CISA KEV JSON feed.
type KEVCatalog struct {
	CatalogVersion  string     `json:"catalogVersion"`
	Count           int        `json:"count"`
	Vulnerabilities []KEVEntry `json:"vulnerabilities"`
}

// GHSAPackage names the package in a GitHub security advisory.
type GHSAPackage struct {
	Ecosystem string `json:"ecosystem"`
	Name      string `json:"name"`
}

// GHSAVulnerability specifies the affected/patched range inside a GHSA.
type GHSAVulnerability struct {
	Package                GHSAPackage `json:"package"`
	VulnerableVersionRange string      `json:"vulnerable_version_range"`
	PatchedVersions        string      `json:"patched_versions"`
}

// GHSAAdvisory represents an advisory from the GitHub Security Advisories API.
type GHSAAdvisory struct {
	GHSAID          string              `json:"ghsa_id"`
	CVEID           string              `json:"cve_id"`
	Severity        string              `json:"severity"`
	Summary         string              `json:"summary"`
	Description     string              `json:"description"`
	HTMLURL         string              `json:"html_url"`
	PublishedAt     string              `json:"published_at"`
	UpdatedAt       string              `json:"updated_at"`
	Vulnerabilities []GHSAVulnerability `json:"vulnerabilities"`
}

// ForumItem represents one announcement parsed from the OPNsense forum RSS feed.
type ForumItem struct {
	Title       string
	Link        string
	Description string
	PubDate     string
	Version     string
	Business    bool
	IsReply     bool
}

// FeedBundle contains all fetched external feed payloads plus a CVE lookup map.
type FeedBundle struct {
	KEVByCVE      map[string]KEVEntry
	KEVVersion    string
	CoreGHSAs     []GHSAAdvisory
	PluginGHSAs   []GHSAAdvisory
	Announcements []ForumItem
}

// Fetcher retrieves advisory and release feeds with configurable endpoints for testing.
type Fetcher struct {
	Client         *http.Client
	KEVURL         string
	KEVFallbackURL string
	CoreGHSAURL    string
	PluginsGHSAURL string
	ForumRSSURL    string
}

// NewFetcher constructs a Fetcher pointing at production feeds.
func NewFetcher() *Fetcher {
	return &Fetcher{
		Client:         &http.Client{Timeout: defaultRequestTimeout},
		KEVURL:         DefaultKEVURL,
		KEVFallbackURL: DefaultKEVFallbackURL,
		CoreGHSAURL:    DefaultCoreGHSAURL,
		PluginsGHSAURL: DefaultPluginsGHSAURL,
		ForumRSSURL:    DefaultForumRSSURL,
	}
}

type rssDocument struct {
	Channel struct {
		Items []struct {
			Title       string `xml:"title"`
			Link        string `xml:"link"`
			Description string `xml:"description"`
			PubDate     string `xml:"pubDate"`
		} `xml:"item"`
	} `xml:"channel"`
}

// FetchAll fetches all configured feeds concurrently, isolating per-feed errors.
func (f *Fetcher) FetchAll(ctx context.Context, prevStatus map[string]model.FeedStatus, now time.Time) (*FeedBundle, map[string]model.FeedStatus) {
	if f.Client == nil {
		f.Client = &http.Client{Timeout: defaultRequestTimeout}
	}
	bundle := &FeedBundle{
		KEVByCVE: make(map[string]KEVEntry),
	}
	statuses := make(map[string]model.FeedStatus, 4)
	for k, v := range prevStatus {
		statuses[k] = v
	}

	var mu sync.Mutex
	var wg sync.WaitGroup

	runFeed := func(name, url string, fn func() (int, error)) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			st := statuses[name]
			st.Name = name
			st.URL = url
			st.LastAttempt = now
			count, err := fn()
			if err != nil {
				st.LastError = err.Error()
			} else {
				st.LastSuccess = now
				st.LastError = ""
				st.ItemCount = count
			}
			mu.Lock()
			statuses[name] = st
			mu.Unlock()
		}()
	}

	runFeed(FeedKEV, f.KEVURL, func() (int, error) {
		raw, err := f.get(ctx, f.KEVURL, "application/json")
		if err != nil && f.KEVFallbackURL != "" {
			if fbRaw, fbErr := f.get(ctx, f.KEVFallbackURL, "application/json"); fbErr == nil {
				raw, err = fbRaw, nil
			} else {
				err = fmt.Errorf("primary: %v; fallback: %v", err, fbErr)
			}
		}
		if err != nil {
			return 0, err
		}
		var cat KEVCatalog
		if err := json.Unmarshal(raw, &cat); err != nil {
			return 0, fmt.Errorf("decode KEV JSON: %w", err)
		}
		byCVE := make(map[string]KEVEntry, len(cat.Vulnerabilities))
		for _, entry := range cat.Vulnerabilities {
			key := strings.ToUpper(strings.TrimSpace(entry.CVEID))
			if key != "" {
				byCVE[key] = entry
			}
		}
		mu.Lock()
		bundle.KEVByCVE = byCVE
		bundle.KEVVersion = cat.CatalogVersion
		mu.Unlock()
		return len(byCVE), nil
	})

	runFeed(FeedCoreGHSA, f.CoreGHSAURL, func() (int, error) {
		items, err := f.fetchGHSAs(ctx, f.CoreGHSAURL)
		if err != nil {
			return 0, err
		}
		mu.Lock()
		bundle.CoreGHSAs = items
		mu.Unlock()
		return len(items), nil
	})

	runFeed(FeedPluginsGHSA, f.PluginsGHSAURL, func() (int, error) {
		items, err := f.fetchGHSAs(ctx, f.PluginsGHSAURL)
		if err != nil {
			return 0, err
		}
		mu.Lock()
		bundle.PluginGHSAs = items
		mu.Unlock()
		return len(items), nil
	})

	runFeed(FeedAnnouncements, f.ForumRSSURL, func() (int, error) {
		items, err := f.fetchForumRSS(ctx, f.ForumRSSURL)
		if err != nil {
			return 0, err
		}
		mu.Lock()
		bundle.Announcements = items
		mu.Unlock()
		return len(items), nil
	})

	wg.Wait()
	return bundle, statuses
}

func (f *Fetcher) fetchGHSAs(ctx context.Context, url string) ([]GHSAAdvisory, error) {
	raw, err := f.get(ctx, url, "application/vnd.github+json")
	if err != nil {
		return nil, err
	}
	var items []GHSAAdvisory
	if err := json.Unmarshal(raw, &items); err != nil {
		return nil, fmt.Errorf("decode GHSA JSON: %w", err)
	}
	return items, nil
}

func (f *Fetcher) fetchForumRSS(ctx context.Context, url string) ([]ForumItem, error) {
	raw, err := f.get(ctx, url, "application/rss+xml, application/xml, text/xml")
	if err != nil {
		return nil, err
	}
	var doc rssDocument
	if err := xml.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("decode forum RSS XML: %w", err)
	}
	out := make([]ForumItem, 0, len(doc.Channel.Items))
	for _, it := range doc.Channel.Items {
		title := strings.TrimSpace(it.Title)
		lower := strings.ToLower(title)
		ver := ""
		if m := verInTitleRe.FindStringSubmatch(title); len(m) == 2 {
			ver = m[1]
		}
		out = append(out, ForumItem{
			Title:       title,
			Link:        strings.TrimSpace(it.Link),
			Description: cleanRSSDescription(it.Description),
			PubDate:     strings.TrimSpace(it.PubDate),
			Version:     ver,
			Business:    strings.Contains(lower, "business"),
			IsReply:     strings.HasPrefix(lower, "re:"),
		})
	}
	return out, nil
}

func cleanRSSDescription(raw string) string {
	s := html.UnescapeString(raw)
	s = strings.ReplaceAll(s, "<br>", "\n")
	s = strings.ReplaceAll(s, "<br/>", "\n")
	s = strings.ReplaceAll(s, "<br />", "\n")
	s = htmlTagRe.ReplaceAllString(s, " ")
	lines := strings.Split(s, "\n")
	cleaned := make([]string, 0, len(lines))
	for _, ln := range lines {
		ln = strings.Join(strings.Fields(ln), " ")
		if ln != "" {
			cleaned = append(cleaned, ln)
		}
	}
	return strings.Join(cleaned, "\n")
}

func (f *Fetcher) get(ctx context.Context, url, accept string) ([]byte, error) {
	if strings.TrimSpace(url) == "" {
		return nil, fmt.Errorf("empty feed URL")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "faragao-netwatch/0.1")
	if accept != "" {
		req.Header.Set("Accept", accept)
	}
	resp, err := f.Client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("HTTP %d from %s", resp.StatusCode, url)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxFeedResponseBytes+1))
	if err != nil {
		return nil, err
	}
	if len(body) > maxFeedResponseBytes {
		return nil, fmt.Errorf("response exceeds %d bytes", maxFeedResponseBytes)
	}
	return body, nil
}
