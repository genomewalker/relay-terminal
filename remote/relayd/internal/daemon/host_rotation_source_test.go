package daemon

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func rotationSourceCodexFixture() string {
	return strings.Join([]string{
		`{"type":"session_meta","payload":{"id":"fixture-session","cwd":"/fixture","source":"cli"}}`,
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Keep the original pane."},{"type":"input_image","image_url":"PRIVATE_IMAGE"}]}}`,
		`{"type":"response_item","payload":{"type":"message","role":"assistant","channel":"analysis","content":[{"type":"output_text","text":"PRIVATE_REASONING"}]}}`,
		`{"type":"response_item","payload":{"type":"reasoning","summary":[{"text":"PRIVATE_SUMMARY"}]}}`,
		`{"type":"response_item","payload":{"type":"function_call_output","output":"PRIVATE_TOOL"}}`,
		`{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"PRIVATE_CONFIG"}]}}`,
		`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"UNKNOWN_CHANNEL"}]}}`,
		`{"type":"response_item","payload":{"type":"message","role":"assistant","channel":"final","content":[{"type":"output_text","text":"Preserved the pane."}]}}`,
	}, "\n") + "\n"
}

func TestHostRotationSourceSelectsOnlyPublicCodexMessages(t *testing.T) {
	messages, err := parseRotationSource(context.Background(), strings.NewReader(rotationSourceCodexFixture()), "codex", "fixture-session", "/fixture")
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 2 || messages[0].Text != "Keep the original pane." || messages[1].Text != "Preserved the pane." {
		t.Fatalf("unexpected public selection: %#v", messages)
	}
}

func rotationClaudeFixtureRow(kind, id, parent, text string, extra map[string]any) string {
	var parentValue any
	if parent != "" {
		parentValue = parent
	}
	row := map[string]any{"type": kind, "sessionId": "fixture-session", "cwd": "/fixture", "uuid": id, "parentUuid": parentValue,
		"message": map[string]any{"role": kind, "content": []any{map[string]any{"type": "text", "text": text},
			map[string]any{"type": "thinking", "thinking": "PRIVATE_REASONING"},
			map[string]any{"type": "tool_result", "content": "PRIVATE_TOOL"}}}}
	for k, v := range extra {
		row[k] = v
	}
	data, _ := json.Marshal(row)
	return string(data) + "\n"
}

func TestHostRotationSourceClaudeFollowsActiveAncestry(t *testing.T) {
	source := rotationClaudeFixtureRow("user", "u", "", "Keep the pane.", nil) +
		rotationClaudeFixtureRow("assistant", "abandoned", "u", "ABANDONED_BRANCH", nil) +
		rotationClaudeFixtureRow("assistant", "a", "u", "Working.", nil) +
		rotationClaudeFixtureRow("user", "meta", "a", "PRIVATE_META", map[string]any{"isMeta": true}) +
		rotationClaudeFixtureRow("assistant", "nested", "", "PRIVATE_SIDECHAIN", map[string]any{"isSidechain": true, "sessionId": "other"}) +
		rotationClaudeFixtureRow("assistant", "done", "meta", "Done.", nil)
	messages, err := parseRotationSource(context.Background(), strings.NewReader(source), "claude", "fixture-session", "/fixture")
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 3 || messages[0].Text != "Keep the pane." || messages[1].Text != "Working." || messages[2].Text != "Done." {
		t.Fatalf("wrong active branch: %#v", messages)
	}
}

func TestHostRotationSourceRejectsAmbiguousOrIncompleteData(t *testing.T) {
	fixture := rotationSourceCodexFixture()
	cases := map[string]string{
		"identity":          strings.Replace(fixture, `"id":"fixture-session"`, `"id":"another"`, 1),
		"cwd":               strings.Replace(fixture, `"cwd":"/fixture"`, `"cwd":"/elsewhere"`, 1),
		"subagent":          strings.Replace(fixture, `"source":"cli"`, `"source":{"subagent":{}}`, 1),
		"duplicate_channel": strings.Replace(fixture, `"channel":"final"`, `"channel":"analysis","channel":"final"`, 1),
		"bad_json":          fixture + "{",
		"rollback":          fixture + `{"type":"event_msg","payload":{"type":"thread_rolled_back"}}`,
		"long_line":         fixture + strings.Repeat(" ", rotationSourceLineLimit+1),
		"invalid_utf8":      fixture + string([]byte{0xff}),
		"missing_identity":  fixture[strings.Index(fixture, "\n")+1:],
	}
	for name, source := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := parseRotationSource(context.Background(), strings.NewReader(source), "codex", "fixture-session", "/fixture"); err == nil {
				t.Fatal("accepted unsafe source")
			}
		})
	}
	claudeCases := map[string]string{
		"missing_parent": rotationClaudeFixtureRow("assistant", "a", "missing", "answer", nil),
		"cycle":          rotationClaudeFixtureRow("user", "u", "a", "request", nil) + rotationClaudeFixtureRow("assistant", "a", "u", "answer", nil),
		"duplicate_uuid": rotationClaudeFixtureRow("user", "u", "", "request", nil) + rotationClaudeFixtureRow("assistant", "u", "", "answer", nil),
		"wrong_session":  rotationClaudeFixtureRow("user", "u", "", "request", map[string]any{"sessionId": "other"}),
	}
	for name, source := range claudeCases {
		t.Run(name, func(t *testing.T) {
			if _, err := parseRotationSource(context.Background(), strings.NewReader(source), "claude", "fixture-session", "/fixture"); err == nil {
				t.Fatal("accepted unsafe ancestry")
			}
		})
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := parseRotationSource(ctx, strings.NewReader(fixture), "codex", "fixture-session", "/fixture"); err == nil {
		t.Fatal("ignored cancellation")
	}
}

