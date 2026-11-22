package main

import (
	"bufio"
	"bytes"
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"chat-send/internal/chatsend"
)

const (
	modelName    = "gpt-6.1-terra"
	providerName = "litellm"
)

//go:embed worker-system.txt
var systemPrompt string

var workerSettings = map[string]any{
	"retry": map[string]any{
		"enabled":     true,
		"maxRetries":  1,
		"baseDelayMs": 500,
		"provider": map[string]any{
			"maxRetries": 0,
			"timeoutMs":  45000,
		},
	},
	"compaction":   map[string]any{"enabled": false},
	"quietStartup": true,
}

type taskOptions struct {
	Mode         string // "", "status", "cancel"
	Route        string
	Brief        string
	Operation    string
	Send         bool
	MentionEmail string
	MentionQuery string
	Portfolio    string
	TaskID       string
	RoutesFile   string
	StateDir     string
}

func defaultPath(envVar, fallbackRel, suffix string) string {
	base := os.Getenv(envVar)
	if base == "" {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, fallbackRel)
	}
	return filepath.Join(base, suffix)
}

func expandHome(p string) string {
	if strings.HasPrefix(p, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, p[2:])
		}
	}
	return p
}

func runJSONCommand(args []string, timeout time.Duration, diagnostics string) (map[string]any, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	var outBuf, errBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf
	err := cmd.Run()
	exitCode := 0
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			exitCode = ee.ExitCode()
		} else {
			exitCode = 1
		}
	}
	if err != nil || outBuf.Len() > chatsend.MaxJSONBytes {
		if diagnostics != "" {
			outTail := outBuf.String()
			if len(outTail) > 16384 {
				outTail = outTail[len(outTail)-16384:]
			}
			errTail := errBuf.String()
			if len(errTail) > 16384 {
				errTail = errTail[len(errTail)-16384:]
			}
			_ = chatsend.AtomicWriteJSON(diagnostics, map[string]any{
				"argv":   args,
				"exit":   exitCode,
				"stdout": outTail,
				"stderr": errTail,
			})
		}
		return nil, chatsend.Stop("worker_command_failed")
	}
	dec := json.NewDecoder(bytes.NewReader(outBuf.Bytes()))
	dec.UseNumber()
	var val map[string]any
	if derr := dec.Decode(&val); derr != nil || val == nil {
		return nil, chatsend.Stop("worker_command_invalid_response")
	}
	return val, nil
}

func resolveSender() (string, error) {
	bin := os.Getenv("CHAT_SEND_BIN")
	if bin == "" {
		var err error
		bin, err = exec.LookPath("chat-send")
		if err != nil {
			return "", chatsend.Stop("chat_send_unavailable")
		}
	}
	info, err := os.Stat(bin)
	if err != nil || !info.Mode().IsRegular() {
		return "", chatsend.Stop("chat_send_unavailable")
	}
	resolved, err := filepath.EvalSymlinks(bin)
	if err != nil {
		return bin, nil
	}
	return resolved, nil
}

func resolveWorkerExtension() (string, error) {
	if ext := os.Getenv("CHAT_SEND_WORKER_EXTENSION"); ext != "" {
		if info, err := os.Stat(ext); err == nil && info.Mode().IsRegular() {
			return ext, nil
		}
	}
	home, _ := os.UserHomeDir()
	fallback := filepath.Join(home, ".agents/skills/chat-send/scripts/worker.ts")
	if info, err := os.Stat(fallback); err == nil && info.Mode().IsRegular() {
		return fallback, nil
	}
	return "", chatsend.Stop("worker_extension_unavailable")
}

