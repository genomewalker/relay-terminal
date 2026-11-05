package daemon

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/creack/pty"
	"golang.org/x/net/websocket"
)

// Opt-in real-provider test: all processes and the invalid test credential use
// a disposable home. No model prompt or real account is used.
func TestRealCodexPickerAuxiliary(t *testing.T) {
	if os.Getenv("RELAY_REAL_CODEX_PICKER_TEST") != "1" {
		t.Skip("opt-in disposable Codex test")
	}
	codex, err := exec.LookPath("codex")
	if err != nil {
		t.Fatal(err)
	}
	for _, allow := range []bool{false, true} {
		t.Run(fmt.Sprint(allow), func(t *testing.T) {
			dir, err := os.MkdirTemp("/tmp", "rpx-")
			if err != nil {
				t.Fatal(err)
			}
			defer os.RemoveAll(dir)
			if err := os.WriteFile(filepath.Join(dir, "auth.json"), []byte(`{"OPENAI_API_KEY":"sk-test-only-invalid"}`), 0600); err != nil {
				t.Fatal(err)
			}
			env := append(os.Environ(), "CODEX_HOME="+dir, "TERM=xterm-256color")
			backPath := filepath.Join(dir, "b.sock")
			backend := exec.Command(codex, "app-server", "--listen", "unix://"+backPath)
			backend.Env = env
			backend.Stdout = io.Discard
			backend.Stderr = io.Discard
			if err := backend.Start(); err != nil {
				t.Fatal(err)
			}
			defer func() { _ = backend.Process.Kill(); _ = backend.Wait() }()
			deadline := time.Now().Add(10 * time.Second)
			for {
				if _, err = os.Stat(backPath); err == nil {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("backend socket not ready")
				}
				time.Sleep(50 * time.Millisecond)
			}
			backPath, err = filepath.EvalSymlinks(backPath)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.Chmod(backPath, 0600); err != nil {
				t.Fatal(err)
			}
			dev, ino, err := codexProxySocketIdentity(backPath)
			if err != nil {
				t.Fatal(err)
			}
			start, err := processStartTime(backend.Process.Pid)
			if err != nil {
				t.Fatal(err)
			}
			p := &codexProxy{descriptor: codexProxyDescriptor{Backend: NativeCodexEndpoint{Socket: backPath, Device: dev, Inode: ino, DaemonPID: backend.Process.Pid, DaemonStart: start}}, frontendDone: make(chan struct{}, 1)}
			frontPath := filepath.Join(dir, "f.sock")
			listener, err := net.Listen("unix", frontPath)
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			if err = os.Chmod(frontPath, 0600); err != nil {
				t.Fatal(err)
			}
			var pid atomic.Int64
			srv := &http.Server{ConnContext: func(ctx context.Context, c net.Conn) context.Context {
				uid, cpid, e := PeerCredentials(c)
				if e != nil {
					return ctx
				}
				s, e := processStartTime(cpid)
				if e != nil {
					return ctx
				}
				return context.WithValue(ctx, codexProxyPeerKey{}, codexProxyPeer{uid, cpid, s})
			}, Handler: websocket.Server{Handshake: func(_ *websocket.Config, _ *http.Request) error { return nil }, Handler: func(c *websocket.Conn) {
				peer, ok := c.Request().Context().Value(codexProxyPeerKey{}).(codexProxyPeer)
				if !ok || int64(peer.pid) != pid.Load() || peer.uid != os.Getuid() {
					return
				}
				p.mu.Lock()
				active := p.active
				p.mu.Unlock()
				if !allow && active {
					return
				}
				p.serveVerifiedFrontend(peer, c)
			}}}
			go srv.Serve(listener)
			defer srv.Close()
			cmd := exec.Command(codex, "--remote", "unix://"+frontPath)
			cmd.Env = env
			cmd.Dir = dir
			terminal, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: 28, Cols: 120})
			if err != nil {
				t.Fatal(err)
			}
			pid.Store(int64(cmd.Process.Pid))
			defer func() { terminal.Close(); _ = cmd.Process.Kill(); _ = cmd.Wait() }()
			chunks := make(chan []byte, 128)
			go func() {
				buf := make([]byte, 32768)
				for {
					n, e := terminal.Read(buf)
					if n > 0 {
						b := append([]byte(nil), buf[:n]...)
						select {
						case chunks <- b:
						default:
						}
					}
					if e != nil {
						return
					}
				}
			}()
			var out strings.Builder
			sent := false
			timeout := time.After(30 * time.Second)
			for {
				select {
				case b := <-chunks:
					out.Write(b)
					s := out.String()
					if strings.Contains(string(b), "\x1b[6n") {
						_, _ = terminal.Write([]byte("\x1b[1;1R"))
					}
					if !sent && strings.Contains(s, "state=idle:app=codex") {
						_, _ = terminal.Write([]byte("/resume\r"))
						sent = true
					}
					if sent && strings.Contains(s, "Failed to start TUI session picker") {
						if allow {
							t.Fatal("picker failed after auxiliary enabled")
						}
						return
					}
					if sent && strings.Contains(s, "Resume a previous session") {
						if !allow {
							t.Fatal("picker unexpectedly worked with auxiliary disabled")
						}
						return
					}
				case <-timeout:
					t.Fatalf("picker outcome not observed; sent=%v tail=%q", sent, tailForPickerTest(out.String()))
				}
			}
		})
	}
}

func tailForPickerTest(s string) string {
	if len(s) > 1800 {
		return s[len(s)-1800:]
	}
	return s
}
