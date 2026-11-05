package rotationtext

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestDifferentialMain retains the canonical main-entrypoint sequence corpus
// and RunOperation over a persistent in-memory store, comparing stdout bytes.
// No API key is available, so no request can leave the machine.
func TestDifferentialMain(t *testing.T) {
	f := newCLIFixture(t)
	// Both sides see exactly this environment; CLI children inherit it.
	environment := []string{"PATH=" + os.Getenv("PATH"), "HOME=" + os.Getenv("HOME"), "TMPDIR=" + f.tmp, "DBUS_SESSION_BUS_ADDRESS=" + noBus}
	saved := os.Environ()
	os.Clearenv()
	for _, entry := range environment {
		name, value, _ := strings.Cut(entry, "=")
		os.Setenv(name, value)
	}
	t.Cleanup(func() {
		os.Clearenv()
		for _, entry := range saved {
			name, value, _ := strings.Cut(entry, "=")
			os.Setenv(name, value)
		}
	})
	accounts := enabledSettings(obj{"providers": []any{"claude_account", "anthropic_api"},
		"accounts": []any{cliAccount(obj{"auth_directory": f.auth, "cli_path": f.cli("claude-ok"), "max_requests_per_day": int64(2)})}})
	question := []any{obj{"role": "user", "content": "Why?"}}
	type call struct{ op, raw string }
	sequences := [][]call{{
		{"status", `{}`}, {"status", `{"operation_id":null}`}, {"status", `[]`}, {"status", `{"x":1}`}, {"status", `not json`},
		{"status", `{"a":1,"a":1}`}, {"abandon", `{}`}, {"submit", asciiJSON(submitRequest(opID, "e"))},
		{"configure", `{"operation_id":"` + opID + `"}`}, {"configure", `{"operation_id":"` + opID + `","settings":{},"x":1}`},
		{"configure", `{"operation_id":"` + opID + `","settings":{},"expected_configuration_id":null}`},
		{"configure", asciiJSON(obj{"operation_id": opID, "settings": enabledSettings(obj{"providers": []any{"anthropic_api", "claude_account"}, "claude_path": f.cli("claude-ok")})})},
		{"submit", asciiJSON(submitRequest(opID2, "Evidence with   and é."))},
		{"status", asciiJSON(obj{"operation_id": opID2})},
		{"submit", asciiJSON(submitRequest(opID3, "\xed\xa0\x80 is not encodable"))},
		{"assess", asciiJSON(assessRequest(opID3))},
		{"assist", asciiJSON(assistRequest(opID3, reqID, question))},
		{"submit", asciiJSON(submitRequest(opID3, strings.Repeat("x", 70000)))},
		{"submit", strings.Repeat(" ", 262145)},
		{"status", `{}`},
	}, {
		{"configure", asciiJSON(obj{"operation_id": opID, "settings": accounts})},
		{"submit", asciiJSON(submitRequest(opID2, "first"))},
		{"submit", asciiJSON(submitRequest(opID3, "second"))},
		{"submit", asciiJSON(submitRequest("cccccccccccccccccccccccccccccccc", "third"))},
		{"assess", asciiJSON(assessRequest("dddddddddddddddddddddddddddddddd"))},
		{"status", `{}`},
	}}
	for index, sequence := range sequences {
		root := filepath.Join(t.TempDir(), "workers")
		if err := os.Mkdir(root, 0o700); err != nil {
			t.Fatal(err)
		}
		rebase := map[string]string{}
		store := newMemoryStore()
		open := func() (*Journal, error) { return OpenJournal(store, nil, nil) }
		for step, c := range sequence {
			want := referenceLookup(t, fmt.Sprintf("%d/%d", index, step), c.op+"\n"+c.raw, map[string]string{f.dir: "@FIXTURE@"}, map[string]string{"TMPDIR": f.tmp}, nil, rebase)
			got, err := RunOperation(context.Background(), open, c.op, []byte(c.raw))
			if err != nil || !bytes.Equal(got, want) {
				t.Errorf("sequence %d step %d %s %s\n python: %s     go: %s (%v)", index, step, c.op, clip(c.raw, 200), clip(string(want), 1500), clip(string(got), 1500), err)
			}
		}
	}
}