func accounting(directory string) map[string]any {
	type key struct {
		req string
		id  string
	}
	records := make(map[key]map[string]any)
	order := make([]key, 0)
	telePath := filepath.Join(directory, "telemetry.jsonl")
	if f, err := os.Open(telePath); err == nil {
		scanner := bufio.NewScanner(f)
		scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for scanner.Scan() {
			var ev map[string]any
			dec := json.NewDecoder(strings.NewReader(scanner.Text()))
			dec.UseNumber()
			if dec.Decode(&ev) != nil {
				continue
			}
			if ev["event"] != "wire_usage" {
				continue
			}
			data, ok := ev["data"].(map[string]any)
			if !ok {
				continue
			}
			reqVal, exists := data["request"]
			if !exists {
				continue
			}
			k := key{req: fmt.Sprint(reqVal), id: fmt.Sprint(data["id"])}
			if _, seen := records[k]; !seen {
				order = append(order, k)
			}
			records[k] = data
		}
		_ = f.Close()
	}

	var done map[string]any
	if d, err := chatsend.ReadJSON(filepath.Join(directory, "done.json"), true); err == nil {
		done = d
	} else {
		done = map[string]any{}
	}

	reqSet := make(map[string]struct{})
	responses := make([]any, 0, len(order))
	var costSum float64
	known := len(order) > 0
	for _, k := range order {
		r := records[k]
		responses = append(responses, r)
		reqSet[k.req] = struct{}{}
		usage, uok := r["usage"].(map[string]any)
		if !uok {
			known = false
			continue
		}
		c, cok := toFloat(usage["cost"])
		if !cok || math.IsNaN(c) || math.IsInf(c, 0) || c < 0 {
			known = false
			continue
		}
		costSum += c
	}

	doneReqs, hasDoneReqs := toInt64(done["requests"])
	complete := hasDoneReqs && int64(len(reqSet)) == doneReqs
	known = known && complete

	var gatewayCost any
	costSource := "unknown"
	if known {
		gatewayCost = costSum
		costSource = "gateway usage.cost"
	}
	return map[string]any{
		"requests":       done["requests"],
		"responses":      responses,
		"usage_complete": complete,
		"gateway_cost":   gatewayCost,
		"cost_source":    costSource,
	}
}

func toFloat(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case int:
		return float64(n), true
	case int64:
		return float64(n), true
	case json.Number:
		f, err := n.Float64()
		return f, err == nil
	default:
		return 0, false
	}
}

func toInt64(v any) (int64, bool) {
	switch n := v.(type) {
	case int:
		return int64(n), true
	case int64:
		return n, true
	case json.Number:
		i, err := n.Int64()
		return i, err == nil
	case float64:
		if float64(int64(n)) == n {
			return int64(n), true
		}
		return 0, false
	default:
		return 0, false
	}
}

