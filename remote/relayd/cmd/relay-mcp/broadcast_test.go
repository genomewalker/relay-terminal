package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

const (
	bSource      = "aaaaaaaa-0000-4000-8000-000000000001"
	bTabMate     = "aaaaaaaa-0000-4000-8000-000000000002"
	bTabShell    = "aaaaaaaa-0000-4000-8000-000000000003"
	bTabUnlinked = "aaaaaaaa-0000-4000-8000-000000000004"
	bOtherTab    = "aaaaaaaa-0000-4000-8000-000000000005"
	bOtherOwner  = "aaaaaaaa-0000-4000-8000-000000000006"
	bEditor      = "aaaaaaaa-0000-4000-8000-000000000007"
	bUnowned     = "aaaaaaaa-0000-4000-8000-000000000008"
	bBroadcast   = "bbbbbbbb-0000-4000-8000-000000000001"
	bTab0        = "cccccccc-0000-4000-8000-000000000000"
	bTab1        = "cccccccc-0000-4000-8000-000000000001"
	bTab2        = "cccccccc-0000-4000-8000-000000000002"
	bTab3        = "cccccccc-0000-4000-8000-000000000003"
	bWorkspace   = "dddddddd-0000-4000-8000-000000000000"
	bWorkspace2  = "dddddddd-0000-4000-8000-000000000001"
)

func bPane(id, agent, kind string) map[string]string {
	return map[string]string{"id": id, "agent": agent, "contentKind": kind}
}

func bMember(pane string, generation int) map[string]any {
	return map[string]any{"paneID": pane, "hostID": "host", "provider": "claude", "sessionID": fmt.Sprintf("conv-%s-%d", pane[len(pane)-2:], generation), "pid": 10, "start": "s"}
}

func bLink(a, b string) map[string]any {
	return map[string]any{"members": []any{bMember(a, 0), bMember(b, 0)}}
}

// broadcastFixture: the source's tab (owned by bWorkspace, broadcast allowed
// for tab and workspace) holds a linked agent, a shell, an unlinked agent and
// an editor; a second tab of the same workspace, a tab of another workspace
// and a tab with unknown ownership each hold one linked agent. The legacy
// session grouping puts the other-workspace tab with the source, as the
// navigator need not.
func broadcastFixture() (string, string) {
	state, _ := json.Marshal(map[string]any{"sessions": []any{
		map[string]any{"tabs": []any{
			map[string]any{"id": bTab0, "workspaceID": bWorkspace, "broadcast": []string{"tab", "workspace"}, "panes": []any{
				bPane(bSource, "claude", "terminal"), bPane(bTabMate, "codex", "terminal"), bPane(bTabShell, "shell", "terminal"),
				bPane(bTabUnlinked, "claude", "terminal"), bPane(bEditor, "codex", "editor")}},
			map[string]any{"id": bTab1, "workspaceID": bWorkspace, "panes": []any{bPane(bOtherTab, "codex", "terminal")}},
			map[string]any{"id": bTab2, "workspaceID": bWorkspace2, "panes": []any{bPane(bOtherOwner, "claude", "terminal")}},
		}},
		map[string]any{"tabs": []any{map[string]any{"id": bTab3, "panes": []any{bPane(bUnowned, "claude", "terminal")}}}},
	}})
	links, _ := json.Marshal(map[string]any{"links": []any{bLink(bSource, bTabMate), bLink(bTabShell, bSource),
		bLink(bOtherTab, bSource), bLink(bOtherOwner, bSource), bLink(bUnowned, bSource), bLink(bEditor, bSource), bLink(bTabUnlinked, bOtherTab)}})
	return string(state), string(links)
}

func bRecipients(m broadcastManifest) string {
	var ids []string
	for _, r := range m.Recipients {
		ids = append(ids, r.PaneID)
	}
	return strings.Join(ids, ",")
}

