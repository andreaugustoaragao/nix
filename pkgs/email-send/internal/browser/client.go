package browser

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Client wraps the host `browser-task` CLI with typed actions and guaranteed cleanup.
type Client struct {
	Binary         string
	Profile        string
	TaskID         string
	MainTargetID   string
	DefaultTimeout int
}

type startResult struct {
	Task   string            `json:"task"`
	TaskID string            `json:"task_id"`
	ID     string            `json:"id"`
	Pages  map[string]string `json:"pages"`
}

type actionEnvelope struct {
	Value json.RawMessage `json:"value"`
	Error string          `json:"error,omitempty"`
}

func NewClient(profile string, defaultTimeoutS int) *Client {
	if profile == "" {
		profile = "accounts"
	}
	if defaultTimeoutS <= 0 || defaultTimeoutS > 300 {
		defaultTimeoutS = 45
	}
	return &Client{
		Binary:         "browser-task",
		Profile:        profile,
		DefaultTimeout: defaultTimeoutS,
	}
}

func (c *Client) runCmd(ctx context.Context, stdin []byte, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, c.Binary, args...)
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return stdout.Bytes(), fmt.Errorf("browser-task %s failed: %w (stderr: %s, stdout: %s)",
			strings.Join(args, " "), err, strings.TrimSpace(stderr.String()), truncate(stdout.String(), 400))
	}
	return stdout.Bytes(), nil
}

// Start opens a managed browser task in the configured profile and records its task and main page target IDs.
func (c *Client) Start(ctx context.Context, label, initialURL string) (string, string, error) {
	args := []string{"start", c.Profile, "--label", label}
	if initialURL != "" {
		args = append(args, "--url", initialURL)
	}
	out, err := c.runCmd(ctx, nil, args...)
	if err != nil {
		return "", "", err
	}
	var res startResult
	if err := json.Unmarshal(extractJSON(out), &res); err != nil {
		return "", "", fmt.Errorf("parse browser-task start output: %w (raw: %s)", err, truncate(string(out), 300))
	}
	id := firstNonEmpty(res.Task, res.TaskID, res.ID)
	if id == "" {
		return "", "", fmt.Errorf("browser-task start returned no task id (raw: %s)", truncate(string(out), 300))
	}
	c.TaskID = id
	c.MainTargetID = res.Pages["main"]
	return c.TaskID, c.MainTargetID, nil
}

// Finish closes the browser task cleanly using an independent timeout so cleanup runs even after SIGINT.
func (c *Client) Finish() error {
	if c.TaskID == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	_, err := c.runCmd(ctx, nil, "finish", c.TaskID)
	c.TaskID = ""
	return err
}