func resultFor(root, operation, directory string, native map[string]any) (map[string]any, error) {
	receiptPath := filepath.Join(root, operation, "receipt.json")
	jobPath := filepath.Join(directory, "job.json")
	donePath := filepath.Join(directory, "done.json")
	payloadPath := filepath.Join(directory, "payload.json")

	var value map[string]any
	_, receiptErr := os.Stat(receiptPath)
	if receiptErr == nil {
		record, err := chatsend.ReadReceiptJSON(receiptPath)
		if err != nil {
			return nil, err
		}
		if _, jerr := os.Stat(jobPath); jerr == nil {
			manifest, merr := chatsend.ReadJSON(jobPath, true)
			if merr != nil {
				return nil, merr
			}
			payload, _, _, _, perr := chatsend.PayloadParts(payloadPath, nil)
			if perr != nil {
				return nil, perr
			}
			recReq, _ := record["request"].(map[string]any)
			manReq, _ := manifest["request"].(map[string]any)
			rEnc, _ := chatsend.Encode(recReq["route"])
			mEnc, _ := chatsend.Encode(manReq["route"])
			pRecEnc, _ := chatsend.Encode(recReq["payload"])
			pExpEnc, _ := chatsend.Encode(payload)
			if record["operation_id"] != operation || !bytes.Equal(rEnc, mEnc) || !bytes.Equal(pRecEnc, pExpEnc) {
				return nil, chatsend.Stop("worker_receipt_binding_mismatch", "uncertain")
			}
		}
		outcome, _ := record["outcome"].(string)
		if outcome == "" {
			outcome = "failed"
		}
		reason, _ := record["reason"].(string)
		if reason == "" {
			reason = "unknown"
		}
		sa, _ := record["send_attempted"].(bool)
		value = map[string]any{
			"outcome":        outcome,
			"reason":         reason,
			"operation_id":   operation,
			"receipt":        receiptPath,
			"send_attempted": sa,
		}
		if native != nil {
			for _, k := range []string{"outcome", "reason", "send_attempted"} {
				if v, ok := native[k]; ok {
					value[k] = v
				}
			}
		}
	} else {
		value = map[string]any{
			"outcome":      "needs_attention",
			"reason":       "worker_has_no_sender_receipt_inspect_original_job",
			"operation_id": operation,
			"receipt":      jobPath,
		}
	}

	if receiptErr != nil {
		if done, derr := chatsend.ReadJSON(donePath, true); derr == nil {
			if stopped, ok := done["result"].(map[string]any); ok {
				detail, dok := stopped["detail"].(string)
				if stopped["operation_id"] == operation && stopped["reason"] == "brief_needs_clarification" && dok && len(detail) > 0 && len(detail) <= 400 {
					value["outcome"] = "needs_attention"
					value["reason"] = "brief_needs_clarification"
					value["detail"] = detail
					value["send_attempted"] = false
				}
			}
		}
	}

	value["worker_job"] = directory
	value["payload"] = payloadPath
	value["provider"] = providerName
	value["model"] = modelName
	value["thinking"] = "low"
	value["accounting"] = accounting(directory)
	if manifest, err := chatsend.ReadJSON(jobPath, true); err == nil {
		value["route"] = manifest["alias"]
		value["routes_file"] = manifest["routes_file"]
		value["state_dir"] = root
	}
	return value, nil
}

func waitFile(path, terminal, marker string, deadline time.Time) error {
	for {
		if _, err := os.Stat(path); err == nil {
			return nil
		}
		if !time.Now().Before(deadline) {
			return chatsend.Stop("worker_deadline_check_original_operation", "uncertain")
		}
		obs, err := runJSONCommand([]string{"hc", "wait", terminal, "--output", marker, "--timeout", "10"}, 15*time.Second, "")
		if err != nil {
			return err
		}
		if obs["reason"] == "exit" {
			if _, serr := os.Stat(path); serr != nil {
				return chatsend.Stop("worker_exited_check_original_operation", "uncertain")
			}
		}
	}
}

func workerCommand(directory string) ([]string, error) {
	piTask, err := exec.LookPath("pi-task")
	if err != nil {
		return nil, chatsend.Stop("pi_task_unavailable")
	}
	if _, err := exec.LookPath("hc"); err != nil {
		return nil, chatsend.Stop("herdr_unavailable")
	}
	ext, err := resolveWorkerExtension()
	if err != nil {
		return nil, err
	}
	return []string{
		"env", "CHAT_SEND_JOB=" + filepath.Join(directory, "job.json"), piTask,
		"--provider", providerName, "--model", modelName, "--thinking", "low",
		"--no-builtin-tools", "--tools", "deliver_message", "--no-mcp",
		"--no-extensions", "-e", ext, "--no-skills",
		"--no-context-files", "--no-prompt-templates", "--no-themes",
		"--offline", "--approve", "--name", "chat-" + filepath.Base(directory),
		"--session-dir", filepath.Join(directory, "sessions"), "--system-prompt", systemPrompt,
	}, nil
}