func TestPlanBroadcastScopes(t *testing.T) {
	state, links := broadcastFixture()
	tab, err := planBroadcast([]byte(state), []byte(links), strings.ToUpper(bSource), "tab", bBroadcast)
	if err != nil || bRecipients(tab) != bTabMate || tab.ScopeID != "tab:"+bTab0 {
		t.Fatalf("tab scope: %+v %v", tab, err)
	}
	if tab.Skipped[bTabUnlinked] == "" || len(tab.Skipped) != 1 {
		t.Fatalf("unlinked tab mate must be reported, nothing else: %v", tab.Skipped)
	}
	all, err := planBroadcast([]byte(state), []byte(links), bSource, "workspace", bBroadcast)
	if err != nil || bRecipients(all) != bTabMate+","+bOtherTab || all.ScopeID != "workspace:"+bWorkspace {
		t.Fatalf("workspace scope must be the navigator workspace, not the legacy session: %+v %v", all, err)
	}
	if all.SourceIdentity == "" || all.Recipients[0].Identity == "" || all.Recipients[0].MessageID != broadcastMessageID(bBroadcast, bTabMate) {
		t.Fatalf("recipients must carry their conversation and derived message ID: %+v", all)
	}
	for _, bad := range []struct{ source, scope string }{{bSource, "everything"}, {"not-a-pane", "tab"}, {bBroadcast, "tab"}} {
		if _, err := planBroadcast([]byte(state), []byte(links), bad.source, bad.scope, bBroadcast); err == nil {
			t.Fatalf("accepted %v", bad)
		}
	}
	// Only the user's grant in Relay allows a scope; nothing else does.
	for _, grants := range [][]string{nil, {"workspace"}, {"Tab"}} {
		edited := bEditTab(t, state, 0, func(tab map[string]any) { tab["broadcast"] = grants })
		if _, err := planBroadcast([]byte(edited), []byte(links), bSource, "tab", bBroadcast); err == nil || !strings.Contains(err.Error(), "only the user") {
			t.Fatalf("grants %v allowed a tab broadcast: %v", grants, err)
		}
	}
	unowned := bEditTab(t, state, 0, func(tab map[string]any) { delete(tab, "workspaceID") })
	if _, err := planBroadcast([]byte(unowned), []byte(links), bSource, "workspace", bBroadcast); err == nil || !strings.Contains(err.Error(), "unknown") {
		t.Fatalf("a source tab with unknown ownership must refuse a workspace broadcast: %v", err)
	}
	if m, err := planBroadcast([]byte(unowned), []byte(links), bSource, "tab", bBroadcast); err != nil || bRecipients(m) != bTabMate {
		t.Fatalf("a tab broadcast needs no workspace: %+v %v", m, err)
	}
	twice := strings.Replace(state, `"id":"`+bOtherTab+`"`, `"id":"`+bTabMate+`"`, 1)
	if _, err := planBroadcast([]byte(twice), []byte(links), bSource, "workspace", bBroadcast); err == nil {
		t.Fatal("a pane placed in two tabs was accepted")
	}
	// Two links to one pane naming different conversations make it ineligible.
	var parsed map[string][]any
	json.Unmarshal([]byte(links), &parsed)
	parsed["links"] = append(parsed["links"], map[string]any{"members": []any{bMember(bSource, 0), bMember(bTabMate, 1)}})
	conflicting, _ := json.Marshal(parsed)
	if m, err := planBroadcast([]byte(state), conflicting, bSource, "tab", bBroadcast); err != nil || len(m.Recipients) != 0 || m.Skipped[bTabMate] == "" {
		t.Fatalf("a pane with two conversations was planned: %+v %v", m, err)
	}
	parsed["links"] = append(parsed["links"], map[string]any{"members": []any{bMember(bSource, 1), bMember(bOtherTab, 0)}})
	twoSources, _ := json.Marshal(parsed)
	if _, err := planBroadcast([]byte(state), twoSources, bSource, "tab", bBroadcast); err == nil {
		t.Fatal("a source with two conversations was accepted")
	}
}

// bEditTab changes the index-th tab of the first session of a state document.
func bEditTab(t *testing.T, state string, index int, edit func(map[string]any)) string {
	var doc map[string]any
	if err := json.Unmarshal([]byte(state), &doc); err != nil {
		t.Fatal(err)
	}
	edit(doc["sessions"].([]any)[0].(map[string]any)["tabs"].([]any)[index].(map[string]any))
	return mustJSON(t, doc)
}

