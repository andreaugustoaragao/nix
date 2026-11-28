package feeds

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"faragao.net/netwatch/internal/model"
)

func TestFetcherIsolatesFailuresAndParsesAllFeeds(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/kev", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"catalogVersion": "2026.11.27",
			"count": 1,
			"vulnerabilities": [{
				"cveID": "cve-2026-124851",
				"vendorProject": "Meta",
				"product": "zstd",
				"vulnerabilityName": "Zstd vuln",
				"dateAdded": "2026-11-26",
				"shortDescription": "desc",
				"requiredAction": "patch",
				"dueDate": "2026-12-01"
			}]
		}`))
	})
	mux.HandleFunc("/core", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	})
	mux.HandleFunc("/plugins", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`[{
			"ghsa_id": "GHSA-test-0001-0002",
			"severity": "high",
			"summary": "Plugin issue",
			"html_url": "https://github.com/opnsense/plugins/security/advisories/GHSA-test-0001-0002",
			"vulnerabilities": [{"package": {"name": "os-ddclient"}, "vulnerable_version_range": "<= 1.34", "patched_versions": "1.35"}]
		}]`))
	})
	mux.HandleFunc("/rss", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/xml")
		_, _ = w.Write([]byte(`<?xml version="1.0" encoding="UTF-8"?>
<rss version="0.92"><channel>
<item>
  <title>OPNsense 26.7.11 released</title>
  <link>https://forum.opnsense.org/index.php?topic=99999.0</link>
  <description><![CDATA[Includes FreeBSD-SA-26:95 security advisory.<br>o firewall: fix]]></description>
  <pubDate>Fri, 27 Nov 2026 10:00:00 GMT</pubDate>
</item>
<item>
  <title>Re: OPNsense 26.10 business edition released</title>
  <link>https://forum.opnsense.org/index.php?topic=53238.msg277724</link>
  <description>patch notes</description>
</item>
</channel></rss>`))
	})
	mux.HandleFunc("/rev-2605", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("5b31ff946309736077f0c4ee23bb85d0a0a1c181\n"))
	})
	mux.HandleFunc("/rev-2611", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("3068c73a96a6979ee8e72e7196577d0bd842d412\n"))
	})

	srv := httptest.NewServer(mux)
	defer srv.Close()

	prevSuccess := time.Date(2026, 11, 26, 8, 0, 0, 0, time.UTC)
	prev := map[string]model.FeedStatus{
		FeedCoreGHSA: {
			Name:        FeedCoreGHSA,
			LastSuccess: prevSuccess,
		},
	}

	now := time.Date(2026, 11, 27, 8, 0, 0, 0, time.UTC)
	fetcher := &Fetcher{
		Client:          srv.Client(),
		KEVURL:          srv.URL + "/kev",
		CoreGHSAURL:     srv.URL + "/core",
		PluginsGHSAURL:  srv.URL + "/plugins",
		ForumRSSURL:     srv.URL + "/rss",
		NixOS2605RevURL: srv.URL + "/rev-2605",
		NixOS2611RevURL: srv.URL + "/rev-2611",
	}

	bundle, statuses := fetcher.FetchAll(context.Background(), prev, now)

	if len(bundle.KEVByCVE) != 1 {
		t.Fatalf("expected 1 KEV entry, got %d", len(bundle.KEVByCVE))
	}
	if _, ok := bundle.KEVByCVE["CVE-2026-124851"]; !ok {
		t.Fatalf("expected normalized uppercase CVE key in KEVByCVE")
	}
	if len(bundle.PluginGHSAs) != 1 {
		t.Fatalf("expected 1 plugin GHSA, got %d", len(bundle.PluginGHSAs))
	}
	if len(bundle.Announcements) != 2 {
		t.Fatalf("expected 2 forum items, got %d", len(bundle.Announcements))
	}
	if bundle.NixOSChannelRevs["nixos-26.05"] != "5b31ff946309736077f0c4ee23bb85d0a0a1c181" ||
		bundle.NixOSChannelRevs["nixos-26.11"] != "3068c73a96a6979ee8e72e7196577d0bd842d412" {
		t.Fatalf("unexpected NixOSChannelRevs: %+v", bundle.NixOSChannelRevs)
	}
	if statuses[FeedNixOS2611].ItemCount != 1 || statuses[FeedNixOS2611].LastError != "" {
		t.Fatalf("unexpected NixOS 26.11 status: %+v", statuses[FeedNixOS2611])
	}
	if bundle.Announcements[0].Version != "26.7.11" || bundle.Announcements[0].Business || bundle.Announcements[0].IsReply {
		t.Fatalf("unexpected announcement[0]: %+v", bundle.Announcements[0])
	}
	if !bundle.Announcements[1].Business || !bundle.Announcements[1].IsReply || bundle.Announcements[1].Version != "26.10" {
		t.Fatalf("unexpected announcement[1]: %+v", bundle.Announcements[1])
	}

	coreSt := statuses[FeedCoreGHSA]
	if coreSt.LastError == "" {
		t.Fatalf("expected error on failed core GHSA feed")
	}
	if !coreSt.LastSuccess.Equal(prevSuccess) {
		t.Fatalf("expected failed feed to preserve prev LastSuccess %v, got %v", prevSuccess, coreSt.LastSuccess)
	}
	if statuses[FeedKEV].LastError != "" || !statuses[FeedKEV].LastSuccess.Equal(now) {
		t.Fatalf("expected KEV feed success at %v, got %+v", now, statuses[FeedKEV])
	}
}
