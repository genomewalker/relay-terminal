package daemon

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNativeReaderOutputIncludesNewlineInWireBudget(t *testing.T) {
	for _, limit := range []int{0, 1, 2} {
		var out bytes.Buffer
		if err := nativeReaderOutput(&out, newPyObject(), limit); err == nil || out.Len() != 0 {
			t.Fatal("output exceeded complete wire budget", limit, out.String())
		}
	}
	var out bytes.Buffer
	if err := nativeReaderOutput(&out, newPyObject(), 3); err != nil || out.String() != "{}\n" {
		t.Fatal("exact wire budget refused", out.String(), err)
	}
}

func TestNativeAccountDirectoryMatchesStrictOperatorSelector(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	for _, bad := range []string{"/", "~", "relative", "~/../escape", "/a/../b", "/a/./b", "/a//b", "~/a/", "/a;touch", "/a\nb", "/" + strings.Repeat("a", 241)} {
		if phRaised(t, func() { phAccountDirectory(bad, "codex") }) == nil {
			t.Fatalf("accepted unsafe selector %q", bad)
		}
	}
	for _, v := range []string{"", "~/account", "/tmp/account"} {
		got := ""
		if e := phRaised(t, func() { got = phAccountDirectory(v, "codex") }); e != nil {
			t.Fatal(v, e)
		}
		want := v
		if strings.HasPrefix(v, "~/") {
			want = filepath.Join(home, v[2:])
		}
		if got != want {
			t.Fatal(v, got, want)
		}
	}
	if got := phAccountDirectory(filepath.Join(home, ".codex"), "codex"); got != "" {
		t.Fatal("default Codex account was not canonicalized", got)
	}
}

// All sixteen combinations execute the real preview code. Neither the checker
// nor the fake bindability response sends a command to an agent.
func TestNativeAccountPreviewRequiresSameFileAndExactBindableReply(t *testing.T) {
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	const session = "11111111-2222-4333-8444-555555555555"
	current := filepath.Join(home, "shared", session+".jsonl")
	phWrite(t, current, `{"type":"user","sessionId":"`+session+`","message":{"content":"hello"}}`+"\n", 0600)
	target := filepath.Join(home, "target")
	path := filepath.Join(target, "projects", "p", session+".jsonl")
	if err := os.MkdirAll(filepath.Dir(filepath.Dir(path)), 0700); err != nil {
		t.Fatal(err)
	}
	base := "/private/relay agent claude --resume " + session
	for state := 0; state < 16; state++ {
		t.Run(fmt.Sprint(state), func(t *testing.T) {
			visible, sameFile, bindable, exact := state&1 != 0, state&2 != 0, state&4 != 0, state&8 != 0
			if err := os.RemoveAll(filepath.Dir(path)); err != nil {
				t.Fatal(err)
			}
			if visible {
				if sameFile {
					if err := os.Symlink(filepath.Dir(current), filepath.Dir(path)); err != nil {
						t.Fatal(err)
					}
				} else {
					phWrite(t, path, `{"type":"user","sessionId":"`+session+`","message":{"content":"hello"}}`+"\n", 0600)
				}
			}
			r := newPHReader(context.Background())
			calls := 0
			r.run = func(args []string, timeout float64) string {
				calls++
				if !phEqualWords(args, []string{"/private/relayd", "account-transcript-check", "claude", target, path}) || timeout != 5 {
					t.Fatal("preview checker arguments changed", args, timeout)
				}
				if !bindable {
					return `{"bindable":false}`
				}
				if !exact {
					return `{"bindable":true,"unexpected":true}`
				}
				return `{"bindable":true}`
			}
			command := ""
			raised := phRaised(t, func() {
				command = r.accountMoveCommand("claude", session, current, base, "", target, "/private/relayd")
			})
			allowed := visible && sameFile && bindable && exact
			if (raised == nil) != allowed {
				t.Fatal("preview admission", state, command, raised)
			}
			if calls != 0 && !(visible && sameFile) {
				t.Fatal("checker ran before exact source proof")
			}
			if allowed && command != "CLAUDE_CONFIG_DIR="+target+" "+base {
				t.Fatal("unexpected preview command", command)
			}
		})
	}
}

func FuzzNativeAccountDirectory(f *testing.F) {
	for _, s := range []string{"~/account", "/tmp/a", "~/../escape", "/a//b", "/a;touch"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		if len(s) > 1024 {
			return
		}
		var path string
		if phRaised(t, func() { path = phAccountDirectory(s, "codex") }) != nil {
			return
		}
		if s != "" && (!phAccountDirectoryPattern.MatchString(s) || strings.Contains(s, "//") || strings.HasSuffix(s, "/")) {
			t.Fatal("invalid selector accepted")
		}
		if path != "" && (!filepath.IsAbs(path) || filepath.Clean(path) != path || strings.ContainsAny(path, "\n;\x00")) {
			t.Fatal("unsafe normalized account", path)
		}
		for _, part := range strings.Split(s, "/") {
			if part == ".." {
				t.Fatal("account traversal accepted")
			}
		}
	})
}
