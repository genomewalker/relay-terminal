package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/relay-terminal/relayd/internal/nativemsg"
)

// Prompt provenance support. Everything here is content-free: lengths, 12-hex
// SHA-256 prefixes and message IDs, never prompt or message text.

var (
	noticeMessageIDPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	noticeTransportPattern = regexp.MustCompile(`^[a-z_]{1,32}$`)
)

// PeerDeliveryNotice sends one agent-event payload to a pane's session. The
// relayd command wires it to the supervisor's event-only socket; when unset,
// deliveries are not announced.
var PeerDeliveryNotice func(pane string, payload []byte) error

// peerDeliveryNoticePayload is the content-free event announcing that relayd
// wrote a peer message to a pane's native inbox, or nil when the outcome does
// not say the message was written.
func peerDeliveryNoticePayload(packet, result map[string]any, now time.Time) []byte {
	if packet["operation"] != "send" {
		return nil
	}
	status, _ := result["status"].(string)
	if status != "written_to_socket" && status != "accepted_by_provider" {
		return nil
	}
	event := map[string]any{"type": "peer_message_delivered", "status": status,
		"occurred_at": now.UTC().Format(time.RFC3339Nano)}
	id, _ := packet["messageID"].(string)
	id = strings.ToLower(id)
	if !noticeMessageIDPattern.MatchString(id) {
		// The ID is what the desktop matches; without one there is nothing to announce.
		return nil
	}
	event["message_id"] = id
	if transport, _ := result["transport"].(string); noticeTransportPattern.MatchString(transport) {
		event["transport"] = transport
	}
	payload, err := json.Marshal(map[string]any{"agent": "relay", "event": event})
	if err != nil {
		return nil
	}
	return payload
}

// announcePeerDelivery tells the target pane's desktop that a peer message
// arrived outside its keyboard path. Best effort: the delivery already happened
// and its receipt is authoritative; a lost notice leaves the submit unknown.
func announcePeerDelivery(pane string, packet, result map[string]any) {
	if PeerDeliveryNotice == nil {
		return
	}
	if payload := peerDeliveryNoticePayload(packet, result, time.Now()); payload != nil {
		_ = PeerDeliveryNotice(pane, payload)
	}
}

// addClaudePromptFingerprint replaces Claude's UserPromptSubmit prompt with
// its length, a hash prefix and the ID of any embedded peer-message block.
// The prompt text itself never leaves the hook.
func addClaudePromptFingerprint(event, input map[string]any) {
	if input["hook_event_name"] != "UserPromptSubmit" {
		return
	}
	prompt, ok := input["prompt"].(string)
	if !ok {
		return
	}
	sum := sha256.Sum256([]byte(prompt))
	event["prompt_length"] = int64(utf8.RuneCountInString(prompt))
	event["prompt_sha256_prefix"] = hex.EncodeToString(sum[:])[:12]
	if id, found := nativemsg.PeerBlockMessageID(prompt); found {
		event["prompt_peer_message_id"] = id
	}
}
