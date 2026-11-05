package daemon

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestWorkCredentialProvisionIsPrivateStableAndConversationBound(t *testing.T) {
	root, _ := peerFixture(t, "node-a")
	got, e := provisionWorkCredential(root, "node-a", testGroupA, "codex", workTestSession)
	if e != nil {
		t.Fatal(e)
	}
	data, _ := json.Marshal(got)
	if bytes.Contains(data, []byte("token")) {
		t.Fatal("credential returned", string(data))
	}
	var c workPaneCredential
	if e = communicationRead(workCredentialPath(root, testGroupA), &c); e != nil {
		t.Fatal(e)
	}
	st, e := os.Stat(workCredentialPath(root, testGroupA))
	if e != nil || st.Mode().Perm() != 0600 {
		t.Fatal("unsafe credential mode", e)
	}
	if len(c.Token) != 43 || c.Caller != got["caller_id"] {
		t.Fatal("invalid saved credential")
	}
	again, e := provisionWorkCredential(root, "node-a", testGroupA, "codex", workTestSession)
	if e != nil || again["caller_id"] != got["caller_id"] {
		t.Fatal("retry changed identity", again, e)
	}
	var next workPaneCredential
	_ = communicationRead(workCredentialPath(root, testGroupA), &next)
	if c != next {
		t.Fatal("retry rotated credential")
	}
	if _, e = provisionWorkCredential(root, "node-a", testGroupA, "codex", workTestThread); e == nil {
		t.Fatal("credential silently rebound to another session")
	}
	hash := sha256.Sum256([]byte(c.Token))
	var policy communicationPolicy
	_ = communicationRead(communicationPolicyPath(root), &policy)
	if len(policy.Callers) != 1 || policy.Callers[0].TokenHash != hex.EncodeToString(hash[:]) {
		t.Fatal("registration missing")
	}
	policy.Callers[0].Paused = true
	_ = communicationAtomic(communicationPolicyPath(root), policy)
	if _, e = provisionWorkCredential(root, "node-a", testGroupA, "codex", workTestSession); e != nil {
		t.Fatal(e)
	}
	if _, e = communicationAuthorize(root, CommunicationRequest{Operation: "remote_send", ActorPaneID: testGroupA, SourcePaneID: testGroupA, ClientToken: c.Token}); e == nil {
		t.Fatal("provisioning cleared caller pause")
	}
}
func TestWorkCredentialRejectsSymlinkAndCannotReadForWorkOrUnknownPane(t *testing.T) {
	root, _ := peerFixture(t, "node-a")
	if _, e := provisionWorkCredential(root, "node-a", "../escape", "codex", workTestSession); e == nil {
		t.Fatal("path injection accepted")
	}
	target := root + "/not-a-credential"
	if e := os.WriteFile(target, []byte(strings.Repeat("x", 32)), 0600); e != nil {
		t.Fatal(e)
	}
	if e := os.Symlink(target, workCredentialPath(root, testGroupA)); e != nil {
		t.Fatal(e)
	}
	if _, e := provisionWorkCredential(root, "node-a", testGroupA, "codex", workTestSession); e == nil {
		t.Fatal("credential followed symlink")
	}
	if _, e := readWorkCredential(root, "node-a", workRequestOrigin{thread: workTestThread, revalidate: func() error { return nil }}); e == nil {
		t.Fatal("Work caller loaded pane credential")
	}
}
