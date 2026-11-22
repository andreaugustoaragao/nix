package main

import (
	"os"
	"path/filepath"
	"testing"

	"chat-send/internal/chatsend"
)

func TestAccountingAndValidation(t *testing.T) {
	dir := t.TempDir()
	// Telemetry with two requests matching done.json requests=2.
	tele := `{"event":"wire_usage","data":{"request":1,"id":"r1","usage":{"cost":0.0012}}}
{"event":"wire_usage","data":{"request":2,"id":"r2","usage":{"cost":0.0008}}}
{corrupt partial line
`
	if err := os.WriteFile(filepath.Join(dir, "telemetry.jsonl"), []byte(tele), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := chatsend.AtomicWriteJSON(filepath.Join(dir, "done.json"), map[string]any{"requests": 2}); err != nil {
		t.Fatal(err)
	}
	acc := accounting(dir)
	if acc["usage_complete"] != true {
		t.Fatalf("expected usage_complete=true, got %+v", acc)
	}
	if acc["cost_source"] != "gateway usage.cost" {
		t.Fatalf("unexpected cost_source: %+v", acc)
	}
	cost, ok := acc["gateway_cost"].(float64)
	if !ok || cost < 0.00199 || cost > 0.00201 {
		t.Fatalf("unexpected gateway_cost: %+v", acc["gateway_cost"])
	}

	// DM mention must fail closed before launching any worker.
	routesPath := filepath.Join(dir, "routes.json")
	if err := chatsend.AtomicWriteJSON(routesPath, map[string]any{
		"version": 1,
		"routes": map[string]any{
			"dm": map[string]any{
				"url":           "https://chat.google.com/app/chat/EXAMPLE",
				"title":         "Example - Chat",
				"account":       "aragao@avaya.com",
				"account_label": "Google Account: Andre Aragao (aragao@avaya.com)",
			},
		},
	}); err != nil {
		t.Fatal(err)
	}
	briefPath := filepath.Join(dir, "brief.txt")
	if err := os.WriteFile(briefPath, []byte("Say hi"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := executeTask(taskOptions{
		Route:        "dm",
		Brief:        briefPath,
		Operation:    "op-dm-mention",
		MentionEmail: "other@avaya.com",
		MentionQuery: "Other",
		RoutesFile:   routesPath,
		StateDir:     filepath.Join(dir, "state"),
	})
	if err == nil || err.Error() != "required_dm_mention_unsupported" {
		t.Fatalf("expected required_dm_mention_unsupported, got %v", err)
	}
}
