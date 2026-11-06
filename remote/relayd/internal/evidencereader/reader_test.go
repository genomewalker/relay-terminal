package evidencereader

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
)

const testContract = "c70e78fa89c0ba9c5bfdac261c74b83fb954d6a984cfcd9c3af0143dce4dc3c8"

type fixture struct {
	root, outside, allowlist, allowlistSHA string
	entries                                []entry
}

func write(t *testing.T, path, content string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return digest([]byte(content))
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	base := t.TempDir()
	f := &fixture{root: filepath.Join(base, "evidence"), outside: filepath.Join(base, "outside")}
	write(t, filepath.Join(f.outside, "secret.txt"), "outside secret\n")
	f.entries = []entry{
		{ID: "S001", Path: "papers/kapk.txt", SHA256: write(t, filepath.Join(f.root, "papers/kapk.txt"), "Kap K ancient DNA\nPermafrost site\nlate Pleistocene\n")},
		{ID: "S002", Path: "notes.md", SHA256: write(t, filepath.Join(f.root, "notes.md"), "permafrost cores were dated\nMaß unit: ü\n")},
	}
	return f
}

// save writes the allowlist (optionally edited) and returns its path and hash.
func (f *fixture) save(t *testing.T, edit func(map[string]any)) {
	t.Helper()
	value := map[string]any{"version": 1, "contract_sha256": testContract, "root": f.root, "evidence": f.entries}
	if edit != nil {
		edit(value)
	}
	raw, _ := json.Marshal(value)
	f.allowlist = filepath.Join(filepath.Dir(f.root), "allowlist.json")
	f.allowlistSHA = write(t, f.allowlist, string(raw))
}

func (f *fixture) open(t *testing.T) *Reader {
	t.Helper()
	if f.allowlist == "" {
		f.save(t, nil)
	}
	r, err := Open(f.allowlist, f.allowlistSHA, testContract)
	if err != nil {
		t.Fatalf("valid allowlist refused: %v", err)
	}
	return r
}

type reply struct {
	Result map[string]any `json:"result"`
	Error  *rpcError      `json:"error"`
}

func rpc(t *testing.T, r *Reader, method string, params any) reply {
	t.Helper()
	encoded, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 7, "method": method, "params": params})
	var out reply
	if err := json.Unmarshal(r.Handle(encoded), &out); err != nil {
		t.Fatal(err)
	}
	return out
}

// tool calls a tool and returns its decoded text, whether it was an error, and
// any JSON-RPC error code.
func tool(t *testing.T, r *Reader, name string, arguments any) (map[string]any, string, int) {
	t.Helper()
	out := rpc(t, r, "tools/call", map[string]any{"name": name, "arguments": arguments})
	if out.Error != nil {
		return nil, "", out.Error.Code
	}
	content := out.Result["content"].([]any)[0].(map[string]any)["text"].(string)
	if out.Result["isError"] == true {
		return nil, content, 0
	}
	var value map[string]any
	if err := json.Unmarshal([]byte(content), &value); err != nil {
		t.Fatalf("tool text is not JSON: %s", content)
	}
	return value, "", 0
}

