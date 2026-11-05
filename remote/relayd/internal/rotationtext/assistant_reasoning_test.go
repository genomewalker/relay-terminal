package rotationtext

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestAssistantAdaptiveReasoningRequestAndReceipt(t *testing.T) {
	safetyJournal(t, 100)
	var sent obj
	thinking := obj{"type": "thinking", "thinking": "", "signature": "opaque-signed-fixture"}
	apiPostHook = func(raw []byte, _ string, _ time.Duration) []byte {
		sent = parseJSON(raw).(obj)
		return []byte(compact(obj{"model": apiModel, "stop_reason": "end_turn",
			"content": []any{thinking, obj{"type": "text", "text": "Ready."}},
			"usage":   obj{"input_tokens": int64(20), "output_tokens": int64(30)}}))
	}
	evidence := compact(obj{"context": "{}", "messages": []any{obj{"role": "user", "content": "Inspect Relay"}}})
	result := assistantStep(context.Background(), safetyStep(evidence))
	safetyEq(t, sent["thinking"], obj{"type": "adaptive", "display": "omitted"})
	safetyEq(t, sent["cache_control"], obj{"type": "ephemeral"})
	safetyEq(t, sent["system"].([]any)[0].(obj)["cache_control"], obj{"type": "ephemeral"})
	safetyEq(t, sent["output_config"], obj{"effort": "medium"})
	safetyEq(t, sent["max_tokens"], 2048)
	safetyEq(t, result["thinking"], "adaptive")
	safetyEq(t, result["effort"], "medium")
	safetyEq(t, result["assistant_content"].([]any)[0], thinking)
}

func TestAssistantOpaqueThinkingSurvivesToolContinuation(t *testing.T) {
	thinking := obj{"type": "thinking", "thinking": "", "signature": "password=opaque_fixture_signature"}
	redacted := obj{"type": "redacted_thinking", "data": "opaque-redacted-fixture"}
	call := safetyCall("get_pane_health")
	messages := []any{
		obj{"role": "user", "content": "Inspect Relay"},
		obj{"role": "assistant", "content": []any{thinking, redacted, call}},
		obj{"role": "user", "content": []any{obj{"type": "tool_result", "tool_use_id": call["id"], "content": "ok"}}},
	}
	safetyEq(t, validateAssistantMessages(messages), 1)
	forwarded := redactAssistantMessages(messages, "opaque_fixture_signature")
	blocks := forwarded[1].(obj)["content"].([]any)
	safetyEq(t, blocks[0], thinking)
	safetyEq(t, blocks[1], redacted)
	for _, bad := range []obj{
		{"type": "thinking", "thinking": "readable reasoning", "signature": "signed"},
		{"type": "thinking", "thinking": "", "signature": ""},
		{"type": "thinking", "thinking": "", "signature": "signed", "input": obj{}},
		{"type": "thinking", "thinking": "", "signature": strings.Repeat("x", 65537)},
		{"type": "redacted_thinking", "data": ""},
		{"type": "redacted_thinking", "data": "opaque", "input": obj{}},
	} {
		safetyRejected(t, func() { validateAssistantBlocks([]any{bad}, 16) })
	}
}
