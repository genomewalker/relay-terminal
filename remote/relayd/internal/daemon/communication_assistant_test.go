package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func assistantFixture(t *testing.T) (string, string, string, *[]map[string]any, communicationGroupNative) {
	t.Helper()
	root := filepath.Join(t.TempDir(), "communication")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	here, target := "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"
	endpoint := map[string]any{"provider": "claude", "sessionID": "s-1", "pid": float64(42), "start": "k:1",
		"socketIdentity": "dev:ino", "transport": "native_peer_socket"}
	sent := &[]map[string]any{}
	native := communicationGroupNative{
		observe: func(pane string) communicationMember {
			return communicationMember{PaneID: pane, Provider: "claude", SessionID: "s-1", PID: 42, Start: "k:1", Endpoint: endpoint}
		},
		send: func(pane string, packet map[string]any) (map[string]any, error) {
			*sent = append(*sent, packet)
			return map[string]any{"status": "written_to_socket", "acknowledgement": "not_implied"}, nil
		},
	}
	return root, here, target, sent, native
}

func assistantRequest(here, target string) CommunicationRequest {
	return CommunicationRequest{Operation: "assistant_send", SourcePaneID: here, PaneID: target,
		MessageID: "33333333-3333-4333-8333-333333333333", Text: "Please run the tests.", AssistantRequestID: "req123",
		ExpectedRecipient: map[string]any{"provider": "claude", "sessionID": "s-1", "pid": 42, "start": "k:1",
			"socketIdentity": "dev:ino", "transport": "native_peer_socket"}}
}

func saveAssistantLink(t *testing.T, root, here, target string) {
	t.Helper()
	id, _, err := communicationPair(here, target)
	if err != nil {
		t.Fatal(err)
	}
	link := communicationLink{Version: 1, ID: id, Members: []communicationMember{{PaneID: here}, {PaneID: target, SessionID: "s-1", Provider: "claude"}}}
	if err := communicationAtomic(filepath.Join(root, "link-"+id+".json"), link); err != nil {
		t.Fatal(err)
	}
}

// Re-review fixture (v1): generic registration/import cannot create Miko.
func TestAssistantReservedIDCannotBeRegisteredOrImported(t *testing.T) {
	root, here, target, sent, native := assistantFixture(t)
	if err := communicationAtomic(communicationPolicyPath(root), communicationPolicy{}); err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256([]byte("independent-process-token"))
	for _, op := range []string{"caller_register", "caller_policy_import"} {
		r := CommunicationRequest{Operation: op, Policy: &communicationPolicy{Callers: []communicationCaller{{
			ID: communicationAssistantCallerID, Label: "unrelated process", TokenHash: hex.EncodeToString(hash[:])}}}}
		if _, err := communicationPolicyAdmin(root, r); err == nil || !strings.Contains(err.Error(), "reserved") {
			t.Fatalf("%s allowed the reserved ID: %v", op, err)
		}
	}
	// A pane or caller credential can never send as Miko.
	saveAssistantLink(t, root, here, target)
	for _, mutate := range []func(*CommunicationRequest){
		func(r *CommunicationRequest) { r.ClientToken = "independent-process-token" },
		func(r *CommunicationRequest) { r.ActorPaneID = target },
	} {
		r := assistantRequest(here, target)
		mutate(&r)
		if _, err := communicationAssistantSend(root, "node", r, native); err == nil {
			t.Fatal("a pane or caller credential sent as Miko")
		}
	}
	if len(*sent) != 0 {
		t.Fatal("a refused request reached native delivery")
	}
}