func TestReaderOffersExactlyThreeReadOnlyTools(t *testing.T) {
	r := newFixture(t).open(t)
	if got := rpc(t, r, "initialize", map[string]any{"protocolVersion": "2025-06-18"}); got.Result["protocolVersion"] != ProtocolVersion {
		t.Fatalf("initialize: %v", got)
	}
	tools := rpc(t, r, "tools/list", nil).Result["tools"].([]any)
	var names []string
	for _, x := range tools {
		definition := x.(map[string]any)
		names = append(names, definition["name"].(string))
		if definition["annotations"].(map[string]any)["readOnlyHint"] != true || definition["inputSchema"].(map[string]any)["additionalProperties"] != false {
			t.Fatalf("%v is not a strict read-only tool", definition["name"])
		}
		properties := definition["inputSchema"].(map[string]any)["properties"].(map[string]any)
		for property := range properties {
			if strings.Contains(property, "path") || strings.Contains(property, "file") || strings.Contains(property, "command") {
				t.Fatalf("%v takes a %s argument", definition["name"], property)
			}
		}
	}
	if !slices.Equal(names, ToolNames) || !slices.Equal(ToolNames, []string{"list", "read", "search"}) {
		t.Fatalf("tools %q", names)
	}
	for _, method := range []string{"resources/list", "prompts/list", "resources/read", "sampling/createMessage", "shell/exec"} {
		if got := rpc(t, r, method, nil); got.Error == nil || got.Error.Code != -32601 {
			t.Fatalf("%s answered: %v", method, got)
		}
	}
}

func TestReaderServesAllowlistedEvidence(t *testing.T) {
	f := newFixture(t)
	r := f.open(t)
	listed, _, _ := tool(t, r, "list", map[string]any{})
	if listed["contract_sha256"] != testContract || len(listed["evidence"].([]any)) != 2 {
		t.Fatalf("list %v", listed)
	}
	read, _, _ := tool(t, r, "read", map[string]any{"id": "S001"})
	if read["text"] != "Kap K ancient DNA\nPermafrost site\nlate Pleistocene\n" || read["eof"] != true || read["sha256"] != f.entries[0].SHA256 {
		t.Fatalf("read %v", read)
	}
	part, _, _ := tool(t, r, "read", map[string]any{"id": "S001", "offset": 6, "limit": 7})
	if part["text"] != "ancient" || part["next_offset"] != float64(13) || part["eof"] != false {
		t.Fatalf("partial read %v", part)
	}
	// A limit inside a multi-byte rune still advances by the whole rune.
	content := "permafrost cores were dated\nMaß unit: ü\n"
	at := strings.Index(content, "ß")
	rune1, _, _ := tool(t, r, "read", map[string]any{"id": "S002", "offset": at, "limit": 1})
	if rune1["text"] != "ß" || rune1["next_offset"] != float64(at+2) {
		t.Fatalf("rune read %v", rune1)
	}
	found, _, _ := tool(t, r, "search", map[string]any{"query": "PERMAFROST"})
	matches := found["matches"].([]any)
	if len(matches) != 2 || matches[0].(map[string]any)["id"] != "S001" || matches[0].(map[string]any)["line"] != float64(2) || matches[1].(map[string]any)["id"] != "S002" {
		t.Fatalf("search %v", found)
	}
	only, _, _ := tool(t, r, "search", map[string]any{"query": "permafrost", "ids": []string{"S002"}, "max_results": 1})
	if len(only["matches"].([]any)) != 1 || only["truncated"] != true {
		t.Fatalf("scoped search %v", only)
	}
	// The stdio loop: notifications get no reply, requests get one line each.
	var out bytes.Buffer
	in := strings.NewReader(`{"jsonrpc":"2.0","method":"notifications/initialized"}` + "\n" + `{"jsonrpc":"2.0","id":1,"method":"ping"}` + "\n" + `not json` + "\n")
	if err := r.Serve(in, &out); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 2 || !strings.Contains(lines[0], `"id":1`) || !strings.Contains(lines[1], "-32700") {
		t.Fatalf("serve output %q", lines)
	}
}

