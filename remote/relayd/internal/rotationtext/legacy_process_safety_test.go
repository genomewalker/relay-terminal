package rotationtext

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

const safetyHelperEnv = "RELAY_LEGACY_SAFETY_HELPER"

func safetyShellQuote(v string) string { return "'" + strings.ReplaceAll(v, "'", "'\"'\"'") + "'" }
func safetyHelperScript(t *testing.T, mode, target string) string {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "private-model")
	writeScript(t, path, "#!/bin/sh\nexport "+safetyHelperEnv+"="+safetyShellQuote(mode)+"\nexport RELAY_LEGACY_SAFETY_TARGET="+safetyShellQuote(target)+"\nexec "+safetyShellQuote(executable)+" -test.run='^TestLegacySafetyProcessHelper$' -- \"$@\"\n")
	return path
}
func safetyProcessEnv(t *testing.T, mode, root string) []string {
	t.Helper()
	return []string{"PATH=/usr/bin:/bin", "HOME=" + t.TempDir(), "DBUS_SESSION_BUS_ADDRESS=" + noBus, safetyHelperEnv + "=" + mode, "RELAY_LEGACY_SAFETY_ROOT=" + root}
}

// Invoked only as an explicitly marked private child. No real provider command,
// account directory, vault or service is reachable from these modes.
func TestLegacySafetyProcessHelper(t *testing.T) {
	mode := os.Getenv(safetyHelperEnv)
	if mode == "" {
		return
	}
	target := os.Getenv("RELAY_LEGACY_SAFETY_TARGET")
	switch mode {
	case "account":
		io.ReadAll(os.Stdin)
		args := []any{}
		past := false
		for _, v := range os.Args[1:] {
			if past {
				args = append(args, v)
			}
			if v == "--" {
				past = true
			}
		}
		record := obj{"argv": args, "env": safetyEnvMap(os.Environ())}
		if err := os.WriteFile(target, []byte(compact(record)), 0600); err != nil {
			os.Exit(31)
		}
		fmt.Print(compact(obj{"subtype": "success", "is_error": false, "structured_output": validDraft()}))
		os.Exit(0)
	case "cli", "start":
		term := make(chan os.Signal, 1)
		signal.Notify(term, syscall.SIGTERM)
		if mode == "cli" {
			io.ReadAll(os.Stdin)
		}
		connection, err := net.Dial("unix", target)
		if err != nil {
			os.Exit(32)
		}
		defer connection.Close()
		fmt.Fprintf(connection, "{\"pid\":%d,\"started\":true}\n", os.Getpid())
		<-term
		fmt.Fprintln(connection, `{"term_received":true}`)
		time.Sleep(24 * time.Hour)
		os.Exit(33)
	case "exit":
		root := os.Getenv("RELAY_LEGACY_SAFETY_ROOT")
		j, err := OpenLedgerJournal(context.Background(), root)
		if err != nil {
			os.Exit(34)
		}
		j.backend = func(context.Context, obj) any { os.Exit(23); return nil }
		j.Submit(context.Background(), safetySubmit(1, "User asked for a factual capsule."))
		os.Exit(35)
	case "signal":
		ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM)
		defer stop()
		root := os.Getenv("RELAY_LEGACY_SAFETY_ROOT")
		raw, err := RunOperation(ctx, func() (*Journal, error) { return OpenLedgerJournal(ctx, root) }, "submit", []byte(compact(safetySubmit(1, "User asked for a factual capsule."))))
		if err != nil {
			os.Exit(36)
		}
		os.Stdout.Write(raw)
		os.Exit(0)
	default:
		os.Exit(37)
	}
}
func safetyListener(t *testing.T) *net.UnixListener {
	t.Helper() // Keep the Unix path below Darwin's 104-byte limit.
	dir, err := os.MkdirTemp("/tmp", "rotation-safety-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: filepath.Join(dir, "ready"), Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	if err := listener.SetDeadline(time.Now().Add(15 * time.Second)); err != nil {
		t.Fatal(err)
	}
	return listener
}
func safetyAccept(t *testing.T, listener *net.UnixListener) (*net.UnixConn, *bufio.Reader, int) {
	t.Helper()
	connection, err := listener.AcceptUnix()
	if err != nil {
		t.Fatalf("fixture CLI never started: %v", err)
	}
	t.Cleanup(func() { connection.Close() })
	connection.SetReadDeadline(time.Now().Add(15 * time.Second))
	reader := bufio.NewReaderSize(connection, 4096)
	line, err := reader.ReadSlice('\n')
	if err != nil {
		t.Fatal(err)
	}
	record, err := safetyDecodeHandshake(line)
	if err != nil {
		t.Fatalf("invalid fixture handshake: %v", err)
	}
	return connection, reader, record.PID
}
func safetyGone(t *testing.T, pid int) {
	t.Helper()
	if err := syscall.Kill(pid, 0); err != syscall.ESRCH {
		t.Fatalf("acquired child %d was not reaped: %v", pid, err)
	}
}
func TestLegacyProcessSafety(t *testing.T) {
	ctx := context.Background()
	t.Run("test_actual_process_exit_leaves_pending_without_replay", func(t *testing.T) {
		j, root, calls := safetySecurityJournal(t)
		safetyConfigure(j, nil)
		deadline, cancel := context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
		executable, err := os.Executable()
		if err != nil {
			t.Fatal(err)
		}
		command := exec.CommandContext(deadline, executable, "-test.run=^TestLegacySafetyProcessHelper$")
		command.Env = safetyProcessEnv(t, "exit", root)
		output, err := command.CombinedOutput()
		exit, ok := err.(*exec.ExitError)
		if !ok || exit.ExitCode() != 23 {
			t.Fatalf("exit fixture: %v %q", err, output)
		}
		safetyEq(t, j.Status(safetyID(1))["status"], "pending")
		safetyEq(t, j.Submit(ctx, safetySubmit(1, "User asked for a factual capsule."))["status"], "pending")
		safetyEq(t, *calls, 0)
	})
	t.Run("test_sigterm_reaps_started_cli_and_preserves_uncertain_operation", func(t *testing.T) {
		j, root, _ := safetySecurityJournal(t)
		listener := safetyListener(t)
		cli := safetyHelperScript(t, "cli", listener.Addr().String())
		safetyConfigure(j, obj{"providers": []any{"codex_account"}, "codex_model": "fixture", "codex_path": cli})
		executable, err := os.Executable()
		if err != nil {
			t.Fatal(err)
		}
		command := exec.Command(executable, "-test.run=^TestLegacySafetyProcessHelper$")
		command.Env = safetyProcessEnv(t, "signal", root)
		var stdout, stderr bytes.Buffer
		command.Stdout = &stdout
		command.Stderr = &stderr
		if err := command.Start(); err != nil {
			t.Fatal(err)
		}
		done := make(chan error, 1)
		go func() { done <- command.Wait() }()
		finished := false
		child := 0
		defer func() {
			if !finished {
				command.Process.Kill()
				<-done
			}
			if child > 0 {
				syscall.Kill(child, syscall.SIGKILL)
			}
		}()
		_, reader, pid := safetyAccept(t, listener)
		child = pid
		// Observe real SIGTERM delivery in the started fixture, not a simulated mask.
		if err := syscall.Kill(child, syscall.SIGTERM); err != nil {
			t.Fatal(err)
		}
		line, err := reader.ReadSlice('\n')
		if err != nil {
			t.Fatal("CLI inherited blocked cancellation", err)
		}
		safetyEq(t, parseJSON(line), obj{"term_received": true})
		if err := command.Process.Signal(syscall.SIGTERM); err != nil {
			t.Fatal(err)
		}
		select {
		case err := <-done:
			finished = true
			if err != nil {
				t.Fatalf("SIGTERM host failed: %v %s", err, stderr.String())
			}
		case <-time.After(10 * time.Second):
			t.Fatal("SIGTERM host did not finish")
		}
		result := parseJSON(stdout.Bytes()).(obj)
		safetyEq(t, result["status"], "uncertain")
		safetyEq(t, result["result"].(obj)["code"], "request_outcome_unknown")
		safetyGone(t, child)
		child = 0
		j.backend = func(context.Context, obj) any { t.Fatal("cancelled operation invoked model again"); return nil }
		safetyEq(t, j.Submit(ctx, safetySubmit(1, "User asked for a factual capsule.")), result)
		safetyEq(t, j.Status(nil)["requests_today"], 1)
		safetyCode(t, "reconciliation_required", func() { j.Submit(ctx, safetySubmit(2, "User asked for a factual capsule.")) })
	})
	t.Run("test_cancellation_during_cli_start_reaps_acquired_child", func(t *testing.T) {
		listener := safetyListener(t)
		cli := safetyHelperScript(t, "start", listener.Addr().String())
		child := 0
		defer func() {
			if child > 0 {
				syscall.Kill(child, syscall.SIGKILL)
			}
		}()
		parent, cancel := context.WithCancel(ctx)
		defer cancel()
		special := &safetyStartContext{Context: parent, onFirstErr: func() { _, _, child = safetyAccept(t, listener); cancel() }}
		safetyCode(t, "request_outcome_unknown", func() {
			runCLI(special, []string{cli}, []byte("fixture"), t.TempDir(), 10*time.Second, []string{"PATH=/usr/bin:/bin"})
		})
		if child <= 1 {
			t.Fatal("cancellation did not acquire a child")
		}
		safetyGone(t, child)
		child = 0
		safetyEq(t, special.checks, 1)
	})
}