func launchArgs(opts taskOptions, directory string) ([]string, error) {
	prefix := strings.ToLower(opts.Operation)
	if len(prefix) > 18 {
		prefix = prefix[:18]
	}
	opDigest, err := chatsend.Digest(opts.Operation)
	if err != nil {
		return nil, err
	}
	name := "chat-" + prefix + "-" + opDigest[:8]
	run, err := workerCommand(directory)
	if err != nil {
		return nil, err
	}
	if opts.Portfolio != "" {
		if opts.TaskID == "" {
			return nil, chatsend.Stop("portfolio_requires_existing_task_id")
		}
		args := []string{
			"chief-of-staff-spawn", "--portfolio", opts.Portfolio, "--task-id", opts.TaskID,
			"--goal", "Prepare the bounded Google Chat job", "--role", "check", "--name", name,
			"--tab-name", "Chat messages", "--cwd", directory, "--harness", "pi",
			"--model", "litellm/" + modelName + "/low", "--no-codex-name", "--",
		}
		return append(args, run...), nil
	}
	args := []string{"hc", "run", "--bg", "--name", name, "--cwd", directory}
	return append(args, run...), nil
}

func nativeResult(mode, root, operation, directory string) (map[string]any, error) {
	bin, err := resolveSender()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, mode, "--operation", operation, "--state-dir", root)
	var outBuf bytes.Buffer
	cmd.Stdout = &outBuf
	_ = cmd.Run()
	if outBuf.Len() > chatsend.MaxJSONBytes {
		return nil, chatsend.Stop("sender_output_invalid")
	}
	var val map[string]any
	dec := json.NewDecoder(bytes.NewReader(outBuf.Bytes()))
	dec.UseNumber()
	if derr := dec.Decode(&val); derr != nil || val == nil {
		return nil, chatsend.Stop("sender_output_invalid")
	}
	outcome, _ := val["outcome"].(string)
	if val["operation_id"] != operation || (outcome != "preview" && outcome != "sent" && outcome != "needs_attention" && outcome != "uncertain" && outcome != "failed") {
		return nil, chatsend.Stop("sender_output_invalid")
	}
	if _, err := os.Stat(filepath.Join(root, operation, "receipt.json")); err != nil {
		return val, nil
	}
	return resultFor(root, operation, directory, val)
}

