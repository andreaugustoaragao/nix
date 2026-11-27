package server

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"faragao.net/netwatch/internal/model"
)

const maxIngestBytes = 4 << 20 // 4 MiB

// IngestHandler processes a validated OPNsense snapshot pushed from the firewall.
type IngestHandler func(ctx context.Context, snap *model.OPNsenseSnapshot) (findingsCount int, urgentSent int, err error)

// StatusProvider supplies safe, secret-free runtime health for /healthz.
type StatusProvider func() map[string]any

// NewMux constructs the HTTP handler for firewall snapshot ingestion and local health checks.
func NewMux(ingestToken string, onIngest IngestHandler, statusFn StatusProvider) http.Handler {
	mux := http.NewServeMux()
	expected := []byte(strings.TrimSpace(ingestToken))

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		payload := map[string]any{
			"ok":   true,
			"time": time.Now().UTC().Format(time.RFC3339),
		}
		if statusFn != nil {
			for k, v := range statusFn() {
				payload[k] = v
			}
		}
		writeJSON(w, http.StatusOK, payload)
	})

	mux.HandleFunc("/ingest/opnsense-audit", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if len(expected) == 0 || !validBearer(r.Header.Get("Authorization"), expected) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, maxIngestBytes)
		defer r.Body.Close()

		dec := json.NewDecoder(r.Body)
		var snap model.OPNsenseSnapshot
		if err := dec.Decode(&snap); err != nil {
			var maxErr *http.MaxBytesError
			if errors.As(err, &maxErr) {
				http.Error(w, "payload too large", http.StatusRequestEntityTooLarge)
				return
			}
			http.Error(w, fmt.Sprintf("invalid JSON: %v", err), http.StatusBadRequest)
			return
		}
		if strings.TrimSpace(snap.Host) == "" || strings.TrimSpace(snap.ProductVersion) == "" {
			http.Error(w, "missing required host or product_version", http.StatusBadRequest)
			return
		}
		if snap.CollectedAt.IsZero() {
			snap.CollectedAt = time.Now().UTC()
		}

		var findingsCount, urgentSent int
		if onIngest != nil {
			var err error
			findingsCount, urgentSent, err = onIngest(r.Context(), &snap)
			if err != nil {
				http.Error(w, "internal processing error", http.StatusInternalServerError)
				return
			}
		}

		writeJSON(w, http.StatusOK, map[string]any{
			"ok":             true,
			"host":           snap.Host,
			"version":        snap.ProductVersion,
			"findings_count": findingsCount,
			"urgent_sent":    urgentSent,
		})
	})

	return mux
}

func validBearer(header string, expected []byte) bool {
	const prefix = "Bearer "
	if !strings.HasPrefix(header, prefix) {
		return false
	}
	got := []byte(strings.TrimSpace(header[len(prefix):]))
	if len(got) != len(expected) {
		return false
	}
	return subtle.ConstantTimeCompare(got, expected) == 1
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