func mustJSON(t *testing.T, value any) string {
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func bWide(count int) (string, string) {
	panes := []any{bPane(bSource, "claude", "terminal")}
	links := []any{}
	for i := 0; i < count; i++ {
		id := fmt.Sprintf("eeeeeeee-0000-4000-8000-%012d", i)
		panes = append(panes, bPane(id, "codex", "terminal"))
		links = append(links, bLink(bSource, id))
	}
	state, _ := json.Marshal(map[string]any{"sessions": []any{map[string]any{"tabs": []any{
		map[string]any{"id": bTab0, "broadcast": []string{"tab"}, "panes": panes}}}}})
	linkJSON, _ := json.Marshal(map[string]any{"links": links})
	return string(state), string(linkJSON)
}

func TestPlanBroadcastLimit(t *testing.T) {
	state, links := bWide(broadcastLimit)
	if m, err := planBroadcast([]byte(state), []byte(links), bSource, "tab", bBroadcast); err != nil || len(m.Recipients) != broadcastLimit {
		t.Fatalf("%d recipients: %v", broadcastLimit, err)
	}
	state, links = bWide(broadcastLimit + 1)
	if _, err := planBroadcast([]byte(state), []byte(links), bSource, "tab", bBroadcast); err == nil {
		t.Fatal("an over-limit broadcast must be refused, not truncated")
	}
}

func TestBroadcastMessageID(t *testing.T) {
	a := broadcastMessageID(bBroadcast, bTabMate)
	if !paneID.MatchString(a) || a != broadcastMessageID(strings.ToUpper(bBroadcast), strings.ToUpper(bTabMate)) {
		t.Fatalf("message ID %s must be a stable UUID", a)
	}
	if a == broadcastMessageID(bBroadcast, bOtherTab) || a == broadcastMessageID(bSource, bTabMate) {
		t.Fatal("message IDs must differ per recipient and per broadcast")
	}
	if a[14] != '8' || !strings.ContainsRune("89ab", rune(a[19])) {
		t.Fatalf("message ID %s must carry the version 8 and RFC 4122 variant bits", a)
	}
}

// memStore is an in-memory broadcastStore whose lock models flock's
// non-blocking exclusion.
type memStore struct {
	files  map[string][]byte
	locked bool
	onSave func(id string, data []byte, created bool)
	fail   bool
}

func newMemStore() *memStore { return &memStore{files: map[string][]byte{}} }

func (m *memStore) lock() (func(), error) {
	if m.locked {
		return nil, errBroadcastBusy
	}
	m.locked = true
	return func() { m.locked = false }, nil
}
func (m *memStore) load(id string) ([]byte, error) {
	data, ok := m.files[id]
	if !ok {
		return nil, fs.ErrNotExist
	}
	return data, nil
}
func (m *memStore) put(id string, data []byte, created bool) error {
	if m.fail {
		return errors.New("disk full")
	}
	if m.onSave != nil {
		m.onSave(id, data, created)
	}
	m.files[id] = append([]byte(nil), data...)
	return nil
}
func (m *memStore) create(id string, data []byte) error {
	if _, ok := m.files[id]; ok {
		return fs.ErrExist
	}
	return m.put(id, data, true)
}
func (m *memStore) save(id string, data []byte) error { return m.put(id, data, false) }
func (m *memStore) remove(id string) error            { delete(m.files, id); return nil }
func (m *memStore) all() (map[string][]byte, error) {
	out := map[string][]byte{}
	for k, v := range m.files {
		out[k] = v
	}
	return out, nil
}

// fixedCaller serves fixed documents and records relay_message_pane calls.
func fixedCaller(state, links *string, sent *[]string, fail map[string]bool) broadcastCaller {
	return func(name string, arguments map[string]any) (string, bool) {
		switch name {
		case "relay_list_panes":
			return *state, true
		case "relay_list_pane_links":
			return *links, true
		case "relay_message_pane":
			target := arguments["pane_id"].(string)
			if fail[target] {
				return "relayd unavailable", false
			}
			*sent = append(*sent, target+" "+arguments["message_id"].(string))
			return `{"status":"accepted_by_provider"}`, true
		}
		return "unexpected " + name, false
	}
}

func bResult(t *testing.T, body string) (map[string]string, string) {
	var out struct {
		Recipients []broadcastRecipient `json:"recipients"`
		Halted     string               `json:"halted"`
	}
	if err := json.Unmarshal([]byte(body), &out); err != nil {
		t.Fatalf("unreadable result %s", body)
	}
	states := map[string]string{}
	for _, r := range out.Recipients {
		states[r.PaneID] = r.State
	}
	return states, out.Halted
}

func TestRunBroadcastRetryConflictAndHalt(t *testing.T) {
	state, links := broadcastFixture()
	var sent []string
	store := newMemStore()
	now := time.Date(2026, 10, 29, 12, 0, 0, 0, time.UTC)
	call := fixedCaller(&state, &links, &sent, map[string]bool{bOtherTab: true})
	body, failed := runBroadcast(bSource, "workspace", bBroadcast, "hello", call, store, now)
	states, _ := bResult(t, body)
	if !failed || states[bTabMate] != "sent" || states[bOtherTab] != "failed" || len(sent) != 1 {
		t.Fatalf("first run: %s %v", body, sent)
	}
	// A new linked pane appears; the retry must not reach it, and must resend
	// only the failed recipient, with the same message ID.
	links = strings.Replace(links, `{"links":[`, `{"links":[`+mustJSON(t, bLink(bSource, bTabUnlinked))+`,`, 1)
	call = fixedCaller(&state, &links, &sent, nil)
	body, failed = runBroadcast(bSource, "workspace", bBroadcast, "hello", call, store, now.Add(time.Minute))
	states, _ = bResult(t, body)
	if failed || states[bOtherTab] != "sent" || len(states) != 2 || len(sent) != 2 || sent[1] != bOtherTab+" "+broadcastMessageID(bBroadcast, bOtherTab) {
		t.Fatalf("retry: %s %v", body, sent)
	}
	for _, other := range []struct{ scope, text string }{{"workspace", "hello!"}, {"tab", "hello"}} {
		if body, failed := runBroadcast(bSource, other.scope, bBroadcast, other.text, call, store, now); !failed || !strings.Contains(body, "different") {
			t.Fatalf("reused ID with %v: %s", other, body)
		}
	}
	if body, failed := runBroadcast(bSource, "workspace", bBroadcast, "hello", call, store, now.Add(broadcastTTL+time.Second)); !failed || !strings.Contains(body, "expired") {
		t.Fatalf("expired ID: %s", body)
	}
	if len(sent) != 2 {
		t.Fatalf("refused calls sent %v", sent)
	}

	// The first recipient's conversation changes: it is held and the rest halt.
	second := "bbbbbbbb-0000-4000-8000-000000000002"
	state, links = broadcastFixture()
	moved := strings.Replace(links, mustJSON(t, bMember(bTabMate, 0)), mustJSON(t, bMember(bTabMate, 1)), 1)
	plannedLinks := links
	turn := 0
	call = func(name string, arguments map[string]any) (string, bool) {
		turn++
		if name == "relay_list_pane_links" && turn > 2 {
			return moved, true
		}
		return fixedCaller(&state, &plannedLinks, &sent, nil)(name, arguments)
	}
	sent = nil
	body, failed = runBroadcast(bSource, "workspace", second, "hello", call, store, now)
	states, halted := bResult(t, body)
	if !failed || states[bTabMate] != "held" || states[bOtherTab] != "pending" || halted == "" || len(sent) != 0 {
		t.Fatalf("drift: %s %v", body, sent)
	}
	// A held recipient stays held even when the drift is undone.
	call = fixedCaller(&state, &plannedLinks, &sent, nil)
	body, _ = runBroadcast(bSource, "workspace", second, "hello", call, store, now)
	states, _ = bResult(t, body)
	if states[bTabMate] != "held" || states[bOtherTab] != "sent" || len(sent) != 1 {
		t.Fatalf("after drift: %s %v", body, sent)
	}
	// Revoking the grant holds every remaining recipient.
	third := "bbbbbbbb-0000-4000-8000-000000000003"
	revoked := bEditTab(t, state, 0, func(tab map[string]any) { tab["broadcast"] = []string{"tab"} })
	turn = 0
	call = func(name string, arguments map[string]any) (string, bool) {
		turn++
		if name == "relay_list_panes" && turn > 2 {
			return revoked, true
		}
		return fixedCaller(&state, &plannedLinks, &sent, nil)(name, arguments)
	}
	sent = nil
	body, _ = runBroadcast(bSource, "workspace", third, "hello", call, store, now)
	if states, _ := bResult(t, body); states[bTabMate] != "held" || len(sent) != 0 || !strings.Contains(body, "no longer allowed") {
		t.Fatalf("revoked: %s %v", body, sent)
	}
	store.fail = true
	if body, failed := runBroadcast(bSource, "tab", "bbbbbbbb-0000-4000-8000-000000000004", "hello", call, store, now); !failed || len(sent) != 0 || !strings.Contains(body, "nothing was sent") {
		t.Fatalf("an unsaved manifest must send nothing: %s %v", body, sent)
	}
}

func TestBroadcastBudgetAndLock(t *testing.T) {
	state, links := broadcastFixture()
	var sent []string
	call := fixedCaller(&state, &links, &sent, nil)
	store := newMemStore()
	now := time.Date(2026, 10, 29, 12, 0, 0, 0, time.UTC)
	id := func(i int) string { return fmt.Sprintf("ffffffff-0000-4000-8000-%012d", i) }
	for i := 0; i < broadcastBudget; i++ {
		if body, failed := runBroadcast(bSource, "tab", id(i), "hi", call, store, now.Add(time.Duration(i)*time.Second)); failed {
			t.Fatalf("broadcast %d: %s", i, body)
		}
	}
	if body, failed := runBroadcast(bSource, "tab", id(99), "hi", call, store, now.Add(time.Minute)); !failed || !strings.Contains(body, "already started") {
		t.Fatalf("fresh IDs must not bypass the budget: %s", body)
	}
	if _, failed := runBroadcast(bSource, "tab", id(0), "hi", call, store, now.Add(time.Minute)); failed {
		t.Fatal("a retry of a known ID is not a new broadcast")
	}
	if body, failed := runBroadcast(bSource, "tab", id(99), "hi", call, store, now.Add(broadcastWindow+time.Minute)); failed {
		t.Fatalf("budget must refill after the window: %s", body)
	}
	if _, err := store.load(id(0)); err != nil {
		t.Fatal("unexpired manifests must be kept")
	}
	runBroadcast(bSource, "tab", id(100), "hi", call, store, now.Add(broadcastTTL+broadcastWindow+time.Minute))
	if _, err := store.load(id(0)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatal("expired manifests must be pruned")
	}
	unlock, _ := store.lock()
	if body, failed := runBroadcast(bSource, "tab", id(101), "hi", call, store, now); !failed || !strings.Contains(body, "in progress") {
		t.Fatalf("a second concurrent broadcast must be refused: %s", body)
	}
	unlock()
}

func TestFileBroadcastStore(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "broadcasts")
	store := fileBroadcastStore{dir}
	unlock, err := store.lock()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.lock(); err == nil {
		t.Fatal("a second holder must not get the lock")
	}
	if err := store.create(bBroadcast, []byte("one")); err != nil {
		t.Fatal(err)
	}
	if err := store.create(bBroadcast, []byte("two")); err == nil {
		t.Fatal("create must refuse an existing manifest")
	}
	if err := store.save(bBroadcast, []byte("three")); err != nil {
		t.Fatal(err)
	}
	if data, _ := store.load(bBroadcast); string(data) != "three" {
		t.Fatalf("save must replace: %q", data)
	}
	if info, _ := os.Stat(store.path(bBroadcast)); info.Mode().Perm() != 0o600 {
		t.Fatalf("manifest mode %v", info.Mode())
	}
	if info, _ := os.Stat(dir); info.Mode().Perm() != 0o700 {
		t.Fatalf("directory mode %v", info.Mode())
	}
	os.WriteFile(filepath.Join(dir, "notes.json"), []byte("x"), 0o600)
	if all, err := store.all(); err != nil || len(all) != 1 || string(all[bBroadcast]) != "three" {
		t.Fatalf("all: %v %v", all, err)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 3 {
		t.Fatalf("temporary files must not remain: %v", entries)
	}
	unlock()
	if again, err := store.lock(); err != nil {
		t.Fatal("the lock must be released")
	} else {
		again()
	}
	// Only contention is "in progress"; any other lock failure says what it is.
	for _, err := range []error{syscall.EWOULDBLOCK, syscall.EAGAIN} {
		if !errors.Is(lockFailure(err), errBroadcastBusy) {
			t.Fatalf("%v must mean another broadcast holds the lock", err)
		}
	}
	for _, err := range []error{syscall.ENOLCK, syscall.EBADF, syscall.EINTR} {
		if got := lockFailure(err); errors.Is(got, errBroadcastBusy) || !errors.Is(got, err) {
			t.Fatalf("%v must be reported as itself, got %v", err, got)
		}
	}
	blocked := filepath.Join(t.TempDir(), "file")
	os.WriteFile(blocked, []byte("x"), 0o600)
	broken := fileBroadcastStore{filepath.Join(blocked, "broadcasts")}
	if _, err := broken.lock(); err == nil || errors.Is(err, errBroadcastBusy) {
		t.Fatalf("an unusable directory must not look like contention: %v", err)
	}
	var sent []string
	state, links := broadcastFixture()
	body, failed := runBroadcast(bSource, "tab", bBroadcast, "hi", fixedCaller(&state, &links, &sent, nil), broken, time.Now())
	if !failed || strings.Contains(body, "in progress") || !strings.Contains(body, "Could not lock") || len(sent) != 0 {
		t.Fatalf("lock failure reported as %q", body)
	}
}

func TestBroadcastDeliversThroughMessagePane(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	state, links := broadcastFixture()
	var mu sync.Mutex
	var posts []string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == "GET" && r.URL.Path == "/api/state":
			io.WriteString(w, state)
		case r.Method == "GET" && r.URL.Path == "/api/pane-links":
			io.WriteString(w, links)
		case r.Method == "POST" && strings.HasSuffix(r.URL.Path, "/message"):
			var body map[string]any
			data, _ := io.ReadAll(r.Body)
			if json.Unmarshal(data, &body) != nil {
				t.Errorf("unreadable message body %s", data)
			}
			if text, _ := body["text"].(string); !strings.HasPrefix(text, "[Relay broadcast "+bBroadcast) || !strings.HasSuffix(text, "\n\nhello all") {
				t.Errorf("delivery must carry the broadcast envelope: %q", text)
			}
			mu.Lock()
			posts = append(posts, strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/api/panes/"), "/message")+" "+body["messageID"].(string))
			mu.Unlock()
			io.WriteString(w, `{"status":"accepted_by_provider"}`)
		default:
			http.Error(w, "unexpected", 404)
		}
	}))
	defer ts.Close()
	s := &server{token: "secret", client: ts.Client(), endpoint: ts.URL}
	call := func() map[string]any {
		params, _ := json.Marshal(map[string]any{"name": "relay_broadcast_message", "arguments": map[string]any{
			"source_pane_id": bSource, "scope": "workspace", "broadcast_id": bBroadcast, "text": "hello all"}})
		result, code, detail := s.handle(request{Method: "tools/call", Params: params})
		if code != 0 {
			t.Fatalf("%d %s", code, detail)
		}
		text, ok := resultText(result)
		if !ok {
			t.Fatalf("broadcast failed: %s", text)
		}
		var out map[string]any
		if json.Unmarshal([]byte(text), &out) != nil {
			t.Fatalf("unreadable result %s", text)
		}
		return out
	}
	want := []string{bOtherTab + " " + broadcastMessageID(bBroadcast, bOtherTab), bTabMate + " " + broadcastMessageID(bBroadcast, bTabMate)}
	first := call()
	sort.Strings(want)
	sort.Strings(posts)
	if strings.Join(posts, "|") != strings.Join(want, "|") {
		t.Fatalf("deliveries %v, want %v", posts, want)
	}
	if first["skipped"].(map[string]any)[bTabUnlinked] == nil {
		t.Fatal("skipped recipient missing from the result")
	}
	if _, err := os.Stat(filepath.Join(os.Getenv("HOME"), ".local/share/relay/broadcasts", bBroadcast+".json")); err != nil {
		t.Fatalf("manifest not saved: %v", err)
	}
	posts = nil
	call()
	if len(posts) != 0 {
		t.Fatalf("a repeated broadcast_id must not resend delivered messages: %v", posts)
	}
}

