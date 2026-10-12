package agentlaunch

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

func TestVerifiedSnapshotRequiresPrivateExactReusableSettings(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	dir := filepath.Join(home, ".local", "share", "relay", "agent-launches")
	path, err := Save(dir, "claude", "/bin/echo", home, "pane-test", "123", []string{"--model", "haiku"}, []string{"--model", "haiku"})
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(data)
	digest := hex.EncodeToString(hash[:])
	snapshot, err := ReadVerified(path, digest)
	if err != nil || snapshot.Arguments.Fresh[0] != "--model" {
		t.Fatalf("verified read: %v", err)
	}
	if _, err := ReadVerified(path, "0000000000000000000000000000000000000000000000000000000000000000"); err == nil {
		t.Fatal("changed digest accepted")
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadVerified(path, digest); err == nil {
		t.Fatal("public snapshot accepted")
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	path, err = Save(dir, "claude", "/bin/echo", home, "pane-test-2", "123", []string{"--unknown-setting"}, []string{"--unknown-setting"})
	if err != nil {
		t.Fatal(err)
	}
	data, _ = os.ReadFile(path)
	hash = sha256.Sum256(data)
	if _, err := ReadVerified(path, hex.EncodeToString(hash[:])); err == nil {
		t.Fatal("ambiguous argv accepted")
	}
}
