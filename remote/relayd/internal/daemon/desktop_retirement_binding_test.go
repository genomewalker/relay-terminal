package daemon

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// These are the remaining named assertions in the archived frontend and stock
// proxy tests, run against the production conversation reader.
func TestDesktopRetiredStockProxyRequiredKernelFields(t *testing.T) {
	want := "stock-proxy:" + strings.Repeat("a", 64)
	if got := phStockProxyIdentity(conversationStockBinding()); got != want {
		t.Fatal("exact stock identity changed", got)
	}
	for _, key := range []string{"proxy_pid", "proxy_start", "control_inode", "connection", "selection"} {
		t.Run(key, func(t *testing.T) {
			binding := conversationStockBinding()
			binding.Get("stock_proxy").(*pyObject).Set(key, int64(0))
			requireConversationRefusal(t, "live identity proof", func() { phStockProxyIdentity(binding) })
		})
	}
	if got := phStockProxyIdentity(pyObj("source", "historical_cache")); got != "" {
		t.Fatal("historical cache invented a live proxy identity", got)
	}
}

func TestDesktopRetiredUnwrittenProxyNeverFabricatesHistory(t *testing.T) {
	r, _ := conversationFixture(t, "codex", "chosen", "")
	r.binding = func(string, string, int64, string) *pyObject { return conversationStockBinding() }
	r.transcript = func(int64, string) (string, string) {
		phRaise(phUnbound, "No real history")
		return "", ""
	}
	requireConversationRefusal(t, "No real history", func() { r.conversationSnapshot("pane", 11, "reader", nil, "", "") })
}

func TestDesktopRetiredNativeInstallerProviderPaths(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	versions := filepath.Join(home, ".local/share/claude/versions")
	image := phWrite(t, filepath.Join(versions, "2.1.295"), "", 0600)
	other := phWrite(t, filepath.Join(home, "bin/2.1.295"), "", 0600)
	r := newPHReader(context.Background())
	for _, c := range []struct{ path, want string }{
		{image, "claude"}, {"/usr/local/bin/claude", "claude"}, {"codex", "codex"},
		{other, ""}, {filepath.Join(versions, "9.9.9"), ""}, {"2.1.295", ""}, {versions, ""},
	} {
		if got := r.provider(c.path); got != c.want {
			t.Fatalf("provider path %q: got %q want %q", c.path, got, c.want)
		}
	}
}

func TestDesktopRetiredProviderProcessHelper(t *testing.T) {
	if os.Getenv("RELAY_RETIREMENT_PROVIDER_HELPER") != "1" {
		return
	}
	fmt.Fprintln(os.Stdout, "ready")
	io.Copy(io.Discard, os.Stdin)
	os.Exit(0)
}

func TestDesktopRetiredLinuxPinnedProviderInventory(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("requires the actual Linux /proc executable identity")
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	binary, e := os.Executable()
	if e != nil {
		t.Fatal(e)
	}
	raw, e := os.ReadFile(binary)
	if e != nil {
		t.Fatal(e)
	}
	for _, scenario := range []string{"pinned-outer", "unowned-version", "exited-image"} {
		t.Run(scenario, func(t *testing.T) {
			path := filepath.Join(home, ".local/share/claude/versions/2.1.301")
			if scenario == "unowned-version" {
				path = filepath.Join(home, "bin/2.1.301")
			}
			if e := os.MkdirAll(filepath.Dir(path), 0700); e != nil {
				t.Fatal(e)
			}
			if e := os.WriteFile(path, raw, 0700); e != nil {
				t.Fatal(e)
			}
			cmd := exec.Command(path, "-test.run=^TestDesktopRetiredProviderProcessHelper$")
			cmd.Env = append(os.Environ(), "RELAY_RETIREMENT_PROVIDER_HELPER=1")
			in, e := cmd.StdinPipe()
			if e != nil {
				t.Fatal(e)
			}
			out, e := cmd.StdoutPipe()
			if e != nil {
				t.Fatal(e)
			}
			if e := cmd.Start(); e != nil {
				t.Fatal(e)
			}
			done := false
			defer func() {
				in.Close()
				if !done {
					cmd.Process.Kill()
					cmd.Wait()
				}
			}()
			ready := make([]byte, 6)
			if _, e := io.ReadFull(out, ready); e != nil || string(ready) != "ready\n" {
				t.Fatal("fixture not ready", e)
			}
			pid := cmd.Process.Pid
			if scenario == "exited-image" {
				in.Close()
				if e := cmd.Wait(); e != nil {
					t.Fatal(e)
				}
				done = true
			}
			r := newPHReader(context.Background())
			r.run = func(args []string, timeout float64) string {
				if len(args) != 5 || args[0] != "/bin/ps" || timeout != 4 {
					t.Fatal("inventory command changed", args, timeout)
				}
				text := fmt.Sprintf("11 1 %d bash\n%d 11 %d 2.1.301\n", os.Getuid(), pid, os.Getuid())
				if scenario == "pinned-outer" {
					text += fmt.Sprintf("%d %d %d codex\n", pid+1, pid, os.Getuid())
				}
				return text
			}
			if scenario == "pinned-outer" {
				got, kind := r.agent(11, "", "")
				if got != int64(pid) || kind != "claude" {
					t.Fatal("pinned outer provider lost", got, kind)
				}
			} else {
				requireConversationRefusal(t, "unique foreground", func() { r.agent(11, "", "") })
			}
		})
	}
}