func TestReaderRefusesUnlistedIDsExtraToolsAndBadArguments(t *testing.T) {
	r := newFixture(t).open(t)
	for _, args := range []map[string]any{{"id": "S003"}, {"id": "s001"}, {"id": "../notes.md"}, {"id": "notes.md"}} {
		if _, failure, code := tool(t, r, "read", args); code == 0 && !strings.Contains(failure, "not in the allowlist") {
			t.Fatalf("read %v: %q %d", args, failure, code)
		}
	}
	if _, failure, _ := tool(t, r, "search", map[string]any{"query": "secret", "ids": []string{"S001", "S999"}}); !strings.Contains(failure, "not in the allowlist") {
		t.Fatalf("search with unlisted id: %q", failure)
	}
	for _, name := range []string{"write", "shell", "exec_command", "read_file", "fetch", "list_mcp_resources", "", "Read"} {
		if _, _, code := tool(t, r, name, map[string]any{"id": "S001"}); code != -32602 {
			t.Fatalf("extra tool %q answered with code %d", name, code)
		}
	}
	bad := map[string][]map[string]any{
		"read": {{}, {"id": nil}, {"id": 1}, {"id": "S001", "path": "/etc/passwd"}, {"id": "S001", "offset": -1}, {"id": "S001", "limit": 0},
			{"id": "S001", "limit": MaxReadBytes + 1}, {"id": "S001", "offset": "0"}},
		"search": {{}, {"query": ""}, {"query": strings.Repeat("a", 257)}, {"query": "x", "root": "/"}, {"query": "x", "max_results": 0},
			{"query": "x", "max_results": MaxSearchResults + 1}, {"query": "x", "ids": "S001"}},
		"list": {{"all": true}, {"root": "/"}},
	}
	for name, cases := range bad {
		for _, args := range cases {
			if _, _, code := tool(t, r, name, args); code != -32602 {
				t.Fatalf("%s %v accepted (code %d)", name, args, code)
			}
		}
	}
}

