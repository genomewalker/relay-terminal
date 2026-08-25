package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

type testWorkerManifest struct {
	WorkerPID int `json:"worker_pid"`
	ShellPID  int `json:"shell_pid"`
}

func TestSupervisorCrashPreservesPaneWorkerAndShell(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("relayd requires Unix sockets and PTYs")
	}
	temporary := t.TempDir()
	binary := filepath.Join(temporary, "relayd-test")
	build := exec.Command("go", "build", "-o", binary, ".")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build relayd: %v\n%s", err, output)
	}
	runtimeDir, err := os.MkdirTemp("/tmp", "relay-crash-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(runtimeDir) })
	stateDir := filepath.Join(temporary, "state")
	environment := append(os.Environ(), "XDG_RUNTIME_DIR="+runtimeDir, "XDG_STATE_HOME="+stateDir)
	socket := filepath.Join(runtimeDir, "relayd.sock")

	firstSupervisor, firstLog := startTestSupervisor(t, binary, socket, environment)
	firstConnection := attachTestPane(t, socket, "crash-pane", 0)
	firstWriter := protocol.NewWriter(firstConnection)
	if err := firstWriter.Write(protocol.Frame{Type: protocol.Input, Payload: []byte("export RELAY_CRASH_TEST=survived\n")}); err != nil {
		t.Fatal(err)
	}
	if err := firstWriter.Write(protocol.Frame{Type: protocol.Input, Payload: []byte("echo before:$RELAY_CRASH_TEST\n")}); err != nil {
		t.Fatal(err)
	}
	lastSequence := waitForTerminalText(t, firstConnection, "before:survived")

	manifestPath := filepath.Join(stateDir, "relay", "workers", "crash-pane.json")
	manifestData, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	var manifest testWorkerManifest
	if err := json.Unmarshal(manifestData, &manifest); err != nil {
		t.Fatal(err)
	}
	if manifest.WorkerPID <= 1 || manifest.ShellPID <= 1 {
		t.Fatalf("invalid worker manifest: %s", manifestData)
	}

	stopTestSupervisor(t, firstSupervisor, firstLog)
	_ = firstConnection.Close()
	assertProcessAlive(t, manifest.WorkerPID, "pane worker")
	assertProcessAlive(t, manifest.ShellPID, "remote shell")

	secondSupervisor, _ := startTestSupervisor(t, binary, socket, environment)
	t.Cleanup(func() {
		if secondSupervisor.Process != nil {
			_ = secondSupervisor.Process.Kill()
			_, _ = secondSupervisor.Process.Wait()
		}
		if process, findErr := os.FindProcess(manifest.WorkerPID); findErr == nil {
			_ = process.Signal(syscall.SIGTERM)
		}
	})
	secondConnection := attachTestPane(t, socket, "crash-pane", lastSequence)
	defer secondConnection.Close()
	if err := protocol.NewWriter(secondConnection).Write(protocol.Frame{
		Type: protocol.Input, Payload: []byte("echo after:$RELAY_CRASH_TEST\n"),
	}); err != nil {
		t.Fatal(err)
	}
	waitForTerminalText(t, secondConnection, "after:survived")
}

func startTestSupervisor(t *testing.T, binary, socket string, environment []string) (*exec.Cmd, *bytes.Buffer) {
	t.Helper()
	var log bytes.Buffer
	command := exec.Command(binary, "daemon", "--socket", socket)
	command.Env = environment
	command.Stdout = &log
	command.Stderr = &log
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		connection, err := net.DialTimeout("unix", socket, 50*time.Millisecond)
		if err == nil {
			hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
				Version: 1, SessionID: "_probe", Probe: true,
			})
			_ = protocol.NewWriter(connection).Write(hello)
			_ = connection.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
			frame, readErr := protocol.ReadFrame(connection)
			_ = connection.Close()
			if readErr == nil && frame.Type == protocol.Status {
				return command, &log
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	_ = command.Process.Kill()
	_, _ = command.Process.Wait()
	t.Fatalf("supervisor did not start: %s", log.String())
	return nil, nil
}

func stopTestSupervisor(t *testing.T, command *exec.Cmd, log *bytes.Buffer) {
	t.Helper()
	if err := command.Process.Kill(); err != nil {
		t.Fatalf("kill supervisor: %v", err)
	}
	if _, err := command.Process.Wait(); err != nil && !strings.Contains(err.Error(), "signal: killed") {
		t.Fatalf("wait supervisor: %v; log=%s", err, log.String())
	}
}

func attachTestPane(t *testing.T, socket, session string, lastSequence uint64) net.Conn {
	t.Helper()
	connection, err := net.DialTimeout("unix", socket, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	_ = connection.SetDeadline(time.Now().Add(3 * time.Second))
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: 1, SessionID: session, Command: "exec /bin/sh",
		Cols: 100, Rows: 30, LastSeq: lastSequence,
	})
	if err := protocol.NewWriter(connection).Write(hello); err != nil {
		t.Fatal(err)
	}
	frame, err := protocol.ReadFrame(connection)
	if err != nil {
		t.Fatal(err)
	}
	var status protocol.StatusPayload
	if frame.Type != protocol.Status || protocol.DecodeJSON(frame, &status) != nil || status.State != "attached" {
		t.Fatalf("unexpected attach response: type=%d payload=%s", frame.Type, frame.Payload)
	}
	_ = connection.SetDeadline(time.Time{})
	return connection
}

func waitForTerminalText(t *testing.T, connection net.Conn, marker string) uint64 {
	t.Helper()
	_ = connection.SetReadDeadline(time.Now().Add(3 * time.Second))
	defer connection.SetReadDeadline(time.Time{})
	var output strings.Builder
	var lastSequence uint64
	for {
		frame, err := protocol.ReadFrame(connection)
		if err != nil {
			t.Fatalf("waiting for %q: %v; output=%q", marker, err, output.String())
		}
		if frame.Type != protocol.Output {
			continue
		}
		sequence, data, err := protocol.ParseOutput(frame)
		if err != nil {
			t.Fatal(err)
		}
		lastSequence = sequence
		output.Write(data)
		if strings.Contains(output.String(), marker) {
			return lastSequence
		}
		if output.Len() > 1<<20 {
			t.Fatal(fmt.Errorf("terminal output exceeded test limit"))
		}
	}
}

func assertProcessAlive(t *testing.T, pid int, label string) {
	t.Helper()
	if err := syscall.Kill(pid, 0); err != nil {
		t.Fatalf("%s pid %d did not survive supervisor crash: %v", label, pid, err)
	}
}