func executeTask(opts taskOptions) (map[string]any, error) {
	if !chatsend.TokenRe.MatchString(opts.Operation) {
		return nil, chatsend.Stop("invalid_operation_id")
	}
	absState, err := filepath.Abs(expandHome(opts.StateDir))
	if err != nil {
		return nil, err
	}
	root, err := chatsend.PrivateDir(absState)
	if err != nil {
		return nil, err
	}
	jobs, err := chatsend.PrivateDir(filepath.Join(root, ".workers"))
	if err != nil {
		return nil, err
	}
	directory := filepath.Join(jobs, opts.Operation)
	if opts.Mode != "" {
		if opts.Route != "" || opts.Brief != "" || opts.Send || opts.MentionEmail != "" || opts.MentionQuery != "" {
			return nil, chatsend.Stop("status_cancel_require_only_operation")
		}
		if opts.Mode == "status" {
			_, recErr := os.Stat(filepath.Join(root, opts.Operation, "receipt.json"))
			_, dirErr := os.Stat(directory)
			if recErr != nil && dirErr == nil {
				return resultFor(root, opts.Operation, directory, nil)
			}
		}
		return nativeResult(opts.Mode, root, opts.Operation, directory)
	}
	if opts.Route == "" || opts.Brief == "" {
		return nil, chatsend.Stop("route_and_brief_required")
	}
	route, err := chatsend.RouteConfig(opts.RoutesFile, opts.Route)
	if err != nil {
		return nil, err
	}
	rawBrief, err := os.ReadFile(opts.Brief)
	if err != nil || len(rawBrief) < 1 || len(rawBrief) > 16384 {
		return nil, chatsend.Stop("brief_must_be_1_to_16384_bytes")
	}
	brief := string(rawBrief)
	if strings.TrimSpace(brief) == "" {
		return nil, chatsend.Stop("invalid_brief_text")
	}
	for _, r := range brief {
		if (r < 32 && r != '\n' && r != '\t') || r == 0x7f {
			return nil, chatsend.Stop("invalid_brief_text")
		}
	}
	if (opts.MentionEmail != "") != (opts.MentionQuery != "") {
		return nil, chatsend.Stop("mention_requires_email_and_query")
	}
	var mention map[string]any
	if opts.MentionEmail != "" {
		mention = map[string]any{"email": opts.MentionEmail, "query": opts.MentionQuery}
	}
	kind, _ := route["kind"].(string)
	if kind == "" {
		kind = "dm"
	}
	if mention != nil && kind != "group" {
		return nil, chatsend.Stop("required_dm_mention_unsupported")
	}
	request := map[string]any{
		"alias":           opts.Route,
		"route":           route,
		"brief":           brief,
		"send_authorized": opts.Send,
		"mention":         mention,
	}
	fingerprint, err := chatsend.Digest(request)
	if err != nil {
		return nil, err
	}

	var out map[string]any
	lerr := chatsend.WithLock(filepath.Join(jobs, opts.Operation+".lock"), func() error {
		var perr error
		directory, perr = chatsend.PrivateDir(directory)
		if perr != nil {
			return perr
		}
		manifestPath := filepath.Join(directory, "job.json")
		if _, merr := os.Stat(manifestPath); merr == nil {
			job, rerr := chatsend.ReadJSON(manifestPath, true)
			if rerr != nil {
				return rerr
			}
			if job["fingerprint"] != fingerprint {
				return chatsend.Stop("worker_operation_request_changed")
			}
			if _, derr := os.Stat(filepath.Join(directory, "dispatch.json")); derr == nil {
				if _, recErr := os.Stat(filepath.Join(root, opts.Operation, "receipt.json")); recErr == nil {
					out, perr = nativeResult("status", root, opts.Operation, directory)
				} else {
					out, perr = resultFor(root, opts.Operation, directory, nil)
				}
				return perr
			}
		} else if _, recErr := os.Stat(filepath.Join(root, opts.Operation, "receipt.json")); recErr == nil {
			return chatsend.Stop("operation_exists_use_chat_send_status")
		} else {
			snapshot := filepath.Join(directory, "routes.json")
			if err := chatsend.AtomicWriteJSON(snapshot, map[string]any{"version": 1, "routes": map[string]any{opts.Route: route}}); err != nil {
				return err
			}
			if mention != nil {
				probe := filepath.Join(directory, "mention-validation.json")
				if err := chatsend.AtomicWriteJSON(probe, map[string]any{
					"version": 1,
					"blocks":  []any{map[string]any{"type": "text", "text": "validation"}},
					"mention": mention,
				}); err != nil {
					return err
				}
				_, _, _, _, verr := chatsend.PayloadParts(probe, nil)
				_ = os.Remove(probe)
				if verr != nil {
					return verr
				}
			}
			senderBin, serr := resolveSender()
			if serr != nil {
				return serr
			}
			job := map[string]any{
				"version":         1,
				"operation":       opts.Operation,
				"alias":           opts.Route,
				"sender":          senderBin,
				"routes_file":     snapshot,
				"state_dir":       root,
				"send_authorized": opts.Send,
				"mention":         mention,
				"request":         request,
				"fingerprint":     fingerprint,
			}
			if err := chatsend.AtomicWriteJSON(manifestPath, job); err != nil {
				return err
			}
		}
		localPi, err := chatsend.PrivateDir(filepath.Join(directory, ".pi"))
		if err != nil {
			return err
		}
		if err := chatsend.AtomicWriteJSON(filepath.Join(localPi, "settings.json"), workerSettings); err != nil {
			return err
		}
		argv, err := launchArgs(opts, directory)
		if err != nil {
			return err
		}
		if err := chatsend.AtomicWriteJSON(filepath.Join(directory, "dispatch.json"), map[string]any{"reserved_at": float64(time.Now().UnixNano()) / 1e9}); err != nil {
			return err
		}
		terminal := ""
		promptAttempted := false
		defer func() {
			if terminal == "" {
				return
			}
			cleanup := map[string]any{"terminal": terminal}
			for _, act := range []string{"kill", "rm"} {
				ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
				cmd := exec.CommandContext(ctx, "hc", act, terminal)
				err := cmd.Run()
				cancel()
				if err == nil {
					cleanup[act] = 0
				} else {
					var ee *exec.ExitError
					if errors.As(err, &ee) {
						cleanup[act] = ee.ExitCode()
					} else {
						cleanup[act] = "unconfirmed"
					}
				}
			}
			_ = chatsend.AtomicWriteJSON(filepath.Join(directory, "cleanup.json"), cleanup)
		}()

		handle, err := runJSONCommand(argv, 75*time.Second, filepath.Join(directory, "launch-error.json"))
		if err != nil {
			return err
		}
		terminal, _ = handle["address"].(string)
		if err := chatsend.AtomicWriteJSON(filepath.Join(directory, "dispatch.json"), map[string]any{"terminal": terminal, "launched_at": float64(time.Now().UnixNano()) / 1e9}); err != nil {
			return err
		}
		if err := waitFile(filepath.Join(directory, "ready.json"), terminal, "CHAT_SEND_READY", time.Now().Add(45*time.Second)); err != nil {
			return err
		}
		ready, err := chatsend.ReadJSON(filepath.Join(directory, "ready.json"), true)
		if err != nil {
			return err
		}
		resolvedDir, _ := filepath.EvalSymlinks(directory)
		if resolvedDir == "" {
			resolvedDir = directory
		}
		wantPrompt := systemPrompt + "\n\n<cwd>\n" + resolvedDir + "\n</cwd>"
		toolsRaw, _ := ready["tools"].([]any)
		if ready["model"] != modelName || ready["provider"] != providerName || ready["thinking"] != "low" || len(toolsRaw) != 1 || toolsRaw[0] != "deliver_message" || ready["system_prompt"] != wantPrompt {
			return chatsend.Stop("worker_startup_scope_mismatch")
		}
		promptAttempted = true
		if err := chatsend.AtomicWriteJSON(filepath.Join(directory, "prompt-attempt.json"), map[string]any{"at": float64(time.Now().UnixNano()) / 1e9, "terminal": terminal}); err != nil {
			return err
		}
		sent, err := runJSONCommand([]string{"hc", "send", terminal, "Prepare the message from this self-contained brief:\n\n" + brief}, 75*time.Second, "")
		if err != nil {
			if promptAttempted {
				return chatsend.Stop("worker_interrupted_check_original_operation", "uncertain")
			}
			return err
		}
		if started, ok := sent["started"].(bool); ok && !started {
			return chatsend.Stop("prompt_delivery_uncertain_check_original_worker", "uncertain")
		}
		if err := waitFile(filepath.Join(directory, "done.json"), terminal, "CHAT_SEND_DONE", time.Now().Add(210*time.Second)); err != nil {
			if promptAttempted {
				return chatsend.Stop("worker_interrupted_check_original_operation", "uncertain")
			}
			return err
		}
		res, err := resultFor(root, opts.Operation, directory, nil)
		if err != nil {
			if promptAttempted {
				return chatsend.Stop("worker_interrupted_check_original_operation", "uncertain")
			}
			return err
		}
		if err := chatsend.AtomicWriteJSON(filepath.Join(directory, "result.json"), res); err != nil {
			return err
		}
		out = res
		return nil
	})
	if lerr != nil {
		return nil, lerr
	}
	return out, nil
}

