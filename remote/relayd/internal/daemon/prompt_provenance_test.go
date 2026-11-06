package daemon

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/nativemsg"
)

const provenanceMessageID = "4f8b2d6a-3c19-4e75-a0d2-9b7e1c5f3a64"

func usePeerDeliveryNotice(t *testing.T) *[][]string {
	t.Helper()
	saved := PeerDeliveryNotice
	var notices [][]string
	PeerDeliveryNotice = func(pane string, payload []byte) error {
		notices = append(notices, []string{pane, string(payload)})
		return nil
	}
	t.Cleanup(func() { PeerDeliveryNotice = saved })
	return &notices
}

func TestNativeSendAnnouncesAContentFreeDeliveryToTheTargetPane(t *testing.T) {
	notices := usePeerDeliveryNotice(t)
	secret := "MESSAGE-TEXT-must-not-leave-relayd"
	useNativeRun(t, func(context.Context, nativemsg.Host, string, []byte) map[string]any {
		return map[string]any{"status": "written_to_socket", "acknowledgement": "not_implied", "transport": "native_peer_socket"}
	})
	if _, err := communicationNative(adapterTestPane, map[string]any{"operation": "send", "messageID": strings.ToUpper(provenanceMessageID), "text": secret}); err != nil {
		t.Fatal(err)
	}
	if len(*notices) != 1 || (*notices)[0][0] != adapterTestPane {
		t.Fatalf("notices %v", *notices)
	}
	payload := (*notices)[0][1]
	if strings.Contains(payload, secret) || strings.Contains(payload, "text") {
		t.Fatalf("notice carries content: %s", payload)
	}
	var envelope struct {
		Agent string         `json:"agent"`
		Event map[string]any `json:"event"`
	}
	if json.Unmarshal([]byte(payload), &envelope) != nil || envelope.Agent != "relay" ||
		envelope.Event["type"] != "peer_message_delivered" || envelope.Event["message_id"] != provenanceMessageID ||
		envelope.Event["transport"] != "native_peer_socket" || envelope.Event["status"] != "written_to_socket" {
		t.Fatalf("notice %s", payload)
	}
}

func TestOnlyAWrittenSendIsAnnounced(t *testing.T) {
	now := time.Now()
	send := map[string]any{"operation": "send", "messageID": provenanceMessageID}
	written := map[string]any{"status": "written_to_socket", "transport": "native_peer_socket"}
	if peerDeliveryNoticePayload(send, map[string]any{"status": "accepted_by_provider", "transport": "codex_app_server_message"}, now) == nil {
		t.Fatal("Codex acceptance not announced")
	}
	for name, c := range map[string]struct{ packet, result map[string]any }{
		"discover":         {map[string]any{"operation": "discover", "messageID": provenanceMessageID}, written},
		"held, not sent":   {send, map[string]any{"status": "not_sent", "reason": "held_expected"}},
		"no status":        {send, map[string]any{}},
		"missing ID":       {map[string]any{"operation": "send"}, written},
		"malformed ID":     {map[string]any{"operation": "send", "messageID": "../" + provenanceMessageID}, written},
		"non-string ID":    {map[string]any{"operation": "send", "messageID": 7}, written},
		"status as number": {send, map[string]any{"status": 1}},
	} {
		if payload := peerDeliveryNoticePayload(c.packet, c.result, now); payload != nil {
			t.Fatalf("%s announced: %s", name, payload)
		}
	}
	payload := peerDeliveryNoticePayload(send, map[string]any{"status": "written_to_socket", "transport": "x\" y"}, now)
	if strings.Contains(string(payload), "transport") {
		t.Fatalf("malformed transport kept: %s", payload)
	}
	// A refused adapter run writes nothing and announces nothing.
	notices := usePeerDeliveryNotice(t)
	useNativeRun(t, func(context.Context, nativemsg.Host, string, []byte) map[string]any {
		return map[string]any{"status": "not_sent", "reason": "held_expected"}
	})
	_, _ = communicationNative(adapterTestPane, map[string]any{"operation": "send", "messageID": provenanceMessageID})
	if len(*notices) != 0 {
		t.Fatalf("held message announced: %v", *notices)
	}
}

func TestClaudePromptHookCarriesFingerprintsNotThePrompt(t *testing.T) {
	block := "<cross-session-message from=\"uds:/tmp/cc-socks/1.sock\" from-session=\"s\" from-name=\"Claude pane bc08\" from-mode=\"bypass\">\n" +
		"Relay message " + provenanceMessageID + " from Claude pane bc08 (session s). Relay verified the sending pane.\nPRIVATE-BODY\n</cross-session-message>"
	prompt := "Another Claude session sent a message:\n" + block + "\n\nThis came from another Claude session."
	raw, _ := json.Marshal(map[string]any{"hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt": prompt})
	envelope, err := CanonicalAgentEnvelope("claude", raw, "hook")
	if err != nil {
		t.Fatal(err)
	}
	indexed := string(indexedAgentPayload(envelope, 9))
	if strings.Contains(indexed, "PRIVATE-BODY") || strings.Contains(indexed, "Another Claude") || strings.Contains(indexed, `"prompt"`) {
		t.Fatalf("prompt text reached the journal: %s", indexed)
	}
	var decoded struct {
		Event map[string]any `json:"event"`
	}
	_ = json.Unmarshal([]byte(indexed), &decoded)
	if decoded.Event["prompt_length"] != float64(len([]rune(prompt))) || decoded.Event["prompt_peer_message_id"] != provenanceMessageID {
		t.Fatalf("fingerprint %v", decoded.Event)
	}
	if prefix, _ := decoded.Event["prompt_sha256_prefix"].(string); len(prefix) != 12 {
		t.Fatalf("hash prefix %q", prefix)
	}
	// Negatives: a typed prompt has no peer ID; other hooks and providers get no fingerprint.
	raw, _ = json.Marshal(map[string]any{"hook_event_name": "UserPromptSubmit", "prompt": "yes, install it"})
	envelope, _ = CanonicalAgentEnvelope("claude", raw, "hook")
	if strings.Contains(string(indexedAgentPayload(envelope, 10)), "prompt_peer_message_id") {
		t.Fatal("typed prompt given a peer message ID")
	}
	for provider, hook := range map[string]string{"claude": "Stop", "codex": "UserPromptSubmit"} {
		raw, _ = json.Marshal(map[string]any{"hook_event_name": hook, "prompt": prompt})
		envelope, _ = CanonicalAgentEnvelope(provider, raw, "hook")
		if out := string(indexedAgentPayload(envelope, 11)); strings.Contains(out, "prompt_") || strings.Contains(out, "PRIVATE-BODY") {
			t.Fatalf("%s %s fingerprinted or leaked: %s", provider, hook, out)
		}
	}
}