func TestHostRotationSourceChunksPreserveEveryByte(t *testing.T) {
	original := strings.Repeat("漢字<&\x01🙂", 21000)
	chunks, digest, err := chunkRotationSource([]rotationSourceMessage{{"user", original}, {"assistant", "done"}})
	if err != nil {
		t.Fatal(err)
	}
	if len(chunks) < 2 || len(digest) != 64 {
		t.Fatal("expected multiple bound chunks and digest")
	}
	reconstructed := ""
	lastPart := 0
	for _, chunk := range chunks {
		if len(chunk) > rotationSourceChunkLimit {
			t.Fatal("oversized chunk")
		}
		var v struct {
			Messages []rotationSourcePart `json:"messages"`
		}
		if err := json.Unmarshal([]byte(chunk), &v); err != nil {
			t.Fatal(err)
		}
		for _, part := range v.Messages {
			if part.Message == 1 {
				if part.Part != lastPart+1 || part.Parts < part.Part {
					t.Fatal("discontinuous parts")
				}
				reconstructed += part.Text
				lastPart = part.Part
			}
		}
	}
	if reconstructed != original {
		t.Fatal("source text was lost or changed")
	}
	if _, _, err := chunkRotationSource([]rotationSourceMessage{{"user", strings.Repeat("x", rotationSourceTextLimit+1)}}); err == nil {
		t.Fatal("accepted oversized evidence")
	}
}

func TestHostRotationSourceFilesAreBoundedAndFresh(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	directory := filepath.Join(home, ".codex", "sessions")
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, "fixture.jsonl")
	if err := os.WriteFile(path, []byte(rotationSourceCodexFixture()), 0600); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	binding := AgentBindingRecord{TranscriptPath: path, Revision: strings.Repeat("a", 64)}
	enrollment := hostRotationEnrollment{Client: "codex", SessionID: "fixture-session", CWD: "/fixture"}
	boundary := hostRotationSourceBoundary{TurnSeq: 3, TranscriptMtimeMS: info.ModTime().UnixMilli(), TranscriptBytes: info.Size()}
	source, err := readHostRotationSource(context.Background(), enrollment, boundary, binding)
	if err != nil {
		t.Fatal(err)
	}
	if source.Messages != 2 || len(source.TranscriptSHA256) != 64 || len(source.Chunks) != 1 {
		t.Fatal("invalid snapshot")
	}
	stale := boundary
	stale.TranscriptMtimeMS--
	if _, err := readHostRotationSource(context.Background(), enrollment, stale, binding); err == nil {
		t.Fatal("accepted stale completion watermark")
	}

	// Same-size edits with restored mtimes still change the full content digest.
	changed := strings.Replace(rotationSourceCodexFixture(), "original", "retained", 1)
	if err := os.WriteFile(path, []byte(changed), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, time.Now(), info.ModTime()); err != nil {
		t.Fatal(err)
	}
	second, err := readHostRotationSource(context.Background(), enrollment, boundary, binding)
	if err != nil {
		t.Fatal(err)
	}
	if source.TranscriptSHA256 == second.TranscriptSHA256 || source.EvidenceSHA256 == second.EvidenceSHA256 {
		t.Fatal("same-size edit escaped digest")
	}

	link := filepath.Join(directory, "linked.jsonl")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if _, err := rotationSourcePath(link, "codex"); err == nil {
		t.Fatal("accepted symlink")
	}
	hardlink := filepath.Join(directory, "hard.jsonl")
	if err := os.Link(path, hardlink); err != nil {
		t.Fatal(err)
	}
	if _, err := rotationSourcePath(path, "codex"); err == nil {
		t.Fatal("accepted hard-linked transcript")
	}
	if err := os.Remove(hardlink); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0666); err != nil {
		t.Fatal(err)
	}
	if _, err := rotationSourcePath(path, "codex"); err == nil {
		t.Fatal("accepted writable source")
	}
	if _, err := rotationSourcePath(filepath.Join(home, "credentials.jsonl"), "codex"); err == nil {
		t.Fatal("accepted outside path")
	}
}
