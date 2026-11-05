package agentaccounts

import (
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"
)

func TestTOMLParsesKeyPathsNeverValueText(t *testing.T) {
	document, err := parseTOML(`# comment
model = "o3" # trailing
[mcp_servers.db]
command = "node"
args = ["a", 'b', [1, 2.5e3], { k = "v" }]
env = { TOKEN = "prefix\", NOT_A_KEY = suffix", "QUOTED.KEY" = 'x', nested.deep = true }
[mcp_servers."web app".http_headers]
Authorization = "Bearer \u0041"
[[profiles.list]]
when = 1979
local = -0.5
[[profiles.list]]
when = +inf
mcp_servers_note.x = 0x1F
`)
	if err != nil {
		t.Fatal(err)
	}
	var paths []string
	tomlWalk(document.root, nil, func(path []string) { paths = append(paths, strings.Join(path, "/")) })
	for _, want := range []string{"mcp_servers/db/env/TOKEN", "mcp_servers/db/env/QUOTED.KEY", "mcp_servers/db/env/nested/deep",
		"mcp_servers/web app/http_headers/Authorization", "profiles/list/when", "profiles/list/mcp_servers_note/x"} {
		if !contains(paths, want) {
			t.Fatalf("missing key path %q in %v", want, paths)
		}
	}
	for _, path := range paths {
		if strings.Contains(path, "NOT_A_KEY") {
			t.Fatalf("value text became a key: %v", paths)
		}
	}
	env := document.root.table("mcp_servers").table("db").table("env")
	if env.values["TOKEN"] != `prefix", NOT_A_KEY = suffix` {
		t.Fatalf("escaped value = %q", env.values["TOKEN"])
	}
	if got := len(document.root.table("profiles").values["list"].(*tomlTableArray).tables); got != 2 {
		t.Fatalf("array of tables has %d elements", got)
	}
}

func TestTOMLRefusesInvalidOrUnsupportedSyntaxWithoutEchoingIt(t *testing.T) {
	for name, text := range map[string]string{
		"unterminated":     "a = \"SECRET_VALUE\n",
		"bad escape":       `a = "SECRET_VALUE\q"`,
		"duplicate key":    "a = 1\na = \"SECRET_VALUE\"\n",
		"header twice":     "[t]\n[t]\nb = \"SECRET_VALUE\"\n",
		"dotted then head": "t.a = 1\n[t]\nb = \"SECRET_VALUE\"\n",
		"inline extended":  "t = { a = 1 }\n[t.b]\nc = \"SECRET_VALUE\"\n",
		"multi-line basic": "a = \"\"\"SECRET_VALUE\"\"\"\n",
		"multi-line lit":   "a = '''SECRET_VALUE'''\n",
		"two on a line":    "a = 1 b = \"SECRET_VALUE\"\n",
		"bare value":       "a = SECRET_VALUE\n",
		"array of value":   "a = 1\n[[a]]\n",
		"control char":     "a = \"SECRET\x01VALUE\"\n",
		"invalid date":     "[mcp_servers.SECRET_VALUE]\ninvalid_date=2000-99-99\n",
		"valid date":       "a = 1979-05-27\n",
		"offset datetime":  "a = 1979-05-27T07:32:00Z\n",
		"local datetime":   "a = 1979-05-27 07:32:00\n",
		"invalid clock":    "a = 25:61:00\n",
		"local time":       "a = 07:32:00\n",
		"over 64 bits":     "a = 9223372036854775808\n",
		"hex over 64 bits": "a = 0x1_0000_0000_0000_0000\n",
		"inline trailing":  "a = { b = \"SECRET_VALUE\", }\n",
		"inline newline":   "a = { b = \"SECRET_VALUE\"\n}\n",
		"escape e":         "a = \"SECRET_VALUE\\e\"\n",
		"escape x":         "a = \"SECRET_VALUE\\x41\"\n",
		"bare CR comment":  "a = 1 # SECRET_VALUE\r\r\n",
	} {
		_, err := parseTOML(text)
		if err == nil {
			t.Fatalf("%s: parsed", name)
		}
		if strings.Contains(err.Error(), "SECRET") {
			t.Fatalf("%s: error echoes file content: %v", name, err)
		}
	}
}