func TestReaderRefusesPathEscapesAndBadAllowlists(t *testing.T) {
	cases := map[string]func(*testing.T, *fixture){
		"parent escape": func(_ *testing.T, f *fixture) { f.entries[0].Path = "../outside/secret.txt" },
		"absolute path": func(_ *testing.T, f *fixture) { f.entries[0].Path = filepath.Join(f.outside, "secret.txt") },
		"inner escape":  func(_ *testing.T, f *fixture) { f.entries[0].Path = "papers/../../outside/secret.txt" },
		"unclean path":  func(_ *testing.T, f *fixture) { f.entries[0].Path = "./notes.md" },
		"empty path":    func(_ *testing.T, f *fixture) { f.entries[0].Path = "" },
		"root itself":   func(_ *testing.T, f *fixture) { f.entries[0].Path = "." },
		"directory":     func(_ *testing.T, f *fixture) { f.entries[0].Path = "papers" },
		"missing file":  func(_ *testing.T, f *fixture) { f.entries[0].Path = "papers/none.txt" },
		"wrong sha":     func(_ *testing.T, f *fixture) { f.entries[0].SHA256 = f.entries[1].SHA256 },
		"uppercase sha": func(_ *testing.T, f *fixture) { f.entries[0].SHA256 = strings.ToUpper(f.entries[0].SHA256) },
		"duplicate id":  func(_ *testing.T, f *fixture) { f.entries[1].ID = "S001" },
		"bad id":        func(_ *testing.T, f *fixture) { f.entries[0].ID = "S 001" },
		"no entries":    func(_ *testing.T, f *fixture) { f.entries = nil },
		"symlink outside": func(t *testing.T, f *fixture) {
			if err := os.Symlink(filepath.Join(f.outside, "secret.txt"), filepath.Join(f.root, "link.txt")); err != nil {
				t.Fatal(err)
			}
			f.entries[0] = entry{ID: "S001", Path: "link.txt", SHA256: digest([]byte("outside secret\n"))}
		},
		"symlinked dir outside": func(t *testing.T, f *fixture) {
			if err := os.Symlink(f.outside, filepath.Join(f.root, "out")); err != nil {
				t.Fatal(err)
			}
			f.entries[0] = entry{ID: "S001", Path: "out/secret.txt", SHA256: digest([]byte("outside secret\n"))}
		},
		"fifo": func(t *testing.T, f *fixture) {
			if err := syscall.Mkfifo(filepath.Join(f.root, "pipe"), 0o600); err != nil {
				t.Fatal(err)
			}
			f.entries[0].Path = "pipe"
		},
		"too large": func(t *testing.T, f *fixture) {
			path := filepath.Join(f.root, "big.txt")
			file, _ := os.Create(path)
			_ = file.Truncate(MaxEvidenceSize + 1)
			file.Close()
			f.entries[0].Path = "big.txt"
		},
	}
	for name, mutate := range cases {
		f := newFixture(t)
		mutate(t, f)
		f.save(t, nil)
		if _, err := Open(f.allowlist, f.allowlistSHA, testContract); err == nil {
			t.Fatalf("%s: allowlist accepted", name)
		}
	}
	files := map[string]func(map[string]any){
		"other contract": func(v map[string]any) { v["contract_sha256"] = strings.Repeat("0", 64) },
		"version 2":      func(v map[string]any) { v["version"] = 2 },
		"relative root":  func(v map[string]any) { v["root"] = "evidence" },
		"unknown field":  func(v map[string]any) { v["allow_paths"] = true },
		"entry field": func(v map[string]any) {
			v["evidence"] = []map[string]any{{"id": "S001", "path": "notes.md", "sha256": strings.Repeat("a", 64), "writable": true}}
		},
	}
	for name, edit := range files {
		f := newFixture(t)
		f.save(t, edit)
		if _, err := Open(f.allowlist, f.allowlistSHA, testContract); err == nil {
			t.Fatalf("%s: allowlist accepted", name)
		}
	}
	f := newFixture(t)
	f.save(t, nil)
	for name, call := range map[string]func() error{
		"tampered bytes":    func() error { _, err := Open(f.allowlist, strings.Repeat("1", 64), testContract); return err },
		"wrong contract":    func() error { _, err := Open(f.allowlist, f.allowlistSHA, strings.Repeat("2", 64)); return err },
		"relative list":     func() error { _, err := Open("allowlist.json", f.allowlistSHA, testContract); return err },
		"bad hash argument": func() error { _, err := Open(f.allowlist, "abc", testContract); return err },
		"symlinked list": func() error {
			link := filepath.Join(filepath.Dir(f.allowlist), "list-link.json")
			_ = os.Symlink(f.allowlist, link)
			_, err := Open(link, f.allowlistSHA, testContract)
			return err
		},
		"trailing data": func() error {
			raw, _ := os.ReadFile(f.allowlist)
			raw = append(raw, []byte(" {}")...)
			sha := write(t, f.allowlist+".2", string(raw))
			_, err := Open(f.allowlist+".2", sha, testContract)
			return err
		},
	} {
		if call() == nil {
			t.Fatalf("%s: opened", name)
		}
	}
}

func TestReaderRefusesEvidenceChangedAfterStart(t *testing.T) {
	f := newFixture(t)
	r := f.open(t)
	write(t, filepath.Join(f.root, "notes.md"), "rewritten after verification\n")
	if _, failure, _ := tool(t, r, "read", map[string]any{"id": "S002"}); !strings.Contains(failure, "changed since") {
		t.Fatalf("changed file served: %q", failure)
	}
	if _, failure, _ := tool(t, r, "search", map[string]any{"query": "rewritten"}); !strings.Contains(failure, "changed since") {
		t.Fatalf("changed file searched: %q", failure)
	}
	// Swapping the file for a symlink to outside content is refused too.
	target := filepath.Join(f.root, "papers/kapk.txt")
	_ = os.Remove(target)
	if err := os.Symlink(filepath.Join(f.outside, "secret.txt"), target); err != nil {
		t.Fatal(err)
	}
	if _, failure, _ := tool(t, r, "read", map[string]any{"id": "S001"}); !strings.Contains(failure, "changed since") || strings.Contains(failure, "outside secret") {
		t.Fatalf("symlink swap served: %q", failure)
	}
}