func TestBroadcastRejectsBadArguments(t *testing.T) {
	s := &server{}
	for _, args := range []map[string]any{
		{"source_pane_id": bSource, "scope": "tab", "broadcast_id": bBroadcast},
		{"source_pane_id": bSource, "scope": "session", "broadcast_id": bBroadcast, "text": "x"},
		{"source_pane_id": bSource, "scope": "tab", "broadcast_id": "x", "text": "x"},
		{"source_pane_id": bSource, "scope": "tab", "broadcast_id": bBroadcast, "text": "   "},
		{"source_pane_id": bSource, "scope": "tab", "broadcast_id": bBroadcast, "text": strings.Repeat("x", broadcastTextLimit+1)},
		{"source_pane_id": bSource, "scope": "tab", "broadcast_id": bBroadcast, "text": "x", "extra": true},
	} {
		raw := map[string]json.RawMessage{}
		for k, v := range args {
			raw[k], _ = json.Marshal(v)
		}
		if _, code, _ := s.broadcast(raw); code != -32602 {
			t.Fatalf("accepted %v", args)
		}
	}
}

// plan sends only to linked, sorted, distinct panes other than the source,
// within the limit and the source's exact scope; anything malformed, a pane
// placed twice, or a truncated document is refused.
func FuzzPlanBroadcast(f *testing.F) {
	state, links := broadcastFixture()
	f.Add(state, links, bSource, true)
	f.Add(state, links, bSource, false)
	f.Add(state, links, bTabMate, false)
	f.Add(strings.Replace(state, bOtherTab, bTabMate, 1), links, bSource, false)
	f.Add(`{"sessions":[{"tabs":[{"id":"`+bTab0+`","broadcast":["tab"],"panes":[{"id":"`+bSource+`","agent":"claude"}]}]}]}`, `{"links":[]}`, bSource, true)
	f.Add(`{"sessions":null}`, `{"links":[{"members":[]}]}`, bSource, false)
	f.Fuzz(func(t *testing.T, state, links, source string, tab bool) {
		scope := "workspace"
		if tab {
			scope = "tab"
		}
		m, err := planBroadcast([]byte(state), []byte(links), source, scope, bBroadcast)
		if len(state) > 1 && json.Valid([]byte(state)) && !json.Valid([]byte(state[:len(state)-1])) {
			if _, cut := planBroadcast([]byte(state[:len(state)-1]), []byte(links), source, scope, bBroadcast); cut == nil {
				t.Fatal("accepted a truncated workspace document")
			}
		}
		if err != nil {
			return
		}
		view, verr := readBroadcastView([]byte(state), []byte(links), strings.ToLower(source))
		if verr != nil || !view.allowed(m.Source, scope) || m.ScopeID == "" || view.scopeID(m.Source, scope) != m.ScopeID {
			t.Fatalf("planned outside an allowed exact scope: %+v %v", m, verr)
		}
		if len(m.Recipients) > broadcastLimit {
			t.Fatalf("%d recipients", len(m.Recipients))
		}
		for i, r := range m.Recipients {
			if r.PaneID == m.Source || (i > 0 && m.Recipients[i-1].PaneID >= r.PaneID) || m.Skipped[r.PaneID] != "" {
				t.Fatalf("recipients must be sorted, distinct, not the source and not skipped: %+v", m)
			}
			if !view.panes[r.PaneID].agent || view.scopeID(r.PaneID, scope) != m.ScopeID || view.peers[r.PaneID] != r.Identity || r.Identity == "" {
				t.Fatalf("recipient %s is not an eligible linked agent in scope: %+v", r.PaneID, m)
			}
			if recheck(view, &m, r) != "" {
				t.Fatalf("a freshly planned recipient fails its own recheck: %s", recheck(view, &m, r))
			}
		}
		// Round trip through the manifest reader.
		m.Digest, m.Created = strings.Repeat("ab", 32), time.Unix(1, 0).UTC()
		m.Expires = m.Created.Add(broadcastTTL)
		data, _ := json.Marshal(m)
		back, err := decodeManifest(data, bBroadcast)
		if err != nil || mustJSON(t, back) != string(data) {
			t.Fatalf("manifest round trip: %v", err)
		}
	})
}