func FuzzParseTOML(f *testing.F) {
	for _, seed := range []string{"a = 1\n", "[t]\nb = \"x\\\"y\"\n", "e = { k = [1, { x = 'y' }] }\n", "[[a.b]]\nc.d = 9223372036854775807\n", "x = \"\\u00e9\"\r\n"} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, text string) {
		document, err := parseTOML(text)
		if err != nil {
			return
		}
		// What Relay writes from a parsed table must parse back the same.
		var out strings.Builder
		tomlEmitBody(&out, nil, document.root)
		again, err := parseTOML(out.String())
		if err != nil {
			t.Fatalf("emitted TOML does not parse: %v", err)
		}
		var first, second []string
		tomlWalk(document.root, nil, func(path []string) { first = append(first, strings.Join(path, "\x00")) })
		tomlWalk(again.root, nil, func(path []string) { second = append(second, strings.Join(path, "\x00")) })
		// Values are written before sub-tables, so only the order may differ.
		sort.Strings(first)
		sort.Strings(second)
		if !reflect.DeepEqual(first, second) {
			t.Fatalf("emitted TOML changed the key paths")
		}
	})
}

func TestCodexOverridesInEveryFormNeverReachAnAccount(t *testing.T) {
	for name, server := range map[string]string{
		"inline":      "[mcp_servers.node_repl]\ncommand = \"node\"\nenv = { CODEX_HOME = \"/synthetic/main-codex\", KEEP = \"fixture\" }\n",
		"table":       "[mcp_servers.node_repl]\ncommand = \"node\"\n[mcp_servers.node_repl.env]\n\"CODEX_HOME\" = \"/synthetic/main-codex\"\nKEEP = \"fixture\"\n",
		"dotted":      "mcp_servers.node_repl.command = \"node\"\nmcp_servers.node_repl.env.CODEX_HOME = \"/synthetic/main-codex\"\nmcp_servers.node_repl.env.KEEP = \"fixture\"\n",
		"inline root": "mcp_servers = { node_repl = { command = \"node\", env = { CODEX_HOME = \"/synthetic/main-codex\", KEEP = \"fixture\" } } }\n",
	} {
		t.Run(name, func(t *testing.T) {
			home := t.TempDir()
			main := filepath.Join(home, ".codex", "config.toml")
			target := filepath.Join(home, ".codex-personal", "config.toml")
			writeFile(t, main, server)
			if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
				t.Fatal(err)
			}
			var result SyncResult
			// No other account key: the override alone must prevent linking.
			if err := syncCodexConfig(main, target, "s1", Account{Provider: "codex"}, &result); err != nil {
				t.Fatal(err)
			}
			info, err := os.Lstat(target)
			if err != nil || info.Mode()&os.ModeSymlink != 0 || result.MCP != CodexConfigMerge {
				t.Fatalf("config with CODEX_HOME was linked (mcp=%s)", result.MCP)
			}
			data, _ := os.ReadFile(target)
			if strings.Contains(string(data), "/synthetic/main-codex") || !strings.Contains(string(data), `KEEP = "fixture"`) {
				t.Fatalf("merged config:\n%s", data)
			}
			// Idempotent: a second sync changes nothing.
			var again SyncResult
			if err := syncCodexConfig(main, target, "s2", Account{Provider: "codex"}, &again); err != nil || again.MCP != MergeUnchanged {
				t.Fatalf("second sync: %v %s", err, again.MCP)
			}
			if after, _ := os.ReadFile(target); string(after) != string(data) {
				t.Fatal("second sync rewrote the file")
			}
		})
	}
}

func TestUnparseableCodexConfigIsRefusedBeforeAnyChange(t *testing.T) {
	home := t.TempDir()
	main := filepath.Join(home, ".codex", "config.toml")
	writeFile(t, main, "[mcp_servers.x]\nenv = { A = \"unterminated }\n")
	target := filepath.Join(home, ".codex-personal", "config.toml")
	writeFile(t, target, "model = \"own\"\n")
	var result SyncResult
	if err := syncCodexConfig(main, target, "s", Account{Provider: "codex"}, &result); err == nil || result.MCP != MergeRefused {
		t.Fatalf("unparseable main config was not refused: %v %s", err, result.MCP)
	}
	entries, _ := os.ReadDir(filepath.Dir(target))
	data, _ := os.ReadFile(target)
	if len(entries) != 1 || string(data) != "model = \"own\"\n" {
		t.Fatal("a refused sync changed the account directory")
	}
	if _, err := PreviewMCP(home, Account{Provider: "codex", Label: "personal", Dir: "~/.codex-personal"}); err == nil {
		t.Fatal("preview of an unparseable config was not refused")
	}
}

