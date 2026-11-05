package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"testing"
)

func TestCommunicationMessageFingerprintBindsTheTargetSession(t *testing.T) {
	// Without a target the identity is byte-identical to existing receipts.
	encoded, _ := json.Marshal(struct{ Source, Target, Message, Text string }{"src", "dst", "id", "text"})
	hash := sha256.Sum256(encoded)
	if communicationMessageFingerprint("src", "dst", "id", "text", "") != hex.EncodeToString(hash[:]) {
		t.Fatal("untargeted message identity changed")
	}
	live := communicationMessageFingerprint("src", "dst", "id", "text", "5577ee9d-5e02-4ca8-b208-74360e3f65d1")
	if live == hex.EncodeToString(hash[:]) ||
		live == communicationMessageFingerprint("src", "dst", "id", "text", "2aea736a-0000-4000-8000-000000000000") {
		t.Fatal("re-aiming the same message ID is not detected")
	}
}
