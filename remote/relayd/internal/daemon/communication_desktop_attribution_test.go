package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"testing"
)

// The desktop brokers same-host sends for MCP clients that predate the daemon
// backend. It forwards the caller's credential, which relayd checks itself; a
// forwarded client_id is a claim and never names the submitting client.
func TestCommunicationDesktopForwardedCredentialAttributesCaller(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	const caller = "19b4d8fd-5ab0-4c72-bc5a-4da265142250"
	token := "desktop-forwarded-token"
	hash := sha256.Sum256([]byte(token))
	policy := communicationPolicy{Callers: []communicationCaller{{ID: caller, Label: "fixture", TokenHash: hex.EncodeToString(hash[:])}}}
	if err := communicationAtomic(communicationPolicyPath(root), policy); err != nil {
		t.Fatal(err)
	}
	send := CommunicationRequest{Operation: "send", SourcePaneID: testGroupA, PaneID: testGroupB}

	withToken := send
	withToken.ClientToken = token
	if id, err := communicationAuthorize(root, withToken); err != nil || id != caller {
		t.Fatalf("forwarded credential = %q, %v; want %s", id, err, caller)
	}
	claimed := send
	claimed.ClientID = caller
	if id, err := communicationAuthorize(root, claimed); err != nil || id != "legacy-unattributed" {
		t.Fatalf("forwarded client_id = %q, %v; want legacy-unattributed", id, err)
	}
	forged := send
	forged.ClientToken = "not-registered"
	if _, err := communicationAuthorize(root, forged); err == nil {
		t.Fatal("an unregistered credential was attributed")
	}
	// Attribution never verifies the sender: with no kernel actor the source stays claimed.
	if communicationSourceVerified(withToken) {
		t.Fatal("a caller credential verified the sending pane")
	}
	policy.Callers[0].Paused = true
	if err := communicationAtomic(communicationPolicyPath(root), policy); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationAuthorize(root, withToken); err == nil {
		t.Fatal("a paused caller sent through the desktop")
	}
}
