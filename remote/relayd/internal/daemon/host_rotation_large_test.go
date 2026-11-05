package daemon

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHostRotationLargeToolLog(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CODEX_HOME", "")
	directory := filepath.Join(home, ".codex", "sessions")
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, "large.jsonl")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if _, err := io.WriteString(file, rotationSourceCodexFixture()); err != nil {
		t.Fatal(err)
	}
	row := "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"output\":\"" + strings.Repeat("x", 1<<20) + "\"}}\n"
	for i := 0; i < 65; i++ {
		if _, err := io.WriteString(file, row); err != nil {
			t.Fatal(err)
		}
	}
	// Native item-completed telemetry may exceed 2 MiB even with small public text.
	largeEvent := `{"type":"event_msg","payload":{"type":"item_completed","output":"` + strings.Repeat("x", 3<<20) + `"}}` + "\n"
	if _, err := io.WriteString(file, largeEvent); err != nil {
		t.Fatal(err)
	}
	info, err := file.Stat()
	if err != nil {
		t.Fatal(err)
	}
	binding := AgentBindingRecord{Version: 1, SessionID: "fixture-session", TranscriptPath: path, Revision: strings.Repeat("a", 64)}
	binding.Producer.Provider = "codex"
	candidate, err := readHostRotationNativeDirectory(context.Background(), binding)
	if err != nil || candidate.CWD != "/fixture" {
		t.Fatalf("large directory discovery failed: %v", err)
	}
	enrollment := hostRotationEnrollment{Client: "codex", SessionID: "fixture-session", CWD: "/fixture"}
	boundary := hostRotationSourceBoundary{TurnSeq: 3, TranscriptMtimeMS: info.ModTime().UnixMilli(), TranscriptBytes: info.Size()}
	source, err := readHostRotationSource(context.Background(), enrollment, boundary, binding)
	if err != nil {
		t.Fatal(err)
	}
	if source.Messages != 2 || len(source.Chunks) != 1 || len(source.TranscriptSHA256) != 64 {
		t.Fatal("tool log leaked or public evidence lost")
	}
	// Reject over-bound files before reading; this sparse file consumes no large buffer.
	if err := file.Truncate(rotationSourceFileLimit + 1); err != nil {
		t.Fatal(err)
	}
	if _, err := readHostRotationNativeDirectory(context.Background(), binding); err == nil {
		t.Fatal("accepted oversized discovery")
	}
	info, _ = file.Stat()
	boundary.TranscriptBytes = info.Size()
	boundary.TranscriptMtimeMS = info.ModTime().UnixMilli()
	if _, err := readHostRotationSource(context.Background(), enrollment, boundary, binding); err == nil {
		t.Fatal("accepted oversized source")
	}
}

func TestHostRotationSelectedLiveTranscript(t *testing.T) {
	path := os.Getenv("RELAY_ROTATION_DIAGNOSTIC_PATH")
	if path == "" {
		t.Skip("explicit read-only diagnostic")
	}
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		t.Fatal(err)
	}
	if info.Size() > rotationSourceFileLimit {
		t.Fatal("file bound exceeded")
	}
	session := os.Getenv("RELAY_ROTATION_DIAGNOSTIC_SESSION")
	provider := os.Getenv("RELAY_ROTATION_DIAGNOSTIC_PROVIDER")
	if provider == "" {
		provider = "codex"
	}
	cwd, _, err := parseHostRotationNativeDirectoryEvidence(context.Background(), io.LimitReader(file, info.Size()), provider, session)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = file.Seek(0, 0); err != nil {
		t.Fatal(err)
	}
	messages, err := parseRotationSource(context.Background(), io.LimitReader(file, info.Size()), provider, session, cwd)
	if err != nil {
		t.Fatal(err)
	}
	chunks, _, err := chunkRotationSource(messages)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("read-only source: bytes=%d public_messages=%d chunks=%d", info.Size(), len(messages), len(chunks))
}

func TestHostRotationCitationPreservesPublicWhitespace(t *testing.T) {
	text := "Answer\n\n<oai-mem-citation>metadata</oai-mem-citation>\n"
	if got := rotationCodexVisibleText(text); got != "Answer\n\n\n" {
		t.Fatalf("public whitespace changed: %q", got)
	}
}
