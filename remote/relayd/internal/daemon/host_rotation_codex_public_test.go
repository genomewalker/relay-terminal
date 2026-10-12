package daemon

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func rotationCodexPublicRow(kind string, payload any) string {
	data, _ := json.Marshal(map[string]any{"type": kind, "payload": payload})
	return string(data) + "\n"
}

func rotationCodexPublicResponse(role, id, turn, channel string, content []any, kinds any) string {
	payload := map[string]any{"type": "message", "role": role, "id": id, "content": content}
	if channel != "" {
		payload["channel"] = channel
	}
	metadata := map[string]any{}
	if turn != "" {
		metadata["turn_id"] = turn
	}
	if kinds != nil {
		metadata["content_item_kinds"] = kinds
	}
	if len(metadata) > 0 {
		payload["internal_chat_message_metadata_passthrough"] = metadata
	}
	return rotationCodexPublicRow("response_item", payload)
}
func rotationCodexPublicAssistant(channel, text, id, turn string) string {
	return rotationCodexPublicResponse("assistant", id, turn, channel, []any{map[string]any{"type": "output_text", "text": text}}, nil)
}
func rotationCodexPublicEvent(thread, turn, id, kind, text string) string {
	return rotationCodexPublicRow("event_msg", map[string]any{"type": "item_completed", "thread_id": thread, "turn_id": turn, "item": map[string]any{"type": kind, "id": id, "content": []any{map[string]any{"type": "Text", "text": text}}}})
}
func rotationCodexPublicHeader() string {
	return rotationCodexPublicRow("session_meta", map[string]any{"id": "fixture-session", "cwd": "/fixture", "source": "cli"})
}
func rotationCodexPublicUser() string {
	return rotationCodexPublicResponse("user", "human", "turn-a", "", []any{map[string]any{"type": "input_text", "text": "Keep 🙂 the pane."}}, []string{"user.text"})
}
func rotationCodexParsePublic(source string) ([]rotationSourceMessage, error) {
	return parseRotationSource(context.Background(), strings.NewReader(source), "codex", "fixture-session", "/fixture")
}
func TestHostRotationCodexPublicCompletionMatchesExactNativeEvidence(t *testing.T) {
	response := rotationCodexPublicAssistant("", "Ready 漢字.", "a", "turn-a")
	event := rotationCodexPublicEvent("fixture-session", "turn-a", "a", "AgentMessage", "Ready 漢字.")
	header := rotationCodexPublicHeader() + rotationCodexPublicUser()
	want := []rotationSourceMessage{{"user", "Keep 🙂 the pane."}, {"assistant", "Ready 漢字."}}
	for name, source := range map[string]string{"response_first": header + response + event, "completion_first": header + event + response, "legacy_explicit_and_completed": header + rotationCodexPublicAssistant("final", "Ready 漢字.", "a", "turn-a") + event} {
		t.Run(name, func(t *testing.T) {
			messages, err := rotationCodexParsePublic(source)
			if err != nil || !reflect.DeepEqual(messages, want) {
				t.Fatalf("public evidence: %#v %v", messages, err)
			}
		})
	}
}
func TestHostRotationCodexPublicCompletionRejectsUnmatchedOrHiddenEvidence(t *testing.T) {
	header := rotationCodexPublicHeader() + rotationCodexPublicUser()
	response := rotationCodexPublicAssistant("", "Public", "a", "turn-a")
	event := rotationCodexPublicEvent("fixture-session", "turn-a", "a", "AgentMessage", "Public")
	cases := map[string]string{
		"missing_completion":          response,
		"completion_without_response": event,
		"wrong_id":                    response + rotationCodexPublicEvent("fixture-session", "turn-a", "other", "AgentMessage", "Public"),
		"wrong_turn":                  response + rotationCodexPublicEvent("fixture-session", "turn-b", "a", "AgentMessage", "Public"),
		"wrong_thread":                response + rotationCodexPublicEvent("other", "turn-a", "a", "AgentMessage", "Public"),
		"wrong_text":                  response + rotationCodexPublicEvent("fixture-session", "turn-a", "a", "AgentMessage", "Different"),
		"reasoning_item":              response + rotationCodexPublicEvent("fixture-session", "turn-a", "a", "Reasoning", "Public"),
		"tool_item":                   response + rotationCodexPublicEvent("fixture-session", "turn-a", "a", "CommandExecution", "Public"),
		"explicit_analysis":           rotationCodexPublicAssistant("analysis", "Public", "a", "turn-a") + event,
		"unknown_channel":             rotationCodexPublicAssistant("unknown", "Public", "a", "turn-a") + event,
		"missing_response_turn":       rotationCodexPublicAssistant("", "Public", "a", "") + event,
		"missing_response_id":         rotationCodexPublicAssistant("", "Public", "", "turn-a") + event,
		"empty_event_turn":            response + rotationCodexPublicEvent("fixture-session", "", "a", "AgentMessage", "Public"),
		"empty_event_id":              response + rotationCodexPublicEvent("fixture-session", "turn-a", "", "AgentMessage", "Public"),
		"long_event_id":               response + rotationCodexPublicEvent("fixture-session", "turn-a", strings.Repeat("x", 257), "AgentMessage", "Public"),
		"duplicate_response":          response + event + response,
		"duplicate_completion":        response + event + event,
		"analysis_identity_reused":    rotationCodexPublicAssistant("analysis", "Public", "a", "turn-a") + response + event,
		"ambiguous_channel":           strings.Replace(response, `"role":"assistant"`, `"channel":"analysis","channel":"final","role":"assistant"`, 1) + event,
	}
	for name, tail := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := rotationCodexParsePublic(header + tail); err == nil {
				t.Fatal("accepted unmatched or hidden source")
			}
		})
	}
	if _, err := rotationCodexParsePublic(event + header + response); err == nil {
		t.Fatal("accepted completion before session identity")
	}
}
func TestHostRotationCodexPublicMetadataSelectsOnlyHumanText(t *testing.T) {
	content := []any{
		map[string]any{"type": "input_text", "text": "PRIVATE_ENV"},
		map[string]any{"type": "input_text", "text": "Keep 🙂 the pane."},
		map[string]any{"type": "input_text", "text": "PRIVATE_SYSTEM"},
		map[string]any{"type": "input_image", "image_url": "PRIVATE_IMAGE"},
		map[string]any{"type": "input_text", "text": "PRIVATE_UNKNOWN"},
	}
	source := rotationCodexPublicHeader() + rotationCodexPublicResponse("user", "mixed", "turn-a", "", content, []string{"environments.environment_context", "user.text", "system.instructions", "user.image", "unknown"}) +
		rotationCodexPublicAssistant("final", "done", "a", "turn-a")
	messages, err := rotationCodexParsePublic(source)
	if err != nil || len(messages) != 2 || messages[0].Text != "Keep 🙂 the pane." {
		t.Fatalf("human text: %#v %v", messages, err)
	}
	cases := map[string]string{
		"environment":           rotationCodexPublicResponse("user", "u", "turn-a", "", content[:1], []string{"environments.environment_context"}),
		"unknown":               rotationCodexPublicResponse("user", "u", "turn-a", "", content[:1], []string{"unknown"}),
		"missing_kinds":         rotationCodexPublicResponse("user", "u", "turn-a", "", content[:1], nil),
		"kind_length_mismatch":  rotationCodexPublicResponse("user", "u", "turn-a", "", content, []string{"user.text"}),
		"kind_type_mismatch":    rotationCodexPublicResponse("user", "u", "turn-a", "", content, 42),
		"kind_content_mismatch": rotationCodexPublicResponse("user", "u", "turn-a", "", content[3:4], []string{"user.text"}),
		"invalid_turn":          rotationCodexPublicResponse("user", "u", "bad\nturn", "", content[1:2], []string{"user.text"}),
	}
	for name, row := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := rotationCodexParsePublic(rotationCodexPublicHeader() + row + rotationCodexPublicAssistant("final", "done", "a", "turn-a")); err == nil {
				t.Fatal("accepted nonhuman or malformed source")
			}
		})
	}
}
func TestHostRotationCodexPublicCompletionPreservesOrderAndBounds(t *testing.T) {
	header := rotationCodexPublicHeader() + rotationCodexPublicUser()
	source := header + rotationCodexPublicAssistant("", "first", "a", "turn-a") + rotationCodexPublicAssistant("commentary", "second", "b", "turn-a") +
		rotationCodexPublicEvent("fixture-session", "turn-a", "a", "AgentMessage", "first") + rotationCodexPublicAssistant("final", "third", "c", "turn-a")
	messages, err := rotationCodexParsePublic(source)
	want := []rotationSourceMessage{{"user", "Keep 🙂 the pane."}, {"assistant", "first"}, {"assistant", "second"}, {"assistant", "third"}}
	if err != nil || !reflect.DeepEqual(messages, want) {
		t.Fatalf("source order: %#v %v", messages, err)
	}
	// Unmatched pending text is bounded as well as admitted public text.
	block := strings.Repeat("x", rotationSourceTextLimit/3)
	oversized := header
	for _, id := range []string{"a", "b", "c", "d"} {
		oversized += rotationCodexPublicAssistant("", block, id, "turn-a")
	}
	if _, err := rotationCodexParsePublic(oversized); err == nil {
		t.Fatal("accepted unbounded pending evidence")
	}
}
