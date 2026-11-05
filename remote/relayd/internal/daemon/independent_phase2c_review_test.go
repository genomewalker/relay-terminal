package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestIndependentV2OldReservedCallerAttackIsClosed(t *testing.T) {
	root, here, target, sent, native := assistantFixture(t)
	if err := communicationAtomic(communicationPolicyPath(root), communicationPolicy{}); err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256([]byte("independent-process-token"))
	for _, op := range []string{"caller_register", "caller_policy_import"} {
		r := CommunicationRequest{Operation: op, Policy: &communicationPolicy{Callers: []communicationCaller{{ID: communicationAssistantCallerID, Label: "unrelated process", TokenHash: hex.EncodeToString(hash[:])}}}}
		if _, err := communicationPolicyAdmin(root, r); err == nil || !strings.Contains(err.Error(), "reserved") {
			t.Fatalf("%s allowed reserved ID: %v", op, err)
		}
	}
	r := assistantRequest(here, target)
	if _, err := communicationAssistantSend(root, "node", r, native); err == nil || len(*sent) != 0 {
		t.Fatalf("unsigned request sent: %v", err)
	}
	t.Log("CLOSED: generic registration/import and unsigned sends cannot claim Miko")
}

// Root's v2 spoof probe, adapted: an unrelated same-owner process can no
// longer pin a key, claim the app or a Run decision, or send without a pair
// saved on this host.
func TestIndependentV2TOFUSpoofNoLongerReproduces(t *testing.T) {
	root, here, target, sent, native := assistantFixture(t)
	if err := communicationAtomic(communicationPolicyPath(root), communicationPolicy{}); err != nil {
		t.Fatal(err)
	}
	r := assistantRequest(here, target)
	r, err := ReconcileCommunicationActor(r, os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := communicationAuthorize(root, r); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationAssistantSend(root, "node", r, native); err == nil || !strings.HasPrefix(err.Error(), "needs_link") || len(*sent) != 0 {
		t.Fatalf("spoof reproduced without a host-saved pair: %v", err)
	}
	saveAssistantLink(t, root, here, target)
	result, err := communicationAssistantSend(root, "node", r, native)
	if err != nil || len(*sent) != 1 {
		t.Fatal(err)
	}
	source := (*sent)[0]["source"].(map[string]any)
	if source["approval"] != nil || source["keyFingerprint"] != nil || result["source_authentication"] != "relay_assistant_owner_submitted" {
		t.Fatalf("an owner-level request still carries an app/Run claim: %v %v", source, result)
	}
	t.Log("CLOSED: no key pinning; owner-level sends need a host-saved pair and carry no app or Run claim")
}

func TestIndependentV2MentionWithoutReadReceiptStaysUnread(t *testing.T) {
	root, target, request, native := sendForReplies(t)
	reply := CommunicationRequest{Operation: "send", SourcePaneID: target, ActorPaneID: target, actorVerified: true, PaneID: communicationAssistantInboxID, MessageID: "55555555-5555-4555-8555-555555555555", Text: "I have not read message " + request.MessageID + ". Please provide its context."}
	if _, err := communicationAssistantReply(root, "node", reply, "caller", native); err != nil {
		t.Fatal(err)
	}
	var original communicationReceipt
	if err := communicationRead(filepath.Join(root, "message-"+request.MessageID+".json"), &original); err != nil {
		t.Fatal(err)
	}
	if original.Result["read_acknowledged"] == true {
		t.Fatal("ID mention still marks read")
	}
	t.Log("CLOSED: negative mention without exact receipt line remains unread")
}

func TestIndependentV2ReplacementSessionIsRefused(t *testing.T) {
	root, target, request, native := sendForReplies(t)
	native.observe = func(pane string) communicationMember {
		return communicationMember{PaneID: pane, Provider: "codex", SessionID: "unrelated-new-session", PID: 99, Start: "k:9"}
	}
	reply := CommunicationRequest{Operation: "send", SourcePaneID: target, ActorPaneID: target, actorVerified: true, PaneID: communicationAssistantInboxID, MessageID: "66666666-6666-4666-8666-666666666666", Text: "Relay-Read-Receipt: " + request.MessageID}
	if _, err := communicationAssistantReply(root, "node", reply, "caller", native); err == nil || !strings.Contains(err.Error(), "not the one") {
		t.Fatalf("replacement session accepted: %v", err)
	}
	var original communicationReceipt
	if err := communicationRead(filepath.Join(root, "message-"+request.MessageID+".json"), &original); err != nil {
		t.Fatal(err)
	}
	if original.Result["read_acknowledged"] == true {
		t.Fatal("replacement session marked original read")
	}
	t.Log("CLOSED: replacement conversation cannot reply or acknowledge old message")
}