// decodeManifest reads files another process wrote: a valid manifest round
// trips exactly, any strict prefix is refused, and anything accepted is
// internally consistent.
func FuzzDecodeManifest(f *testing.F) {
	state, links := broadcastFixture()
	m, _ := planBroadcast([]byte(state), []byte(links), bSource, "workspace", bBroadcast)
	m.Digest, m.Created = strings.Repeat("0f", 32), time.Date(2026, 10, 29, 12, 0, 0, 0, time.UTC)
	m.Expires = m.Created.Add(broadcastTTL)
	m.Recipients[0].State, m.Recipients[0].Detail = "sent", json.RawMessage(`{"status":"accepted_by_provider"}`)
	valid, _ := json.Marshal(m)
	f.Add(valid)
	f.Add([]byte(strings.Replace(string(valid), `"version":1`, `"version":2`, 1)))
	f.Add([]byte(strings.Replace(string(valid), `"state":"sent"`, `"state":"done"`, 1)))
	f.Add([]byte(string(valid) + `{}`))
	f.Add([]byte(`{}`))
	f.Fuzz(func(t *testing.T, data []byte) {
		got, err := decodeManifest(data, bBroadcast)
		for cut := len(data) - 1; err == nil && cut >= 0 && cut > len(data)-64; cut-- {
			if _, perr := decodeManifest(data[:cut], bBroadcast); perr == nil && json.Valid(data) && !json.Valid(data[:cut]) {
				t.Fatalf("accepted a truncated manifest (%d of %d bytes)", cut, len(data))
			}
		}
		if err != nil {
			return
		}
		if got.ID != bBroadcast || len(got.Recipients) > broadcastLimit || got.Expires.Sub(got.Created) > broadcastTTL || !got.Expires.After(got.Created) {
			t.Fatalf("inconsistent manifest accepted: %+v", got)
		}
		for i, r := range got.Recipients {
			if r.MessageID != broadcastMessageID(got.ID, r.PaneID) || r.PaneID == got.Source || (i > 0 && got.Recipients[i-1].PaneID >= r.PaneID) {
				t.Fatalf("inconsistent recipient accepted: %+v", r)
			}
		}
		again, _ := json.Marshal(got)
		if back, err := decodeManifest(again, bBroadcast); err != nil || mustJSON(t, back) != string(again) {
			t.Fatalf("an accepted manifest does not round trip: %v", err)
		}
	})
}

