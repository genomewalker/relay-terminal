package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestHostRotationTextResourceParity(t *testing.T) {
	source, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "Sources", "Relay", "Resources", "Rotation", "text_backend.py"))
	if err != nil || !bytes.Equal(source, hostRotationText) {
		t.Fatal("embedded text adapter differs from the canonical resource", err)
	}
}

func TestHostRotationTextServiceDefaultsAndPrivateSettings(t *testing.T) {
	root := filepath.Join(t.TempDir(), "workers")
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	call := func(operation string, args any) map[string]any {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		raw, err := hostRotationTextService(ctx, root, operation, args)
		if err != nil {
			t.Fatal(err)
		}
		var result map[string]any
		if json.Unmarshal(raw, &result) != nil {
			t.Fatal("invalid result")
		}
		return result
	}
	if result := call("status", map[string]any{}); result["status"] != "not_configured" {
		t.Fatalf("unexpected initial status: %v", result)
	}
	if _, err := os.Stat(filepath.Join(root, "rotation-text")); !os.IsNotExist(err) {
		t.Fatal("status created journal state")
	}
	settings := map[string]any{"enabled": false, "providers": []string{"anthropic_api"},
		"daily_limit_microusd": 1000000, "monthly_limit_microusd": 2000000, "max_requests_per_day": 10}
	result := call("configure", map[string]any{"operation_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "settings": settings})
	if result["status"] != "ready" {
		t.Fatalf("configuration failed: %v", result)
	}
	result = call("submit", map[string]any{"v": 1, "operation_id": "11111111111111111111111111111111",
		"binding": map[string]any{"session_id": "fixture", "client": "claude", "turn_seq": 1}, "evidence": "Offline fixture only."})
	if result["code"] != "text_backend_disabled" {
		t.Fatalf("disabled backend did not refuse: %v", result)
	}
	settings["api_key"] = "secret-must-never-persist"
	result = call("configure", map[string]any{"operation_id": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "settings": settings})
	if result["code"] != "invalid_settings" {
		t.Fatalf("secret accepted in settings: %v", result)
	}
	path := filepath.Join(root, "rotation-text", "operations.sqlite3")
	data, err := privatePromptEditorBytes(path, 1<<20)
	if err != nil || bytes.Contains(data, []byte("secret-must-never-persist")) {
		t.Fatal("journal permissions or secret persistence", err)
	}
}
