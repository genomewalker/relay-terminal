package daemon

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"os"
	"strings"
	"testing"
	"time"
)

type callerAdminKey struct {
	pub  ed25519.PublicKey
	priv ed25519.PrivateKey
}

func newCallerAdminKey(t *testing.T) callerAdminKey {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return callerAdminKey{pub, priv}
}

// signed returns r with a proof signed by k for the given node and expiry.
func (k callerAdminKey) signed(r CommunicationRequest, node string, expires int64) CommunicationRequest {
	nonce := make([]byte, 16)
	_, _ = rand.Read(nonce)
	p := communicationAdminProof{PublicKey: base64.StdEncoding.EncodeToString(k.pub),
		Nonce: base64.StdEncoding.EncodeToString(nonce), Expires: expires}
	sig := ed25519.Sign(k.priv, communicationCallerAdminMessage(node, r, p))
	p.Signature = base64.StdEncoding.EncodeToString(sig)
	r.AdminProof = &p
	return r
}

func callerAdminPolicy(id string) *communicationPolicy {
	h := sha256.Sum256([]byte("token-" + id))
	return &communicationPolicy{Callers: []communicationCaller{{ID: id, Label: "fixture " + id, TokenHash: hex.EncodeToString(h[:])}}}
}

func callerAdminFixture(t *testing.T) (key callerAdminKey, node string) {
	t.Helper()
	communicationLockHome(t)
	node, _ = currentNodeIdentity()
	return newCallerAdminKey(t), node
}

func listCallers(t *testing.T) map[string]any {
	t.Helper()
	res, err := ExecuteCommunication(CommunicationRequest{Operation: "caller_list"})
	if err != nil {
		t.Fatalf("caller_list: %v", err)
	}
	return res
}

func TestCallerAdminMutationsRefusedWithoutProof(t *testing.T) {
	_, _ = callerAdminFixture(t)
	paused := true
	for _, r := range []CommunicationRequest{
		{Operation: "caller_policy_import", Policy: callerAdminPolicy("fence-a")},
		{Operation: "caller_register", Policy: callerAdminPolicy("fence-b")},
		{Operation: "caller_set_paused", CallerID: "legacy-unattributed", Paused: &paused},
		{Operation: "caller_unknown_future_op"},
	} {
		if _, err := ExecuteCommunication(r); err == nil || !strings.Contains(err.Error(), "Relay app proof") {
			t.Fatalf("%s without proof: %v", r.Operation, err)
		}
	}
	requireNoCallerAdminState(t)
}

func TestCallerAdminProofAppliedPinnedAndReplayRefused(t *testing.T) {
	key, node := callerAdminFixture(t)
	exp := time.Now().Add(time.Minute).Unix()
	imp := key.signed(CommunicationRequest{Operation: "caller_policy_import", Policy: callerAdminPolicy("fence-a")}, node, exp)
	if res, err := ExecuteCommunication(imp); err != nil || res["status"] != "imported" {
		t.Fatalf("signed import: %v %v", res, err)
	}
	// Replay of the same proof (same nonce) is refused.
	if _, err := ExecuteCommunication(imp); err == nil || !strings.Contains(err.Error(), "already used") {
		t.Fatalf("replay: %v", err)
	}
	paused := true
	set := key.signed(CommunicationRequest{Operation: "caller_set_paused", CallerID: "legacy-unattributed", Paused: &paused}, node, exp)
	if _, err := ExecuteCommunication(set); err != nil {
		t.Fatalf("signed set_paused: %v", err)
	}
	reg := key.signed(CommunicationRequest{Operation: "caller_register", Policy: callerAdminPolicy("fence-c")}, node, exp)
	if _, err := ExecuteCommunication(reg); err != nil {
		t.Fatalf("signed register: %v", err)
	}
	list := listCallers(t)
	info, err := ExecuteCommunication(CommunicationRequest{Operation: "caller_admin_info"})
	if err != nil || info["node_id"] != node || info["admin_key_sha256"] != communicationCallerAdminFingerprint(base64.StdEncoding.EncodeToString(key.pub)) {
		t.Fatalf("caller_admin_info does not report node and pinned key: %v %v", info, err)
	}
	if len(list["callers"].([]map[string]any)) != 3 || list["callers"].([]map[string]any)[0]["paused"] != true {
		t.Fatalf("applied state wrong: %v", list)
	}
}