// runCLI calls Err immediately after command.Start returns. Holding that exact
// check until the private child announces itself makes this boundary reliable.
type safetyStartContext struct {
	context.Context
	once       sync.Once
	onFirstErr func()
	checks     int
}

func (c *safetyStartContext) Err() error { c.checks++; c.once.Do(c.onFirstErr); return c.Context.Err() }

type safetyHandshake struct {
	PID     int  `json:"pid"`
	Started bool `json:"started"`
}

func safetyDecodeHandshake(raw []byte) (safetyHandshake, error) {
	var r safetyHandshake
	if len(raw) > 4096 {
		return r, errors.New("fixture record bound")
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if e := d.Decode(&r); e != nil {
		return r, e
	}
	var extra any
	if e := d.Decode(&extra); e != io.EOF {
		return r, errors.New("fixture trailing frame")
	}
	if r.PID <= 1 || !r.Started {
		return r, errors.New("fixture identity missing")
	}
	return r, nil
}
func FuzzLegacySafetyHandshake(f *testing.F) {
	for _, s := range []string{`{"pid":123,"started":true}`, `{}`, `{"pid":0,"started":true}`, `{"pid":123,"started":true} {}`, `{"pid":123,"started":true,"extra":1}`} {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, b []byte) {
		r, e := safetyDecodeHandshake(b)
		if e != nil {
			return
		}
		if len(b) > 4096 || r.PID <= 1 || !r.Started {
			t.Fatal("fixture handshake authority/bound changed")
		}
		raw, e := json.Marshal(r)
		if e != nil {
			t.Fatal(e)
		}
		again, e := safetyDecodeHandshake(raw)
		if e != nil || again != r {
			t.Fatal("fixture handshake roundtrip changed")
		}
		if _, e = safetyDecodeHandshake(raw[:len(raw)-1]); e == nil {
			t.Fatal("truncated fixture frame accepted")
		}
		if _, e = safetyDecodeHandshake(append(raw, []byte(` {}`)...)); e == nil {
			t.Fatal("trailing fixture frame accepted")
		}
	})
}