func TestDecodeManifestRejectsInconsistentRecords(t *testing.T) {
	state, links := broadcastFixture()
	m, _ := planBroadcast([]byte(state), []byte(links), bSource, "workspace", bBroadcast)
	m.Digest, m.Created = strings.Repeat("0f", 32), time.Date(2026, 10, 29, 12, 0, 0, 0, time.UTC)
	m.Expires = m.Created.Add(broadcastTTL)
	valid := mustJSON(t, m)
	if _, err := decodeManifest([]byte(valid), bBroadcast); err != nil {
		t.Fatalf("valid manifest refused: %v", err)
	}
	edit := func(change func(*broadcastManifest)) string {
		copy := m
		copy.Recipients = append([]broadcastRecipient(nil), m.Recipients...)
		change(&copy)
		return mustJSON(t, copy)
	}
	for name, data := range map[string]string{
		"wrong message ID": edit(func(m *broadcastManifest) {
			m.Recipients[0].MessageID = broadcastMessageID(bSource, m.Recipients[0].PaneID)
		}),
		"unsorted": edit(func(m *broadcastManifest) { m.Recipients[0], m.Recipients[1] = m.Recipients[1], m.Recipients[0] }),
		"source as target": edit(func(m *broadcastManifest) {
			m.Recipients[0].PaneID, m.Recipients[0].MessageID = bSource, broadcastMessageID(bBroadcast, bSource)
		}),
		"no identity":      edit(func(m *broadcastManifest) { m.Recipients[0].Identity = "" }),
		"unknown state":    edit(func(m *broadcastManifest) { m.Recipients[0].State = "done" }),
		"long life":        edit(func(m *broadcastManifest) { m.Expires = m.Created.Add(broadcastTTL + time.Second) }),
		"scope mismatch":   edit(func(m *broadcastManifest) { m.ScopeID = "tab:" + bTab0 }),
		"uppercase source": edit(func(m *broadcastManifest) { m.Source = strings.ToUpper(m.Source) }),
		"short digest":     edit(func(m *broadcastManifest) { m.Digest = "abcd" }),
		"no skipped map":   edit(func(m *broadcastManifest) { m.Skipped = nil }),
		"another ID":       edit(func(m *broadcastManifest) { m.ID = bSource }),
		"unknown field":    strings.Replace(valid, `{"version":1`, `{"extra":1,"version":1`, 1),
		"trailing data":    valid + ` {}`,
		"truncated":        valid[:len(valid)-2],
	} {
		if _, err := decodeManifest([]byte(data), bBroadcast); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
}
