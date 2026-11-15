package daemon

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"
)

const compressedThread = "01a197e5-2c34-7582-8f60-f43f3dac9335"

func compressedRolloutRows() []any {
	return []any{
		pyObj("type", "session_meta", "payload", pyObj("id", compressedThread, "cwd", "/w")),
		pyObj("type", "turn_context", "payload", pyObj("model", "gpt-rosalind-astra")),
		pyObj("type", "event_msg", "state", "quiet", "payload", pyObj("type", "task_complete")),
	}
}

func writeCompressed[T string | []byte](t *testing.T, path string, content T) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	var encoded bytes.Buffer
	writer, err := zstd.NewWriter(&encoded)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write([]byte(content)); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, encoded.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	stamp := time.Now().Add(-48 * time.Hour)
	if err := os.Chtimes(path, stamp, stamp); err != nil {
		t.Fatal(err)
	}
	return path
}

func syntheticLifecycleReader() *phReader {
	r := newPHReader(context.Background())
	r.codexLifecycle = func(row any) *pyList {
		if state := phGet(row, "state", nil); state != nil {
			return pyListOf(state, "time")
		}
		return nil
	}
	return r
}

// Codex 0.169 compresses an idle thread's rollout to .jsonl.zst while the
// pane keeps the thread loaded. Account moves and same-pane restarts on
// dandy-07 refused every such pane with "An exact saved conversation is
// required for restart." because only the plain .jsonl name was matched.
func TestExactCodexTranscriptFindsCompressedRollout(t *testing.T) {
	root := t.TempDir()
	path := writeCompressed(t, filepath.Join(root, "sessions", "2026", "11", "01",
		"rollout-2026-11-01T17-15-41-"+compressedThread+".jsonl.zst"), mrJSONLines(compressedRolloutRows()...))
	r := syntheticLifecycleReader()
	if got := r.exactCodexTranscript(compressedThread, root); got != path {
		t.Fatalf("exact transcript = %q, want %q", got, path)
	}
	if got := r.metadata(path, "codex"); got != compressedThread {
		t.Fatalf("metadata = %v", got)
	}
	lifecycle, context, revision := r.tailEvidence(path, "codex")
	if lifecycle != "quiet" || revision == "" {
		t.Fatalf("tail evidence = %q %q", lifecycle, revision)
	}
	if model := phGet(context, "model", nil); model != "gpt-rosalind-astra" {
		t.Fatalf("turn context = %v", context)
	}
}

func TestExactCodexTranscriptPrefersPlainTwin(t *testing.T) {
	root := t.TempDir()
	directory := filepath.Join(root, "sessions", "2026", "11", "01")
	name := "rollout-2026-11-01T17-15-41-" + compressedThread + ".jsonl"
	writeCompressed(t, filepath.Join(directory, name+".zst"), mrJSONLines(compressedRolloutRows()...))
	plain := phWrite(t, filepath.Join(directory, name), mrJSONLines(compressedRolloutRows()...), 0600)
	if got := syntheticLifecycleReader().exactCodexTranscript(compressedThread, root); got != plain {
		t.Fatalf("exact transcript = %q, want the plain twin %q", got, plain)
	}
}

func TestCompressedRolloutWrongThreadStillRefused(t *testing.T) {
	root := t.TempDir()
	rows := compressedRolloutRows()
	rows[0] = pyObj("type", "session_meta", "payload", pyObj("id", "01a197e5-0000-7000-8000-000000000000"))
	writeCompressed(t, filepath.Join(root, "sessions", "2026", "11", "01",
		"rollout-2026-11-01T17-15-41-"+compressedThread+".jsonl.zst"), mrJSONLines(rows...))
	if raised := phRaised(t, func() { syntheticLifecycleReader().exactCodexTranscript(compressedThread, root) }); raised == nil {
		t.Fatal("a compressed rollout whose metadata names another thread was accepted")
	}
}

func TestAccountTranscriptCheckAcceptsCompressedCodexRollout(t *testing.T) {
	root := t.TempDir()
	path := writeCompressed(t, filepath.Join(root, "sessions", "2026", "11", "01",
		"rollout-2026-11-01T17-15-41-"+compressedThread+".jsonl.zst"), mrJSONLines(compressedRolloutRows()...))
	if err := ValidateAccountTranscript(path, "codex", root); err != nil {
		t.Fatalf("move check refused a compressed rollout: %v", err)
	}
	// Readers that parse JSONL stay strict.
	if err := validateAccountTranscript(path, "codex", root); err == nil {
		t.Fatal("binding validation accepted a compressed rollout")
	}
	outside := writeCompressed(t, filepath.Join(root, "elsewhere", "rollout-x-"+compressedThread+".jsonl.zst"), []byte("{}\n"))
	if err := ValidateAccountTranscript(outside, "codex", root); err == nil {
		t.Fatal("move check accepted a compressed rollout outside sessions")
	}
	if err := ValidateAccountTranscript(path, "claude", root); err == nil {
		t.Fatal("move check accepted a compressed Claude transcript")
	}
}

func TestDecodedTailStartsAtLineBoundary(t *testing.T) {
	path := writeCompressed(t, filepath.Join(t.TempDir(), "r.jsonl.zst"), []byte("aaaaaaaaaa\nbbbbbbbbbb\ncccccccccc\n"))
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if got := string(phDecodedTail(file, path, 15)); got != "cccccccccc\n" {
		t.Fatalf("tail = %q", got)
	}
}
