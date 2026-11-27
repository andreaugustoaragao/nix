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
