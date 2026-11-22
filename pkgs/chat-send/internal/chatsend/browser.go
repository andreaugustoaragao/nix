package chatsend

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os/exec"
	"time"
)

// BrowserRunner abstracts browser-task invocation for deterministic unit testing.
type BrowserRunner interface {
	Run(args []string, input []byte, timeout time.Duration) (stdout []byte, err error)
}

type ExecBrowserRunner struct {
	Binary string
}

func (r ExecBrowserRunner) Run(args []string, input []byte, timeout time.Duration) ([]byte, error) {
	bin := r.Binary
	if bin == "" {
		bin = "browser-task"
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, args...)
	if input != nil {
		cmd.Stdin = bytes.NewReader(input)
	}
	var outBuf bytes.Buffer
	var errBuf bytes.Buffer
	cmd.Stdout = &limitedWriter{w: &outBuf, limit: MaxBrowserOutputBytes + 1}
	cmd.Stderr = &limitedWriter{w: &errBuf, limit: 16384}
	err := cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		return nil, Stop("browser_timeout")
	}
	if err != nil {
		return nil, Stop("browser_command_failed")
	}
	if outBuf.Len() > MaxBrowserOutputBytes {
		return nil, Stop("browser_output_oversized")
	}
	return outBuf.Bytes(), nil
}

type limitedWriter struct {
	w     *bytes.Buffer
	limit int
}

func (l *limitedWriter) Write(p []byte) (int, error) {
	rem := l.limit - l.w.Len()
	if rem > 0 {
		if len(p) > rem {
			_, _ = l.w.Write(p[:rem])
		} else {
			_, _ = l.w.Write(p)
		}
	}
	return len(p), nil
}

type Browser struct {
	Record  map[string]any
	Persist func() error
	Runner  BrowserRunner
	ProbeJS string
}

func (b *Browser) Call(args []string, action map[string]any, phase string) (map[string]any, error) {
	label := ""
	if action != nil {
		label, _ = asString(action["type"])
	} else if len(args) > 0 {
		label = args[0]
	}
	start := time.Now()

	var input []byte
	var err error
	if action != nil {
		input, err = Encode(action)
		if err != nil {
			return nil, Stop("browser_unavailable_or_invalid_output")
		}
	}

	runner := b.Runner
	if runner == nil {
		runner = ExecBrowserRunner{}
	}

	var result map[string]any
	var callErr error
	defer func() {
		ms := time.Since(start).Milliseconds()
		entry := map[string]any{"action": label, "ms": ms}
		if phase != "" {
			entry["phase"] = phase
			if action != nil {
				entry["key"] = action["key"]
			}
		}
		var timings []any
		if existing, ok := asSlice(b.Record["actions"]); ok {
			timings = existing
		}
		timings = append(timings, entry)
		if len(timings) > 200 {
			timings = timings[len(timings)-200:]
		}
		b.Record["actions"] = timings
		prevCount, _ := asInt64(b.Record["action_count"])
		prevMs, _ := asInt64(b.Record["action_ms"])
		b.Record["action_count"] = prevCount + 1
		b.Record["action_ms"] = prevMs + ms
		_ = b.Persist()
	}()

	raw, runErr := runner.Run(args, input, 40*time.Second)
	if runErr != nil {
		var se *StopError
		if errors.As(runErr, &se) {
			callErr = se
			return nil, callErr
		}
		callErr = Stop("browser_unavailable_or_invalid_output")
		return nil, callErr
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&result); err != nil || result == nil {
		return nil, Stop("browser_output_invalid")
	}
	var extra any
	if err := dec.Decode(&extra); err != io.EOF {
		return nil, Stop("browser_output_invalid")
	}
	return result, nil
}

func (b *Browser) Action(kind string, phase string, fields map[string]any) (map[string]any, error) {
	taskID, _ := asString(b.Record["task"])
	payload := make(map[string]any, len(fields)+1)
	for k, v := range fields {
		payload[k] = v
	}
	payload["type"] = kind
	return b.Call([]string{"action", taskID, "--page", "main", "--timeout", "30"}, payload, phase)
}

func (b *Browser) Ownership(resume bool) error {
	taskID, _ := asString(b.Record["task"])
	info, err := b.Call([]string{"info", taskID}, nil, "")
	if err != nil {
		return err
	}
	if info["task"] != b.Record["task"] || info["profile"] != "accounts" || info["label"] != b.Record["label"] || !jsonEqual(info["pages"], b.Record["pages"]) {
		return Stop("task_ownership_changed")
	}
	state, _ := asString(info["state"])
	if state == "kept" && resume {
		if _, err := b.Call([]string{"resume", taskID}, nil, ""); err != nil {
			return err
		}
	} else if state != "active" {
		return Stop("task_not_active")
	}
	return nil
}

func (b *Browser) Probe() (map[string]any, error) {
	script := b.ProbeJS
	if script == "" {
		script = DefaultProbeScript
	}
	res, err := b.Action("evaluate", "", map[string]any{"expression": script})
	if err != nil {
		return nil, err
	}
	val, ok := asMap(res["value"])
	if !ok {
		return nil, Stop("unsupported_or_truncated_dom")
	}
	ver, vok := asInt64(val["version"])
	trunc, _ := asBool(val["truncated"])
	if !vok || ver != 1 || trunc {
		return nil, Stop("unsupported_or_truncated_dom")
	}
	return val, nil
}
