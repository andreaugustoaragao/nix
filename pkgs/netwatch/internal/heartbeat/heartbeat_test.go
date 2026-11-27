package heartbeat

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestPingHealthyFailAndError(t *testing.T) {
	var paths []string
	var bodies []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		b, _ := io.ReadAll(r.Body)
		bodies = append(bodies, string(b))
		if r.URL.Path == "/uuid/broken" {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	if err := Ping(context.Background(), srv.Client(), srv.URL+"/uuid", false, "ok"); err != nil {
		t.Fatalf("healthy Ping() unexpected err: %v", err)
	}
	if err := Ping(context.Background(), srv.Client(), srv.URL+"/uuid/", true, "fault"); err != nil {
		t.Fatalf("fail Ping() unexpected err: %v", err)
	}
	if len(paths) != 2 || paths[0] != "/uuid" || paths[1] != "/uuid/fail" {
		t.Fatalf("unexpected paths: %v", paths)
	}
	if bodies[0] != "ok" || bodies[1] != "fault" {
		t.Fatalf("unexpected bodies: %v", bodies)
	}
	if err := Ping(context.Background(), srv.Client(), srv.URL+"/uuid/broken", false, ""); err == nil {
		t.Fatalf("expected error on 502 status")
	}
}
