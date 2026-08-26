package daemon

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestCanonicalCodexNativeEventsRetainMetadataNotPrompts(t *testing.T) {
	raw := []byte(`{"method":"item/started","params":{"threadId":"root","turnId":"turn-1","item":{"type":"collabAgentToolCall","id":"item-1","tool":"spawnAgent","status":"inProgress","senderThreadId":"root","receiverThreadIds":["root/worker"],"prompt":"private task text"}}}`)
	encoded, err := CanonicalAgentEnvelope("codex", raw, "codex-app-server")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "private task text") {
		t.Fatalf("canonical event leaked provider prompt: %s", encoded)
	}
	var envelope struct {
		Schema int            `json:"schema_version"`
		Event  map[string]any `json:"event"`
	}
	if json.Unmarshal(encoded, &envelope) != nil {
		t.Fatal("invalid canonical JSON")
	}
	if envelope.Schema != 1 || envelope.Event["hook_event_name"] != "SubagentStart" ||
		envelope.Event["agent_id"] != "root/worker" || envelope.Event["thread_id"] != "root" {
		t.Fatalf("unexpected canonical event: %#v", envelope)
	}
}

func TestCanonicalCodexTokenUsage(t *testing.T) {
	raw := []byte(`{"method":"thread/tokenUsage/updated","params":{"threadId":"t","turnId":"v","tokenUsage":{"total":{"inputTokens":100,"cachedInputTokens":40,"outputTokens":7}}}}`)
	encoded, err := CanonicalAgentEnvelope("codex", raw, "codex-app-server")
	if err != nil {
		t.Fatal(err)
	}
	var envelope struct {
		Event map[string]any `json:"event"`
	}
	if json.Unmarshal(encoded, &envelope) != nil {
		t.Fatal("invalid canonical JSON")
	}
	if envelope.Event["hook_event_name"] != "ResourceUsage" || envelope.Event["input_tokens"] != float64(100) {
		t.Fatalf("unexpected resource event: %#v", envelope.Event)
	}
}

func TestCanonicalClaudeStreamLifecycle(t *testing.T) {
	encoded, err := CanonicalAgentEnvelope("claude", []byte(`{"type":"system","session_id":"claude-1"}`), "claude-stream-json")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encoded), `"hook_event_name":"SessionStart"`) {
		t.Fatalf("unexpected Claude lifecycle event: %s", encoded)
	}
}

func TestCanonicalPeerMessageKeepsBoundedContentAndDirection(t *testing.T) {
	raw := []byte(`{"method":"item/started","params":{"threadId":"root","item":{"type":"collabAgentToolCall","id":"m1","tool":"sendInput","status":"inProgress","senderThreadId":"root/a","receiverThreadIds":["root/b"],"prompt":"check the result"}}}`)
	encoded, err := CanonicalAgentEnvelope("codex", raw, "codex-app-server")
	if err != nil {
		t.Fatal(err)
	}
	var envelope struct {
		Event map[string]any `json:"event"`
	}
	if json.Unmarshal(encoded, &envelope) != nil {
		t.Fatal("invalid canonical JSON")
	}
	if envelope.Event["hook_event_name"] != "PeerMessage" || envelope.Event["from_peer_id"] != "root/a" ||
		envelope.Event["to_peer_id"] != "root/b" || envelope.Event["message"] != "check the result" {
		t.Fatalf("unexpected peer event: %#v", envelope.Event)
	}
}