func TestAccountDirectoriesMayNotOverlapTheMainDirectory(t *testing.T) {
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(home, ".claude"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(home, filepath.Join(home, "alias")); err != nil {
		t.Fatal(err)
	}
	for name, accounts := range map[string][]Account{
		"inside main":       {{Provider: "claude", Label: "work"}, {Provider: "claude", Label: "p", Dir: "~/.claude/sub"}},
		"alias of main":     {{Provider: "claude", Label: "work"}, {Provider: "claude", Label: "p", Dir: filepath.Join(home, "alias", ".claude")}},
		"nested accounts":   {{Provider: "codex", Label: "work"}, {Provider: "codex", Label: "a", Dir: "~/.codex-a"}, {Provider: "codex", Label: "b", Dir: "~/.codex-a/b"}},
		"aliased duplicate": {{Provider: "codex", Label: "work"}, {Provider: "codex", Label: "a", Dir: "~/.codex-a"}, {Provider: "codex", Label: "b", Dir: filepath.Join(home, "alias", ".codex-a")}},
	} {
		if _, err := Normalize(Registry{Version: 1, Accounts: accounts}, home); err == nil {
			t.Fatalf("%s: accepted", name)
		}
	}
	// A Codex alias of the main directory folds to the default account.
	registry, err := Normalize(Registry{Version: 1, Accounts: []Account{{Provider: "codex", Label: "work", Dir: filepath.Join(home, "alias", ".codex")}}}, home)
	if err != nil || registry.Accounts[0].Dir != "" {
		t.Fatalf("Codex alias of main: %v %+v", err, registry)
	}
	// Prepare and Sync refuse an alias account without a registry, too.
	alias := Account{Provider: "claude", Label: "p", Dir: filepath.Join(home, "alias", ".claude")}
	if Prepare(home, alias) == nil {
		t.Fatal("Prepare accepted an alias of the main directory")
	}
	if _, err := Sync(home, alias, time.Unix(1, 0)); err == nil {
		t.Fatal("Sync accepted an alias of the main directory")
	}
}

func TestSyncIsRefusedWhenTheReviewedPreviewIsStale(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	config := filepath.Join(home, ".codex", "config.toml")
	writeFile(t, config, "[mcp_servers.a]\ncommand = \"node\"\nenv = { A = \"1\" }\n")
	account := Account{Provider: "codex", Label: "personal", Dir: "~/.codex-personal"}
	first, err := PreviewMCP(home, account)
	if err != nil || len(first.Fingerprint) != 64 {
		t.Fatalf("preview: %v %+v", err, first)
	}
	writeFile(t, config, "[mcp_servers.a]\ncommand = \"node\"\nenv = { A = \"1\", B = \"2\" }\n")
	second, _ := PreviewMCP(home, account)
	if second.Fingerprint == first.Fingerprint {
		t.Fatal("a new env key did not change the preview fingerprint")
	}
	// Excluding a reviewed server afterwards is the user's own choice.
	excluded := account
	excluded.MCPExclude = []string{"a"}
	if third, _ := PreviewMCP(home, excluded); third.Fingerprint != second.Fingerprint || !third.Servers[0].Excluded {
		t.Fatal("an exclusion changed the reviewed fingerprint")
	}
	if _, err := Handle(Request{Action: "sync", Provider: "codex", Label: "personal", PreviewFingerprint: first.Fingerprint}, nil); err == nil ||
		!strings.Contains(err.Error(), "changed since it was reviewed") {
		t.Fatalf("stale preview sync: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(home, ".codex-personal")); !os.IsNotExist(err) {
		t.Fatal("a refused sync created the account directory")
	}
	if response, err := Handle(Request{Action: "sync", Provider: "codex", Label: "personal", PreviewFingerprint: second.Fingerprint}, nil); err != nil || response.Sync == nil || response.Sync.Error != "" {
		t.Fatalf("current preview sync: %v %+v", err, response.Sync)
	}
}

func contains(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}