func TestCallerAdminProofBoundToArgumentsNodeOperationAndKey(t *testing.T) {
	key, node := callerAdminFixture(t)
	exp := time.Now().Add(time.Minute).Unix()
	if _, err := ExecuteCommunication(key.signed(CommunicationRequest{Operation: "caller_policy_import", Policy: callerAdminPolicy("fence-a")}, node, exp)); err != nil {
		t.Fatal(err)
	}
	f, tr := false, true
	// Proof for paused=false cannot be used to pause.
	p := key.signed(CommunicationRequest{Operation: "caller_set_paused", CallerID: "legacy-unattributed", Paused: &f}, node, exp)
	p.Paused = &tr
	// Proof for another operation / another node / another policy.
	other := key.signed(CommunicationRequest{Operation: "caller_register", Policy: callerAdminPolicy("fence-b")}, node, exp)
	other.Operation = "caller_policy_import"
	elsewhere := key.signed(CommunicationRequest{Operation: "caller_register", Policy: callerAdminPolicy("fence-b")}, "0000000000000000", exp)
	swapped := key.signed(CommunicationRequest{Operation: "caller_register", Policy: callerAdminPolicy("fence-b")}, node, exp)
	swapped.Policy = callerAdminPolicy("fence-evil")
	// A different key is refused once a key is pinned.
	wrong := newCallerAdminKey(t).signed(CommunicationRequest{Operation: "caller_set_paused", CallerID: "legacy-unattributed", Paused: &tr}, node, exp)
	for name, r := range map[string]CommunicationRequest{"arguments": p, "operation": other, "node": elsewhere, "policy": swapped, "wrong key": wrong} {
		if _, err := ExecuteCommunication(r); err == nil {
			t.Fatalf("%s: tampered or foreign proof accepted", name)
		}
	}
	if _, err := ExecuteCommunication(wrong); err == nil || !strings.Contains(err.Error(), "does not match") {
		t.Fatalf("wrong key reports %v", err)
	}
	if got := listCallers(t)["callers"].([]map[string]any); len(got) != 2 || got[0]["paused"] != false {
		t.Fatalf("a refused proof changed policy: %v", got)
	}
	// A validly signed proof from a second key is refused on pin mismatch.
	k2 := newCallerAdminKey(t)
	k2req := CommunicationRequest{Operation: "caller_set_paused", CallerID: "legacy-unattributed", Paused: &tr}
	if _, err := ExecuteCommunication(k2.signed(k2req, node, exp)); err == nil || !strings.Contains(err.Error(), "pinned") {
		t.Fatalf("second key not refused as unpinned: %v", err)
	}
}

func TestCallerAdminExpiredAndOverlongProofsRefused(t *testing.T) {
	key, node := callerAdminFixture(t)
	r := CommunicationRequest{Operation: "caller_policy_import", Policy: callerAdminPolicy("fence-a")}
	if _, err := ExecuteCommunication(key.signed(r, node, time.Now().Add(-time.Second).Unix())); err == nil || !strings.Contains(err.Error(), "expired") {
		t.Fatalf("expired: %v", err)
	}
	if _, err := ExecuteCommunication(key.signed(r, node, time.Now().Add(time.Hour).Unix())); err == nil || !strings.Contains(err.Error(), "too long") {
		t.Fatalf("overlong: %v", err)
	}
	requireNoCallerAdminState(t)
}

