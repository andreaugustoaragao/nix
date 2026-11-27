package heartbeat

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

const defaultTimeout = 10 * time.Second

// Ping notifies an external dead-man's-switch URL (e.g. Healthchecks.io).
// When fail is true, "/fail" is appended to pingURL.
func Ping(ctx context.Context, client *http.Client, pingURL string, fail bool, statusBody string) error {
	base := strings.TrimRight(strings.TrimSpace(pingURL), "/")
	if base == "" {
		return fmt.Errorf("heartbeat URL is empty")
	}
	target := base
	if fail {
		target += "/fail"
	}
	if client == nil {
		client = &http.Client{Timeout: defaultTimeout}
	}

	method := http.MethodGet
	var bodyReader io.Reader
	if strings.TrimSpace(statusBody) != "" {
		method = http.MethodPost
		bodyReader = bytes.NewBufferString(statusBody)
	}
	req, err := http.NewRequestWithContext(ctx, method, target, bodyReader)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "faragao-netwatch/0.1")
	if bodyReader != nil {
		req.Header.Set("Content-Type", "text/plain; charset=utf-8")
	}

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("heartbeat HTTP %d from %s", resp.StatusCode, target)
	}
	return nil
}