// Re-review fixture (v2, first-use key spoof): an unrelated owner-level
// process gets no app or Run claim, no key pinning exists, and with no saved
// pair on this host nothing is sent at all.
func TestAssistantOwnerRequestsCarryNoAppOrRunClaim(t *testing.T) {
	root, here, target, sent, native := assistantFixture(t)
	for _, file := range []string{"communication.go", "communication_assistant.go", "communication_policy.go"} {
		source, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(source), "assistant_key_pin") || strings.Contains(string(source), "AssistantPublicKey") {
			t.Fatalf("first-use key pinning still exists in %s", file)
		}
	}
	if _, err := communicationAssistantSend(root, "node", assistantRequest(here, target), native); err == nil ||
		!strings.HasPrefix(err.Error(), "needs_link") {
		t.Fatalf("a send without a pair saved on this host was not refused: %v", err)
	}
	if len(*sent) != 0 {
		t.Fatal("an unlinked request reached native delivery")
	}
	saveAssistantLink(t, root, here, target)
	result, err := communicationAssistantSend(root, "node", assistantRequest(here, target), native)
	if err != nil || len(*sent) != 1 {
		t.Fatal(err)
	}
	source := (*sent)[0]["source"].(map[string]any)
	for _, claim := range []string{"approval", "keyFingerprint", "paneID", "sessionID"} {
		if source[claim] != nil {
			t.Fatalf("the source makes an unverifiable claim %q: %v", claim, source)
		}
	}
	if source["authentication"] != "relay_assistant_owner_submitted" || result["source_authentication"] != "relay_assistant_owner_submitted" {
		t.Fatalf("provenance wrong: %v %v", source, result)
	}
	for _, forbidden := range []string{"relay_app_signed", "relay_app_assistant_attested", "kernel_verified", "source_host_attested"} {
		if result["source_authentication"] == forbidden {
			t.Fatalf("provenance overclaims: %s", forbidden)
		}
	}
}

func TestAssistantSendFollowsTheLinkRuleAndRecipientBinding(t *testing.T) {
	root, here, target, sent, native := assistantFixture(t)
	saveAssistantLink(t, root, here, target)
	changed := assistantRequest(here, target)
	changed.ExpectedRecipient["pid"] = 43
	if _, err := communicationAssistantSend(root, "node", changed, native); err == nil || !strings.HasPrefix(err.Error(), "recipient_changed") {
		t.Fatalf("changed recipient was not refused: %v", err)
	}
	if len(*sent) != 0 {
		t.Fatal("a refused request reached native delivery")
	}
}

func TestAssistantSendUsesTheMessageSystemOnce(t *testing.T) {
	root, here, target, sent, native := assistantFixture(t)
	saveAssistantLink(t, root, here, target)
	request := assistantRequest(here, target)
	first, err := communicationAssistantSend(root, "node", request, native)
	if err != nil {
		t.Fatal(err)
	}
	second, err := communicationAssistantSend(root, "node", request, native)
	if err != nil || len(*sent) != 1 || second["status"] != first["status"] {
		t.Fatalf("message was replayed or not idempotent: %v %d", err, len(*sent))
	}
	if first["status"] != "written_to_socket" || first["link_authority"] != "relayd_node_pair" {
		t.Fatalf("receipt wrong: %v", first)
	}
	conflict := request
	conflict.Text = "different"
	if _, err := communicationAssistantSend(root, "node", conflict, native); err == nil {
		t.Fatal("a different message reused the same ID")
	}
}

// Cross-host: the user's pane is on another host; the pair is checked on
// this host from its saved cross-host record, never from a signer's claim.
func TestAssistantCrossHostPairIsCheckedOnThisHost(t *testing.T) {
	root, _, target, sent, native := assistantFixture(t)
	macPane := "44444444-4444-4444-8444-444444444444"
	if _, err := communicationAssistantSend(root, "node", assistantRequest(macPane, target), native); err == nil ||
		!strings.HasPrefix(err.Error(), "needs_link") {
		t.Fatalf("an unsaved cross-host pair was accepted: %v", err)
	}
	link := communicationAssistantLink{Version: 1, HerePaneID: macPane, HereHost: "This Mac", PaneID: target,
		Provider: "claude", SessionID: "s-1", SavedAt: time.Now().UTC()}
	if err := communicationAtomic(communicationAssistantLinkPath(root, macPane, target), link); err != nil {
		t.Fatal(err)
	}
	result, err := communicationAssistantSend(root, "node", assistantRequest(macPane, target), native)
	if err != nil || len(*sent) != 1 || result["link_authority"] != "relayd_cross_host_pair" {
		t.Fatalf("saved cross-host pair failed: %v %v", err, result)
	}
}