func TestCallerAdminNonceExpiryAllowsPruningAndCapBounds(t *testing.T) {
	key, node := callerAdminFixture(t)
	root := communicationRoot()
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	r := CommunicationRequest{Operation: "caller_policy_import", Policy: callerAdminPolicy("fence-a")}
	first := key.signed(r, node, now.Add(time.Minute).Unix())
	if err := communicationCallerAdminVerify(root, node, first, now); err != nil {
		t.Fatal(err)
	}
	// After the proof expires its nonce is pruned from the store, not kept forever.
	later := now.Add(2 * time.Minute)
	if err := communicationCallerAdminVerify(root, node, key.signed(r, node, later.Add(time.Minute).Unix()), later); err != nil {
		t.Fatal(err)
	}
	var st communicationAdminState
	if err := communicationRead(communicationCallerAdminPath(root), &st); err != nil || len(st.Nonces) != 1 {
		t.Fatalf("nonce store not pruned: %v %v", st, err)
	}
	for i := len(st.Nonces); i < communicationCallerAdminNonces; i++ {
		st.Nonces = append(st.Nonces, communicationAdminNonce{Nonce: base64.StdEncoding.EncodeToString([]byte{byte(i), byte(i >> 8)}), Expires: later.Add(time.Minute).Unix()})
	}
	if err := communicationAtomic(communicationCallerAdminPath(root), st); err != nil {
		t.Fatal(err)
	}
	if err := communicationCallerAdminVerify(root, node, key.signed(r, node, later.Add(time.Minute).Unix()), later); err == nil || !strings.Contains(err.Error(), "too many") {
		t.Fatalf("full nonce store: %v", err)
	}
}

func TestCallerAdminProviderCredentialStillRefused(t *testing.T) {
	key, node := callerAdminFixture(t)
	r := key.signed(CommunicationRequest{Operation: "caller_policy_import", Policy: callerAdminPolicy("fence-a"), ClientToken: "x"}, node, time.Now().Add(time.Minute).Unix())
	if _, err := ExecuteCommunication(r); err == nil || !strings.Contains(err.Error(), "owner administration required") {
		t.Fatalf("provider token with a proof: %v", err)
	}
}

// A refused request neither pins a key nor creates a policy.
func requireNoCallerAdminState(t *testing.T) {
	t.Helper()
	for _, p := range []string{communicationCallerAdminPath(communicationRoot()), communicationPolicyPath(communicationRoot())} {
		if _, err := os.Lstat(p); !os.IsNotExist(err) {
			t.Fatalf("%s exists after refused requests (%v)", p, err)
		}
	}
}

// Vectors produced by Sources/Relay/RelayCallerAdminProof.swift (Swift test
// RelayCallerAdminProofTests): both sides must build identical bytes.
func TestCallerAdminSwiftVectors(t *testing.T) {
	th := "t"
	imp := CommunicationRequest{Operation: "caller_policy_import", Policy: &communicationPolicy{LegacyPaused: true, Callers: []communicationCaller{
		{ID: "ABC-1", Label: "L", Thread: &th, TokenHash: "ff"}, {ID: "x", Label: "M", TokenHash: "aa", Paused: true}}}}
	if got, want := communicationCallerAdminArguments(imp), "0:1:-1:11:25:abc-11:L2:+t2:ff1:01:x1:M1:-2:aa1:1"; got != want {
		t.Fatalf("arguments %q != %q", got, want)
	}
	paused := true
	set := CommunicationRequest{Operation: "caller_set_paused", CallerID: "Legacy-Unattributed", Paused: &paused}
	pub, _ := base64.StdEncoding.DecodeString("6kpsY+KcUgq+9VB7Ey7F+ZVHdq6+vnuSQh7qaRRG0iw=")
	sig, _ := base64.StdEncoding.DecodeString("niQvvEc3Kz8li7A0c2cmzBThkb4EicJVaQ7FE8mAbGmA1/VaO8+4sztNNbDW0XxGtyDaVhpncTbEgQzem5QpBw==")
	p := communicationAdminProof{Nonce: "AQEBAQEBAQEBAQEBAQEBAQ==", Expires: 1120}
	if !ed25519.Verify(pub, communicationCallerAdminMessage("n1", set, p), sig) {
		t.Fatal("Swift-signed proof does not verify against the Go message")
	}
}

func TestCallerAdminRefusesEmptyNodeIdentity(t *testing.T) {
	key, node := callerAdminFixture(t)
	r := key.signed(CommunicationRequest{Operation: "caller_policy_import", Policy: callerAdminPolicy("fence-a")}, "", time.Now().Add(time.Minute).Unix())
	if err := communicationCallerAdminVerify(communicationRoot(), "", r, time.Now()); err == nil || !strings.Contains(err.Error(), "node identity unknown") {
		t.Fatalf("empty node accepted: %v", err)
	}
	if node == "" {
		t.Fatal("fixture node identity is empty")
	}
	requireNoCallerAdminState(t)
}