// Action sends a typed JSON action to `browser-task action`.
func (c *Client) Action(ctx context.Context, pageName string, timeoutS int, payload map[string]any) ([]byte, error) {
	if timeoutS <= 0 || timeoutS > 300 {
		timeoutS = c.DefaultTimeout
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	args := []string{"action", c.TaskID, "--page", pageName, "--timeout", strconv.Itoa(timeoutS)}
	return c.runCmd(ctx, body, args...)
}

func (c *Client) Navigate(ctx context.Context, pageName, targetURL string) error {
	_, err := c.Action(ctx, pageName, c.DefaultTimeout, map[string]any{
		"type": "navigate",
		"url":  targetURL,
	})
	return err
}

func (c *Client) Viewport(ctx context.Context, pageName string, width, height int) error {
	_, err := c.Action(ctx, pageName, c.DefaultTimeout, map[string]any{
		"type":   "viewport",
		"width":  width,
		"height": height,
	})
	return err
}

func (c *Client) ClickRole(ctx context.Context, pageName, role, name string) error {
	_, err := c.Action(ctx, pageName, c.DefaultTimeout, map[string]any{
		"type": "click",
		"target": map[string]any{
			"role":  role,
			"name":  name,
			"exact": true,
		},
	})
	return err
}

func (c *Client) FillRole(ctx context.Context, pageName, role, name, text string) error {
	_, err := c.Action(ctx, pageName, c.DefaultTimeout, map[string]any{
		"type": "fill",
		"target": map[string]any{
			"role":  role,
			"name":  name,
			"exact": true,
		},
		"text": text,
	})
	return err
}

func (c *Client) Key(ctx context.Context, pageName, key string) error {
	_, err := c.Action(ctx, pageName, c.DefaultTimeout, map[string]any{
		"type": "key",
		"key":  key,
	})
	return err
}

// Evaluate runs a JS expression in the page and unmarshals `.value` into out.
func (c *Client) Evaluate(ctx context.Context, pageName, expression string, out any) error {
	raw, err := c.Action(ctx, pageName, c.DefaultTimeout, map[string]any{
		"type":       "evaluate",
		"expression": expression,
	})
	if err != nil {
		return err
	}
	trimmed := extractJSON(raw)
	var env actionEnvelope
	if err := json.Unmarshal(trimmed, &env); err == nil && len(env.Value) > 0 {
		if env.Error != "" {
			return fmt.Errorf("page evaluate error: %s", env.Error)
		}
		if out == nil {
			return nil
		}
		if err := json.Unmarshal(env.Value, out); err != nil {
			return fmt.Errorf("unmarshal evaluate value: %w (value: %s)", err, truncate(string(env.Value), 300))
		}
		return nil
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(trimmed, out); err != nil {
		return fmt.Errorf("unmarshal raw action output: %w (raw: %s)", err, truncate(string(trimmed), 300))
	}
	return nil
}

// WaitForCondition polls boolExpr until it returns true or timeout elapses.
func (c *Client) WaitForCondition(ctx context.Context, pageName, boolExpr string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		var ok bool
		err := c.Evaluate(ctx, pageName, boolExpr, &ok)
		if err == nil && ok {
			return nil
		}
		if time.Now().After(deadline) {
			if err != nil {
				return fmt.Errorf("wait condition timed out (last err: %w)", err)
			}
			return fmt.Errorf("wait condition timed out after %s", timeout)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(400 * time.Millisecond):
		}
	}
}

var configFlagRe = regexp.MustCompile(`--config\s+([^\s'"]+)`)

// DiscoverCDPPort inspects the browser-task wrapper script's --config JSON to find the CDP port for profile.
func (c *Client) DiscoverCDPPort() (int, error) {
	binPath, err := exec.LookPath(c.Binary)
	if err != nil {
		return 0, fmt.Errorf("locate %s: %w", c.Binary, err)
	}
	wrapperBytes, err := os.ReadFile(binPath)
	if err != nil {
		return 0, fmt.Errorf("read %s: %w", binPath, err)
	}
	m := configFlagRe.FindSubmatch(wrapperBytes)
	if m == nil {
		return 0, fmt.Errorf("no --config flag found in %s", binPath)
	}
	cfgBytes, err := os.ReadFile(string(m[1]))
	if err != nil {
		return 0, fmt.Errorf("read browser-task config %s: %w", string(m[1]), err)
	}
	var profiles map[string]struct {
		Port int `json:"port"`
	}
	if err := json.Unmarshal(cfgBytes, &profiles); err != nil {
		return 0, fmt.Errorf("parse browser-task config %s: %w", string(m[1]), err)
	}
	p, ok := profiles[c.Profile]
	if !ok || p.Port <= 0 {
		return 0, fmt.Errorf("profile %q not found or missing port in %s", c.Profile, string(m[1]))
	}
	return p.Port, nil
}

func extractJSON(b []byte) []byte {
	s := bytes.TrimSpace(b)
	if len(s) == 0 || s[0] == '{' || s[0] == '[' {
		return s
	}
	if idx := bytes.IndexByte(s, '{'); idx >= 0 {
		return s[idx:]
	}
	return s
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func truncate(s string, max int) string {
	s = strings.TrimSpace(s)
	if len(s) <= max {
		return s
	}
	return s[:max] + "..."
}