func parseTaskArgs(argv []string) (taskOptions, error) {
	opts := taskOptions{
		RoutesFile: defaultPath("XDG_CONFIG_HOME", ".config", "chat-send/routes.json"),
		StateDir:   defaultPath("XDG_STATE_HOME", ".local/state", "chat-send"),
	}
	for i := 0; i < len(argv); i++ {
		arg := argv[i]
		if !strings.HasPrefix(arg, "-") {
			if opts.Mode != "" || (arg != "status" && arg != "cancel") {
				return opts, fmt.Errorf("unexpected argument: %s", arg)
			}
			opts.Mode = arg
			continue
		}
		nextVal := func() (string, error) {
			if i+1 >= len(argv) {
				return "", fmt.Errorf("missing value for %s", arg)
			}
			i++
			return argv[i], nil
		}
		key := arg
		var val string
		hasEq := false
		if idx := strings.IndexByte(arg, '='); idx >= 0 {
			key = arg[:idx]
			val = arg[idx+1:]
			hasEq = true
		}
		readVal := func() (string, error) {
			if hasEq {
				return val, nil
			}
			return nextVal()
		}
		switch key {
		case "--send":
			opts.Send = true
		case "--route":
			v, err := readVal()
			if err != nil {
				return opts, err
			}
			opts.Route = v
		case "--brief":
			v, err := readVal()
			if err != nil {
				return opts, err
			}
			opts.Brief = v
		case "--operation":
			v, err := readVal()
			if err != nil {
				return opts, err
			}
			opts.Operation = v
		case "--mention-email":
			v, err := readVal()
			if err != nil {
				return opts, err
			}
			opts.MentionEmail = v
		case "--mention-query":
			v, err := readVal()
			if err != nil {
				return opts, err
			}
			opts.MentionQuery = v
		case "--portfolio":
			v, err := readVal()
			if err != nil {
				return opts, err
			}
			opts.Portfolio = v
		case "--task-id":
			v, err := readVal()
			if err != nil {
				return opts, err
			}
			opts.TaskID = v
		case "--routes-file":
			v, err := readVal()
			if err != nil {
				return opts, err
			}
			opts.RoutesFile = v
		case "--state-dir":
			v, err := readVal()
			if err != nil {
				return opts, err
			}
			opts.StateDir = v
		case "-h", "--help":
			fmt.Fprintln(os.Stderr, "Usage: chat-send-task [status|cancel] --operation ID [--route ALIAS --brief FILE [--send] [--mention-email EMAIL --mention-query QUERY] [--portfolio DIR --task-id ID]] [--routes-file FILE] [--state-dir DIR]")
			os.Exit(0)
		default:
			return opts, fmt.Errorf("unknown flag: %s", key)
		}
	}
	if opts.Operation == "" {
		return opts, fmt.Errorf("--operation is required")
	}
	return opts, nil
}

func main() {
	syscall.Umask(0o077)
	opts, err := parseTaskArgs(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	res, runErr := executeTask(opts)
	if runErr != nil {
		outcome := "needs_attention"
		reason := "worker_runtime_or_storage_error"
		var se *chatsend.StopError
		if errors.As(runErr, &se) {
			outcome = se.Outcome
			reason = se.Reason
		}
		res = map[string]any{
			"outcome":      outcome,
			"reason":       reason,
			"operation_id": opts.Operation,
		}
		if chatsend.TokenRe.MatchString(opts.Operation) {
			dir := filepath.Join(opts.StateDir, ".workers", opts.Operation)
			if _, serr := os.Stat(dir); serr == nil {
				res["worker_job"] = dir
				launchErr := filepath.Join(dir, "launch-error.json")
				if _, lerr := os.Stat(launchErr); lerr == nil {
					res["diagnostics"] = launchErr
				}
			}
		}
	}
	raw, _ := chatsend.Encode(res)
	fmt.Println(string(raw))
	outcome, _ := res["outcome"].(string)
	os.Exit(chatsend.ExitCode(outcome))
}
