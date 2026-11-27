package server

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"faragao.net/netwatch/internal/model"
)

func TestIngestAuthValidationAndHealthz(t *testing.T) {
	var seenHost string
	h := NewMux("secret-token-123", func(_ context.Context, snap *model.OPNsenseSnapshot) (int, int, error) {
		seenHost = snap.Host
		return 2, 0, nil
	}, func() map[string]any {
		return map[string]any{"service": "netwatch"}
	})

	// Unauthorized request
	req := httptest.NewRequest(http.MethodPost, "/ingest/opnsense-audit", strings.NewReader(`{}`))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 without token, got %d", rec.Code)
	}

	// Wrong token
	req = httptest.NewRequest(http.MethodPost, "/ingest/opnsense-audit", strings.NewReader(`{}`))
	req.Header.Set("Authorization", "Bearer wrong")
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 on wrong token, got %d", rec.Code)
	}

	// Missing required fields -> 400
	req = httptest.NewRequest(http.MethodPost, "/ingest/opnsense-audit", strings.NewReader(`{"host":""}`))
	req.Header.Set("Authorization", "Bearer secret-token-123")
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 on missing host/version, got %d", rec.Code)
	}

	// Valid payload -> 200
	valid := `{"host":"chief-tui-opn","product_version":"26.7.10","audit_ok":true}`
	req = httptest.NewRequest(http.MethodPost, "/ingest/opnsense-audit", bytes.NewBufferString(valid))
	req.Header.Set("Authorization", "Bearer secret-token-123")
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || seenHost != "chief-tui-opn" {
		t.Fatalf("expected 200 & seenHost=chief-tui-opn, got %d host=%q body=%s", rec.Code, seenHost, rec.Body.String())
	}

	// Healthz -> 200
	req = httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "netwatch") {
		t.Fatalf("expected 200 healthz, got %d body=%s", rec.Code, rec.Body.String())
	}

	// Oversized payload -> 413
	huge := `{"host":"chief-tui-opn","product_version":"26.7.10","audit_error":"` + strings.Repeat("a", maxIngestBytes+100) + `"}`
	req = httptest.NewRequest(http.MethodPost, "/ingest/opnsense-audit", strings.NewReader(huge))
	req.Header.Set("Authorization", "Bearer secret-token-123")
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413 on oversized body, got %d", rec.Code)
	}
}

func TestAdminRoutesLoopbackAndBearerEnforcement(t *testing.T) {
	var ackedID string
	h := NewMuxWithAdmin("admin-tok", nil, nil, &AdminHandlers{
		Status: func(_ context.Context) (any, error) {
			return map[string]any{"ok": true, "count": 2}, nil
		},
		Ack: func(_ context.Context, id, note string) error {
			ackedID = id + ":" + note
			return nil
		},
		Resolve: func(_ context.Context, id string) (any, error) {
			return map[string]any{"id": id, "status": "resolved"}, nil
		},
		AcceptBaseline: func(_ context.Context) error {
			return nil
		},
		Maintenance: func(_ context.Context, minutes int, note string) (any, error) {
			return map[string]any{"minutes": minutes, "note": note}, nil
		},
		CleanupSynthetic: func(_ context.Context) (int, error) {
			return 3, nil
		},
	})

	// Non-loopback client with valid token must be rejected with 403 Forbidden.
	req := httptest.NewRequest(http.MethodGet, "/admin/status", nil)
	req.RemoteAddr = "192.168.100.2:55555"
	req.Header.Set("Authorization", "Bearer admin-tok")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for non-loopback /admin/status, got %d", rec.Code)
	}

	// Loopback client without valid token -> 401
	req = httptest.NewRequest(http.MethodGet, "/admin/status", nil)
	req.RemoteAddr = "127.0.0.1:41234"
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for unauth loopback /admin/status, got %d", rec.Code)
	}

	// Loopback + valid token succeeds across admin routes
	for _, tc := range []struct {
		method string
		path   string
		body   string
	}{
		{http.MethodGet, "/admin/status", ""},
		{http.MethodPost, "/admin/ack", `{"id":"sec:1","note":"ok"}`},
		{http.MethodPost, "/admin/resolve", `{"id":"sec:1"}`},
		{http.MethodPost, "/admin/accept-baseline", ""},
		{http.MethodPost, "/admin/maintenance", `{"minutes":30,"note":"patch"}`},
		{http.MethodPost, "/admin/cleanup-synthetic", ""},
	} {
		req = httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body))
		req.RemoteAddr = "127.0.0.1:41234"
		req.Header.Set("Authorization", "Bearer admin-tok")
		rec = httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("%s %s returned %d: %s", tc.method, tc.path, rec.Code, rec.Body.String())
		}
	}
	if ackedID != "sec:1:ok" {
		t.Fatalf("expected ack handler invoked, got %q", ackedID)
	}
}

func TestMetricsEndpoint(t *testing.T) {
	h := NewMuxWithMetrics("tok", nil, nil, func() string {
		return "# TYPE netwatch_up gauge\nnetwatch_up 1\nnetwatch_opnsense_webgui_cert_expiry_seconds 1803528612\n"
	}, nil)

	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 for GET /metrics, got %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/plain") {
		t.Fatalf("expected text/plain Content-Type, got %q", ct)
	}
	if !strings.Contains(rec.Body.String(), "netwatch_up 1") || !strings.Contains(rec.Body.String(), "1803528612") {
		t.Fatalf("unexpected metrics body: %s", rec.Body.String())
	}

	req = httptest.NewRequest(http.MethodPost, "/metrics", nil)
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405 for POST /metrics, got %d", rec.Code)
	}
}