func sendForReplies(t *testing.T) (string, string, CommunicationRequest, communicationGroupNative) {
	root, here, target, _, native := assistantFixture(t)
	saveAssistantLink(t, root, here, target)
	request := assistantRequest(here, target)
	if _, err := communicationAssistantSend(root, "node", request, native); err != nil {
		t.Fatal(err)
	}
	return root, target, request, native
}

// Re-review fixture: a mention without the exact receipt line is not a read.
func TestAssistantMentionWithoutReadReceiptIsNotRead(t *testing.T) {
	root, target, request, native := sendForReplies(t)
	reply := CommunicationRequest{Operation: "send", SourcePaneID: target, ActorPaneID: target, actorVerified: true,
		PaneID: communicationAssistantInboxID, MessageID: "55555555-5555-4555-8555-555555555555",
		Text: "I have not read message " + request.MessageID + ". Please provide its context.\n> Relay-Read-Receipt: " + request.MessageID}
	if _, err := communicationAssistantReply(root, "node", reply, "caller", native); err != nil {
		t.Fatal(err)
	}
	var original communicationReceipt
	if err := communicationRead(filepath.Join(root, "message-"+request.MessageID+".json"), &original); err != nil {
		t.Fatal(err)
	}
	if original.Result["read_acknowledged"] == true {
		t.Fatal("a mention or quote was treated as a read receipt")
	}
	ack := reply
	ack.MessageID, ack.Text = "77777777-7777-4777-8777-777777777777", "Done.\nRelay-Read-Receipt: "+request.MessageID
	if _, err := communicationAssistantReply(root, "node", ack, "caller", native); err != nil {
		t.Fatal(err)
	}
	_ = communicationRead(filepath.Join(root, "message-"+request.MessageID+".json"), &original)
	if original.Result["read_acknowledged"] != true {
		t.Fatal("an exact Relay-Read-Receipt line did not acknowledge")
	}
}

// Re-review fixture: a replacement conversation in the same pane cannot reply
// or acknowledge the original recipient's message.
func TestAssistantReplacementSessionCannotReplyOrAcknowledge(t *testing.T) {
	root, target, request, native := sendForReplies(t)
	native.observe = func(pane string) communicationMember {
		return communicationMember{PaneID: pane, Provider: "codex", SessionID: "unrelated-new-session", PID: 99, Start: "k:9"}
	}
	reply := CommunicationRequest{Operation: "send", SourcePaneID: target, ActorPaneID: target, actorVerified: true,
		PaneID: communicationAssistantInboxID, MessageID: "66666666-6666-4666-8666-666666666666",
		Text: "Relay-Read-Receipt: " + request.MessageID}
	if _, err := communicationAssistantReply(root, "node", reply, "caller", native); err == nil {
		t.Fatal("a replacement conversation was admitted to Miko's inbox")
	}
	var original communicationReceipt
	if communicationRead(filepath.Join(root, "message-"+request.MessageID+".json"), &original) != nil || original.Result["read_acknowledged"] == true {
		t.Fatal("a replacement conversation acknowledged the original message")
	}
	unverified := reply
	unverified.actorVerified = false
	if _, err := communicationAssistantReply(root, "node", unverified, "caller", native); err == nil {
		t.Fatal("an unverified reply was accepted")
	}
}

func TestAssistantInboxIsOwnerOnly(t *testing.T) {
	root, target, _, _ := sendForReplies(t)
	if _, err := communicationAssistantInbox(root, CommunicationRequest{Operation: "assistant_inbox", ActorPaneID: target}); err == nil {
		t.Fatal("a pane read Miko's inbox")
	}
	if _, err := communicationAssistantInbox(root, CommunicationRequest{Operation: "assistant_inbox"}); err != nil {
		t.Fatal(err)
	}
}
