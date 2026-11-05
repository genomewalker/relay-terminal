package daemon

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func conversationFixture(t *testing.T, kind, session, text string) (*phReader, string) {
	t.Helper()
	path := phWrite(t, filepath.Join(t.TempDir(), "conversation.jsonl"), text, 0600)
	r := phScriptedReader(nil)
	r.identity = func(any) string { return "same-process" }
	r.agent = func(int64, string, string) (int64, string) { return 22, kind }
	r.inventory = func() *phProcesses {
		p := &phProcesses{rows: map[int64]phProcess{}}
		p.set(11, phProcess{parent: 1, name: "bash"})
		p.set(22, phProcess{parent: 11, name: kind})
		return p
	}
	r.binding = func(string, string, int64, string) *pyObject { return nil }
	r.transcript = func(int64, string) (string, string) { return path, session }
	r.metadata = func(string, string) any { return session }
	return r, path
}

func conversationJSONLine(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return string(b) + "\n"
}
func conversationTextRow(id, text string) map[string]any {
	return map[string]any{"uuid": id, "type": "response_item", "payload": map[string]any{"type": "message", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": text}}}}
}
func requireConversationRefusal(t *testing.T, part string, run func()) {
	t.Helper()
	got := phRaised(t, run)
	if got == nil || !strings.Contains(got.msg, part) {
		t.Fatalf("expected refusal containing %q, got %v", part, got)
	}
}

// These cases preserve the original frontend-binding and history paging
// regressions, now against the production Go reader rather than a script.
func TestConversationSameProcessThreadSwitchRejectsSnapshot(t *testing.T) {
	r, path := conversationFixture(t, "codex", "first", conversationJSONLine(conversationTextRow("1", "first thread")))
	calls := 0
	r.transcript = func(int64, string) (string, string) {
		calls++
		if calls > 1 {
			return path, "second"
		}
		return path, "first"
	}
	requireConversationRefusal(t, "changed its bound transcript", func() { r.conversationSnapshot("pane", 11, "", nil, "", "") })
}
func TestConversationSameProcessThreadSwitchRejectsAttachment(t *testing.T) {
	row := map[string]any{"type": "user", "uuid": "image", "sessionId": "first", "message": map[string]any{"content": []any{map[string]any{"type": "image", "source": map[string]any{"type": "base64", "media_type": "image/png", "data": base64.StdEncoding.EncodeToString([]byte("image fixture"))}}}}}
	r, path := conversationFixture(t, "claude", "first", conversationJSONLine(row))
	snapshot := r.conversationSnapshot("pane", 11, "", nil, "", "")
	image := phIndex(snapshot, "items").(*pyList).items[0].(*pyObject).Get("images").(*pyList).items[0].(*pyObject)
	reference := image.Get("reference").(string)
	attachment := r.conversationAttachment("pane", 11, "", reference)
	raw, err := base64.StdEncoding.DecodeString(attachment.Get("data").(string))
	if err != nil || string(raw) != "image fixture" || attachment.Get("mime") != "image/png" {
		t.Fatal("exact attachment bytes", attachment, err)
	}
	calls := 0
	r.transcript = func(int64, string) (string, string) {
		calls++
		if calls > 1 {
			return path, "second"
		}
		return path, "first"
	}
	requireConversationRefusal(t, "changed its bound transcript", func() { r.conversationAttachment("pane", 11, "", reference) })
}
func TestConversationTranscriptRecheckFences(t *testing.T) {
	t.Run("closed descriptor", func(t *testing.T) {
		r, _ := conversationFixture(t, "codex", "first", "")
		r.transcript = func(int64, string) (string, string) { phRaise(phUnbound, "No unique transcript"); return "", "" }
		requireConversationRefusal(t, "No unique transcript", func() { r.recheckConversationTranscript(22, "codex", "/first", "first", nil) })
	})
	t.Run("changed path same session", func(t *testing.T) {
		r, _ := conversationFixture(t, "codex", "first", "")
		r.transcript = func(int64, string) (string, string) { return "/replacement", "first" }
		requireConversationRefusal(t, "changed its bound transcript", func() { r.recheckConversationTranscript(22, "codex", "/first", "first", nil) })
	})
	t.Run("unchanged descriptor", func(t *testing.T) {
		r, _ := conversationFixture(t, "codex", "first", "")
		r.transcript = func(int64, string) (string, string) { return "/first", "first" }
		r.recheckConversationTranscript(22, "codex", "/first", "first", nil)
	})
	t.Run("authenticated path separate revision", func(t *testing.T) {
		r, _ := conversationFixture(t, "codex", "first", "")
		r.transcript = func(int64, string) (string, string) { t.Fatal("must use authenticated revision"); return "", "" }
		r.recheckConversationTranscript(22, "codex", "/first", "first", pyObj("transcript_path", "/first"))
	})
	t.Run("authenticated metadata change", func(t *testing.T) {
		r, _ := conversationFixture(t, "codex", "second", "")
		requireConversationRefusal(t, "Authenticated transcript session changed", func() {
			r.recheckConversationTranscript(22, "codex", "/first", "first", pyObj("transcript_path", "/first"))
		})
	})
	t.Run("authenticated path change", func(t *testing.T) {
		r, _ := conversationFixture(t, "codex", "first", "")
		requireConversationRefusal(t, "Authenticated transcript session changed", func() {
			r.recheckConversationTranscript(22, "codex", "/first", "first", pyObj("transcript_path", "/replacement"))
		})
	})
}
func TestConversationHistoryPagesCoverAllRowsWithoutDuplicates(t *testing.T) {
	var text strings.Builder
	for i := 0; i < 600; i++ {
		text.WriteString(conversationJSONLine(conversationTextRow(fmt.Sprint(i), fmt.Sprint("message ", i))))
	}
	r, _ := conversationFixture(t, "codex", "session", text.String())
	page := r.conversationSnapshot("pane", 11, "", nil, "", "")
	pages := [][]any{page.Get("items").(*pyList).items}
	source := page.Get("binding").(*pyObject).Get("source_identity").(string)
	for {
		raw := page.Get("history").(*pyObject).Get("before")
		if raw == nil {
			break
		}
		before := raw.(int64)
		page = r.conversationSnapshot("pane", 11, "", &before, source, "session")
		if !pyEqual(page.Get("history").(*pyObject).Get("historical"), true) || page.Get("control") != nil {
			t.Fatal("historical control leaked")
		}
		pages = append([][]any{page.Get("items").(*pyList).items}, pages...)
		if len(pages) > 600 {
			t.Fatal("history cursor failed to advance")
		}
	}
	var ids []string
	for _, items := range pages {
		for _, item := range items {
			ids = append(ids, item.(*pyObject).Get("id").(string))
		}
	}
	var want []string
	for i := 0; i < 600; i++ {
		want = append(want, fmt.Sprint(i))
	}
	if !reflect.DeepEqual(ids, want) {
		t.Fatalf("history coverage got %d ordered ids, want 600", len(ids))
	}
	before := int64(100)
	requireConversationRefusal(t, "history source changed", func() { r.conversationSnapshot("pane", 11, "", &before, "different", "session") })
}
func TestConversationHistoryKeepsToolsFromSameRecordTogether(t *testing.T) {
	var text strings.Builder
	for i := 0; i < 6; i++ {
		var blocks []any
		for j := 0; j < 64; j++ {
			blocks = append(blocks, map[string]any{"type": "tool_use", "id": fmt.Sprint(i, "-", j), "name": "Read", "input": map[string]any{}})
		}
		text.WriteString(conversationJSONLine(map[string]any{"uuid": fmt.Sprint(i), "sessionId": "session", "type": "assistant", "message": map[string]any{"content": blocks}}))
	}
	r, _ := conversationFixture(t, "claude", "session", text.String())
	latest := r.conversationSnapshot("pane", 11, "", nil, "", "")
	before := latest.Get("history").(*pyObject).Get("before").(int64)
	older := r.conversationSnapshot("pane", 11, "", &before, latest.Get("binding").(*pyObject).Get("source_identity").(string), "session")
	ids := map[string]bool{}
	count := 0
	for _, page := range []*pyObject{older, latest} {
		for _, raw := range page.Get("items").(*pyList).items {
			count++
			id := raw.(*pyObject).Get("id").(string)
			if ids[id] {
				t.Fatal("duplicate tool record", id)
			}
			ids[id] = true
		}
	}
	if count != 384 || len(ids) != 384 || older.Get("history").(*pyObject).Get("before") != nil {
		t.Fatal("same-record tool coverage", count, len(ids))
	}
}
func conversationStockBinding() *pyObject {
	return pyObj("version", int64(1), "source", "stock_app_server_proxy", "session_id", "chosen", "revision", strings.Repeat("a", 64), "producer", pyObj("pane_id", "pane", "provider", "codex", "process_id", int64(22), "process_start", int64(7)),
		"stock_proxy", pyObj("proxy_pid", int64(44), "proxy_start", int64(55), "control_socket", "/private/control", "control_device", int64(1), "control_inode", int64(2), "connection", int64(3), "selection", int64(4)),
		"native_endpoint", pyObj("socket", "/private/backend", "daemon_pid", int64(44), "daemon_start", int64(55)))
}
func TestConversationBindingOnlyIdentifiesUnwrittenStockThreadAndRejectsRevisionChange(t *testing.T) {
	r, _ := conversationFixture(t, "codex", "session", "")
	binding := conversationStockBinding()
	r.binding = func(string, string, int64, string) *pyObject { return binding }
	r.run = func([]string, float64) string { return `{"process_start":7}` }
	r.transcript = func(int64, string) (string, string) { t.Fatal("must not guess history"); return "", "" }
	got := r.conversationBindingOnly("pane", 11, "reader").Get("binding").(*pyObject)
	if got.Get("session_id") != "chosen" || got.Get("source_identity") != "stock-proxy:"+strings.Repeat("a", 64) {
		t.Fatal("unwritten stock identity", got)
	}
	calls := 0
	r.binding = func(string, string, int64, string) *pyObject {
		calls++
		if calls > 1 {
			changed := binding.Copy()
			changed.Set("revision", strings.Repeat("b", 64))
			return changed
		}
		return binding
	}
	requireConversationRefusal(t, "binding changed", func() { r.conversationBindingOnly("pane", 11, "reader") })
}
func TestConversationSnapshotRejectsProcessBindingAndSourceChanges(t *testing.T) {
	for _, which := range []string{"root", "agent", "ancestry", "binding", "rotate", "truncate", "mode"} {
		t.Run(which, func(t *testing.T) {
			r, path := conversationFixture(t, "codex", "session", conversationJSONLine(conversationTextRow("1", "hi")))
			binding := conversationStockBinding()
			binding.Set("session_id", "session")
			binding.Set("transcript_path", path)
			calls := 0
			r.binding = func(string, string, int64, string) *pyObject {
				calls++
				if calls > 1 && which == "binding" {
					q := binding.Copy()
					q.Set("revision", strings.Repeat("b", 64))
					return q
				}
				return binding
			}
			identityReads := map[int64]int{}
			r.identity = func(v any) string {
				pid := phPyInt(v)
				identityReads[pid]++
				if identityReads[pid] > 1 && (which == "root" && pid == 11 || which == "agent" && pid == 22) {
					return "reused"
				}
				return "same"
			}
			if which == "ancestry" {
				r.inventory = func() *phProcesses { return &phProcesses{rows: map[int64]phProcess{}} }
			}
			if which == "mode" {
				if err := os.Chmod(path, 0666); err != nil {
					t.Fatal(err)
				}
			}
			if which == "rotate" || which == "truncate" {
				r.codexLifecycle = func(any) *pyList {
					if which == "rotate" {
						if err := os.Rename(path, path+".old"); err != nil {
							t.Fatal(err)
						}
						if err := os.WriteFile(path, []byte("{}\n"), 0600); err != nil {
							t.Fatal(err)
						}
					} else {
						if err := os.Truncate(path, 0); err != nil {
							t.Fatal(err)
						}
					}
					return nil
				}
				// Lifecycle is only read when no authenticated binding exists.
				r.binding = func(string, string, int64, string) *pyObject { return nil }
				r.run = func([]string, float64) string { return `{"process_start":7}` }
			}
			if raised := phRaised(t, func() { r.conversationSnapshot("pane", 11, "reader", nil, "", "") }); raised == nil {
				t.Fatal("changed identity/source accepted", which)
			}
		})
	}
}
func TestConversationLineBoundsAndPartialRecords(t *testing.T) {
	for _, size := range []int{0, 1, 65535, 65536, 65537, conversationMaxLine, conversationMaxLine + 1} {
		data := append(bytes.Repeat([]byte{'x'}, size), '\n', 'z', '\n')
		reader := bufioNewConversationReader(data)
		first := conversationReadLine(reader, conversationMaxLine+1)
		if len(first) > conversationMaxLine+1 {
			t.Fatal("line allocation exceeded bound")
		}
		rest, _ := io.ReadAll(reader)
		if !bytes.Equal(append(append([]byte{}, first...), rest...), data) {
			t.Fatal("line reader lost buffered bytes", size)
		}
	}
	r, _ := conversationFixture(t, "codex", "session", conversationJSONLine(conversationTextRow("1", "complete"))+strings.TrimSuffix(conversationJSONLine(conversationTextRow("2", "partial")), "\n"))
	got := r.conversationSnapshot("pane", 11, "", nil, "", "").Get("items").(*pyList)
	if len(got.items) != 1 || got.items[0].(*pyObject).Get("id") != "1" {
		t.Fatal("partial record admitted")
	}
}

// Fuzz the actual transcript parser and line reader, checking stable output,
// bounded result cardinality, exact revisions, and lossless buffered reads.
func FuzzConversationRows(f *testing.F) {
	f.Add([]byte("x\nrest"))
	f.Add([]byte(strings.Repeat("x", 30) + "\nremainder"))
	for _, seed := range []string{`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi"}]}}`,
		`{"type":"assistant","sessionId":"session","message":{"content":[{"type":"tool_use","id":"one","name":"Read","input":{}},{"type":"tool_result","tool_use_id":"one","content":"done"}]}}`,
		`{"type":"user","sessionId":"session","message":{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"eA=="}}]}}`,
		`{"type":"event_msg","payload":{"type":"plan_update","plan":[]}}`,
		`{"type":"response_item","payload":null}`, `{"type":"event_msg","payload":[]}`, `{`} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 65536 {
			return
		}
		reader := bufioNewConversationReader(data)
		first := conversationReadLine(reader, 31)
		rest, _ := io.ReadAll(reader)
		if len(first) > 31 || !bytes.Equal(append(append([]byte{}, first...), rest...), data) {
			t.Fatal("bounded lossless line read")
		}
		var decoded any
		if phCatch(func() { decoded = phLoadsBytes(data) }, phValueError) != nil {
			return
		}
		row, ok := decoded.(*pyObject)
		if !ok {
			return
		}
		var result *pyList
		if phRaised(t, func() { result = parseConversationRow(row, "claude", "session", 37, newPyObject()) }) != nil {
			return
		}
		if len(result.items) > 65 {
			t.Fatal("parser item bound", len(result.items))
		}
		encoded := pyCompact(result)
		var again *pyList
		if phRaised(t, func() { again = parseConversationRow(row, "claude", "session", 37, newPyObject()) }) != nil || !bytes.Equal(encoded, pyCompact(again)) {
			t.Fatal("parser is not deterministic")
		}
		for _, raw := range result.items {
			item := raw.(*pyObject)
			if item.Get("revision") != int64(38) {
				t.Fatal("source revision changed")
			}
			if image, ok := item.Get("images").(*pyList); ok && len(image.items) > 16 {
				t.Fatal("image count bound")
			}
		}
	})
}

func FuzzNativeReaderCLI(f *testing.F) {
	f.Add("../pane", int64(-1), "not-base64")
	f.Add("pane", int64(0), "e30=")
	f.Fuzz(func(t *testing.T, pane string, root int64, encoded string) {
		if len(pane) > 256 || len(encoded) > 65536 {
			return
		}
		// Invalid selectors must be rejected before any host observation. A
		// cancelled context cannot make a malformed selector valid.
		if phSafeID.MatchString(pane) && root >= 0 {
			return
		}
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		var out bytes.Buffer
		if err := RunPaneMessaging(ctx, []string{"--pane", pane, "--root-pid", fmt.Sprint(root), "--request", encoded}, &out); err == nil || out.Len() != 0 {
			t.Fatal("invalid selector reached messaging")
		}
		if err := RunAgentConversation(ctx, []string{"--pane", pane, "--root-pid", fmt.Sprint(root)}, &out); err == nil || out.Len() != 0 {
			t.Fatal("invalid selector reached conversation")
		}
	})
}

func bufioNewConversationReader(data []byte) *bufio.Reader {
	return bufio.NewReaderSize(bytes.NewReader(data), 65536)
}
