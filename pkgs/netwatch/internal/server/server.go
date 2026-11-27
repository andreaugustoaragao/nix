package server

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"net"
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

// AdminHandlers exposes loopback-only state operations so CLI tools avoid racy file writes while serve runs.
type AdminHandlers struct {
	Status           func(ctx context.Context) (any, error)
	Ack              func(ctx context.Context, id, note string) error
	Resolve          func(ctx context.Context, id string) (any, error)
	AcceptBaseline   func(ctx context.Context) error
	Maintenance      func(ctx context.Context, minutes int, note string) (any, error)
	CleanupSynthetic func(ctx context.Context) (int, error)
}

// NewMux constructs the HTTP handler for firewall snapshot ingestion and local health checks.
func NewMux(ingestToken string, onIngest IngestHandler, statusFn StatusProvider) http.Handler {
	return NewMuxWithAdmin(ingestToken, onIngest, statusFn, nil)
}

// NewMuxWithAdmin constructs the HTTP handler plus optional loopback-restricted /admin endpoints.
func NewMuxWithAdmin(ingestToken string, onIngest IngestHandler, statusFn StatusProvider, admin *AdminHandlers) http.Handler {
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

	if admin != nil {
		mountAdminRoutes(mux, expected, admin)
	}

	return mux
}

func mountAdminRoutes(mux *http.ServeMux, expected []byte, admin *AdminHandlers) {
	wrap := func(method string, h http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			if r.Method != method {
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			if !isLoopbackRemote(r.RemoteAddr) {
				http.Error(w, "forbidden: loopback only", http.StatusForbidden)
				return
			}
			if len(expected) == 0 || !validBearer(r.Header.Get("Authorization"), expected) {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
			h(w, r)
		}
	}

	mux.HandleFunc("/admin/status", wrap(http.MethodGet, func(w http.ResponseWriter, r *http.Request) {
		if admin.Status == nil {
			http.Error(w, "not implemented", http.StatusNotImplemented)
			return
		}
		res, err := admin.Status(r.Context())
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusOK, res)
	}))

	mux.HandleFunc("/admin/ack", wrap(http.MethodPost, func(w http.ResponseWriter, r *http.Request) {
		if admin.Ack == nil {
			http.Error(w, "not implemented", http.StatusNotImplemented)
			return
		}
		var req struct {
			ID   string `json:"id"`
			Note string `json:"note"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req); err != nil {
			http.Error(w, fmt.Sprintf("invalid JSON: %v", err), http.StatusBadRequest)
			return
		}
		if strings.TrimSpace(req.ID) == "" {
			http.Error(w, "id is required", http.StatusBadRequest)
			return
		}
		if err := admin.Ack(r.Context(), strings.TrimSpace(req.ID), req.Note); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "id": req.ID})
	}))

	mux.HandleFunc("/admin/resolve", wrap(http.MethodPost, func(w http.ResponseWriter, r *http.Request) {
		if admin.Resolve == nil {
			http.Error(w, "not implemented", http.StatusNotImplemented)
			return
		}
		var req struct {
			ID string `json:"id"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req); err != nil {
			http.Error(w, fmt.Sprintf("invalid JSON: %v", err), http.StatusBadRequest)
			return
		}
		if strings.TrimSpace(req.ID) == "" {
			http.Error(w, "id is required", http.StatusBadRequest)
			return
		}
		res, err := admin.Resolve(r.Context(), strings.TrimSpace(req.ID))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "finding": res})
	}))

	mux.HandleFunc("/admin/accept-baseline", wrap(http.MethodPost, func(w http.ResponseWriter, r *http.Request) {
		if admin.AcceptBaseline == nil {
			http.Error(w, "not implemented", http.StatusNotImplemented)
			return
		}
		if err := admin.AcceptBaseline(r.Context()); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	}))

	mux.HandleFunc("/admin/maintenance", wrap(http.MethodPost, func(w http.ResponseWriter, r *http.Request) {
		if admin.Maintenance == nil {
			http.Error(w, "not implemented", http.StatusNotImplemented)
			return
		}
		var req struct {
			Minutes int    `json:"minutes"`
			Note    string `json:"note"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req); err != nil {
			http.Error(w, fmt.Sprintf("invalid JSON: %v", err), http.StatusBadRequest)
			return
		}
		res, err := admin.Maintenance(r.Context(), req.Minutes, req.Note)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		writeJSON(w, http.StatusOK, res)
	}))

	mux.HandleFunc("/admin/cleanup-synthetic", wrap(http.MethodPost, func(w http.ResponseWriter, r *http.Request) {
		if admin.CleanupSynthetic == nil {
			http.Error(w, "not implemented", http.StatusNotImplemented)
			return
		}
		n, err := admin.CleanupSynthetic(r.Context())
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "removed": n})
	}))
}

func isLoopbackRemote(remoteAddr string) bool {
	host := strings.TrimSpace(remoteAddr)
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	host = strings.Trim(host, "[]")
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
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
