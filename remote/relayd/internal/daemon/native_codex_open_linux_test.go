//go:build linux

package daemon

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLinuxOpenCodexTranscriptIdentityAndAmbiguity(t *testing.T) {
	root := filepath.Join(t.TempDir(), ".codex", "sessions")
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "rollout.jsonl")
	first, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	row := `{"type":"session_meta","payload":{"id":"01a10251-94a1-7d91-acc4-34493b16342b"}}` + "\n"
	if _, err = first.WriteString(row); err != nil {
		t.Fatal(err)
	}
	got, session, identity, err := linuxOpenCodexTranscript(os.Getpid())
	if err != nil || got != path || session != "01a10251-94a1-7d91-acc4-34493b16342b" {
		t.Fatalf("initial %q %q %v", got, session, err)
	}
	if _, err = first.WriteString(`{"type":"event_msg"}` + "\n"); err != nil {
		t.Fatal(err)
	}
	_, _, after, err := linuxOpenCodexTranscript(os.Getpid())
	if err != nil || after != identity {
		t.Fatalf("append changed identity: %q %q %v", identity, after, err)
	}
	second, err := os.OpenFile(filepath.Join(root, "second.jsonl"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = second.WriteString(row); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err = linuxOpenCodexTranscript(os.Getpid()); err == nil {
		t.Fatal("multiple open transcripts accepted")
	}
	second.Close()
	if _, _, _, err = linuxOpenCodexTranscript(os.Getpid()); err != nil {
		t.Fatal(err)
	}
	if err = os.Rename(path, filepath.Join(root, "old")); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(path, []byte(row), 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err = linuxOpenCodexTranscript(os.Getpid()); err == nil {
		t.Fatal("replaced named transcript accepted")
	}
}
