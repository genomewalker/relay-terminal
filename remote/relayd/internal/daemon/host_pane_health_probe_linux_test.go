//go:build linux

package daemon

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// When PH_FAKE_DAEMON_DIR is set, this test binary answers the relayd
// subcommands the probe runs from fixture files. All observations remain native.
func init() {
	directory := os.Getenv("PH_FAKE_DAEMON_DIR")
	if directory == "" || len(os.Args) < 2 {
		return
	}
	switch name := os.Args[1]; name {
	case "prompt-owner-binding", "agent-process-identity", "agent-binding", "upgrade-workers", "rotation-supervisor-rpc":
		if name == "rotation-supervisor-rpc" {
			_, _ = io.ReadAll(os.Stdin)
		}
		data, _ := os.ReadFile(filepath.Join(directory, name+".out"))
		code := 0
		if rc, err := os.ReadFile(filepath.Join(directory, name+".rc")); err == nil {
			code = int(phIntText(string(rc)))
		}
		_, _ = os.Stdout.Write(data)
		os.Exit(code)
	}
}

type phLivePane struct {
	worker, shell, agent *os.Process
	workerStart          int64
	shellStart           int64
	agentStart           int64
	agentPID             int64
}

func phStartOf(t *testing.T, pid int) int64 {
	t.Helper()
	start, err := processStartTime(pid)
	if err != nil {
		t.Fatal(err)
	}
	return int64(start)
}

// phSpawnPane starts worker sh -> shell sh -> agent (a copy of sleep named
// after the provider), optionally holding transcript open as fd 3.
func phSpawnPane(t *testing.T, home, provider string, transcript *os.File) phLivePane {
	t.Helper()
	bin := filepath.Join(home, "bin")
	if err := os.MkdirAll(bin, 0o700); err != nil {
		t.Fatal(err)
	}
	sleep, err := os.ReadFile("/bin/sleep")
	if err != nil {
		t.Fatal(err)
	}
	agent := filepath.Join(bin, provider)
	if err := os.WriteFile(agent, sleep, 0o700); err != nil {
		t.Fatal(err)
	}
	phWrite(t, filepath.Join(bin, "worker.sh"), "/bin/sh \"$(dirname \"$0\")/shell.sh\" \"$@\"\n:\n", 0o700)
	phWrite(t, filepath.Join(bin, "shell.sh"), "\"$1\" 100000\n:\n", 0o700)
	command := exec.Command("/bin/sh", filepath.Join(bin, "worker.sh"), agent)
	if transcript != nil {
		command.ExtraFiles = []*os.File{transcript}
	}
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		// Only the process group this test created.
		_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
		_ = command.Wait()
	})
	pane := phLivePane{worker: command.Process}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		children := phChildren(command.Process.Pid)
		if len(children) == 1 {
			grandchildren := phChildren(children[0])
			if len(grandchildren) == 1 {
				if name, _ := os.ReadFile("/proc/" + pyStr(int64(grandchildren[0])) + "/comm"); strings.TrimSpace(string(name)) == provider {
					pane.shell, _ = os.FindProcess(children[0])
					pane.agent, _ = os.FindProcess(grandchildren[0])
					pane.agentPID = int64(grandchildren[0])
					break
				}
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	if pane.agent == nil {
		t.Fatal("live pane process tree did not start")
	}
	pane.workerStart = phStartOf(t, pane.worker.Pid)
	pane.shellStart = phStartOf(t, pane.shell.Pid)
	pane.agentStart = phStartOf(t, pane.agent.Pid)
	return pane
}

func phChildren(pid int) []int {
	data, err := os.ReadFile("/proc/" + pyStr(int64(pid)) + "/task/" + pyStr(int64(pid)) + "/children")
	if err != nil {
		return nil
	}
	var result []int
	for _, field := range strings.Fields(string(data)) {
		result = append(result, int(phIntText(field)))
	}
	return result
}

func phDaemonResponse(t *testing.T, directory, name string, value any, rc int) {
	t.Helper()
	text := ""
	switch v := value.(type) {
	case nil:
	case string:
		text = v
	default:
		data, _ := json.Marshal(v)
		text = string(data)
	}
	phWrite(t, filepath.Join(directory, name+".out"), text, 0o600)
	phWrite(t, filepath.Join(directory, name+".rc"), pyStr(int64(rc)), 0o600)
}

// TestPaneHealthLiveProbeMatchesPythonOracle runs the whole probe (inspect,
// worker and context observations) against live process trees and captured
// primary outputs, and requires byte-identical replies.
func TestPaneHealthLiveProbeMatchesPythonOracle(t *testing.T) {
	home := t.TempDir()
	daemon, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	fake := filepath.Join(home, "fake-daemon")
	state := filepath.Join(home, ".local", "state")
	t.Setenv("HOME", home)
	t.Setenv("XDG_STATE_HOME", state)
	t.Setenv("PATH", "/usr/bin:/bin")
	t.Setenv("PH_FAKE_DAEMON_DIR", fake)
	for _, name := range []string{"CLAUDE_CONFIG_DIR", "CODEX_HOME"} {
		t.Setenv(name, "")
		os.Unsetenv(name)
	}
	boot := "test-boot-" + pyStr(int64(os.Getpid()))
	session := "3c9a7d2e-1111-4222-8333-444455556666"
	transcriptPath := phWrite(t, filepath.Join(home, ".claude", "projects", "p", session+".jsonl"), phJSONLines(
		phObject{"type": "user", "sessionId": session, "message": phObject{"content": "hi"}},
		phObject{"type": "assistant", "sessionId": session, "message": phObject{"stop_reason": "end_turn"}}), 0o600)
	codexSession := "4d0b8e3f-1111-4222-8333-444455556666"
	codexPath := phWrite(t, filepath.Join(home, ".codex", "sessions", "2026", "rollout-a-"+codexSession+".jsonl"), phJSONLines(
		phObject{"type": "session_meta", "payload": phObject{"id": codexSession}},
		phObject{"type": "turn_context", "payload": phObject{"cwd": "/w", "approval_policy": "never", "sandbox_policy": phObject{"type": "danger-full-access"}}},
		phObject{"type": "event_msg", "timestamp": "2026-01-02T03:04:05Z", "payload": phObject{"type": "task_complete"}}), 0o600)
	transcript, err := os.Open(transcriptPath)
	if err != nil {
		t.Fatal(err)
	}
	defer transcript.Close()

	type scenario struct {
		name     string
		provider string
		openFile *os.File
		setup    func(pane string, live phLivePane)
	}
	manifest := func(pane string, live phLivePane, extra phObject) {
		record := phObject{"session_id": pane, "state": "running", "worker_pid": live.worker.Pid, "shell_pid": live.shell.Pid,
			"worker_start_time": live.workerStart, "node_boot_id": boot}
		for key, value := range extra {
			record[key] = value
		}
		data, _ := json.Marshal(record)
		phWrite(t, filepath.Join(state, "relay", "workers", pane+".json"), string(data), 0o600)
	}
	owner := func(pane string, live phLivePane, provider string) phObject {
		return phObject{"version": 1, "pane_id": pane, "node_boot_id": boot, "worker_pid": live.worker.Pid,
			"worker_start": live.workerStart, "shell_pid": live.shell.Pid, "shell_start": live.shellStart,
			"provider": provider, "process_id": live.agentPID, "process_start": live.agentStart,
			"session_id": session, "transcript_identity": "input:x"}
	}
	common := func(pane string, live phLivePane, provider string) {
		phDaemonResponse(t, fake, "agent-process-identity", phObject{"process_start": live.agentStart}, 0)
		phDaemonResponse(t, fake, "upgrade-workers", []any{phObject{"session_id": pane, "result": "current", "worker_pid": live.worker.Pid}}, 0)
		phDaemonResponse(t, fake, "rotation-supervisor-rpc", phObject{"v": 1, "enabled": true, "state": "idle", "generation": 7, "extra": 1}, 0)
	}
	scenarios := []scenario{
		{"claude-bound-owner", "claude", nil, func(pane string, live phLivePane) {
			manifest(pane, live, nil)
			common(pane, live, "claude")
			phDaemonResponse(t, fake, "prompt-owner-binding", owner(pane, live, "claude"), 0)
			phDaemonResponse(t, fake, "agent-binding", phObject{"version": 1, "session_id": session, "transcript_path": transcriptPath,
				"observed_at": "now", "producer": phObject{"pane_id": pane, "process_id": live.agentPID, "provider": "claude",
					"process_start": live.agentStart}}, 0)
		}},
		{"claude-recovery-owner", "claude", nil, func(pane string, live phLivePane) {
			manifest(pane, live, nil)
			common(pane, live, "claude")
			phDaemonResponse(t, fake, "prompt-owner-binding", "", 1)
			phDaemonResponse(t, fake, "agent-binding", phObject{"version": 1, "session_id": session, "transcript_path": transcriptPath,
				"producer": phObject{"pane_id": pane, "process_id": live.agentPID, "provider": "claude", "process_start": live.agentStart}}, 0)
		}},
		{"claude-unbound-open-transcript", "claude", transcript, func(pane string, live phLivePane) {
			manifest(pane, live, nil)
			common(pane, live, "claude")
			phDaemonResponse(t, fake, "prompt-owner-binding", "", 1)
			phDaemonResponse(t, fake, "agent-binding", "", 1)
		}},
		{"claude-binding-mismatch", "claude", nil, func(pane string, live phLivePane) {
			manifest(pane, live, nil)
			common(pane, live, "claude")
			phDaemonResponse(t, fake, "prompt-owner-binding", owner(pane, live, "claude"), 0)
			phDaemonResponse(t, fake, "agent-binding", phObject{"version": 1, "session_id": session,
				"producer": phObject{"pane_id": pane, "process_id": 1, "provider": "claude", "process_start": 1}}, 0)
		}},
		{"shell-owner", "claude", nil, func(pane string, live phLivePane) {
			manifest(pane, live, nil)
			common(pane, live, "claude")
			phDaemonResponse(t, fake, "prompt-owner-binding", phObject{"version": 1, "provider": "shell", "pane_id": pane,
				"process_id": live.shell.Pid, "shell_pid": live.shell.Pid, "process_start": 55, "shell_start": 55}, 0)
		}},
		{"codex-bound", "codex", nil, func(pane string, live phLivePane) {
			manifest(pane, live, nil)
			common(pane, live, "codex")
			phDaemonResponse(t, fake, "prompt-owner-binding", owner(pane, live, "codex"), 0)
			phDaemonResponse(t, fake, "agent-binding", phObject{"version": 1, "session_id": codexSession, "transcript_path": codexPath,
				"producer": phObject{"pane_id": pane, "process_id": live.agentPID, "provider": "codex", "process_start": live.agentStart}}, 0)
		}},
		{"worker-stale-start", "claude", nil, func(pane string, live phLivePane) {
			manifest(pane, live, phObject{"worker_start_time": live.workerStart + 1})
			common(pane, live, "claude")
			phDaemonResponse(t, fake, "prompt-owner-binding", owner(pane, live, "claude"), 0)
		}},
		{"context-unsupported", "claude", nil, func(pane string, live phLivePane) {
			manifest(pane, live, nil)
			common(pane, live, "claude")
			phDaemonResponse(t, fake, "prompt-owner-binding", owner(pane, live, "claude"), 0)
			phDaemonResponse(t, fake, "agent-binding", "", 1)
			phDaemonResponse(t, fake, "upgrade-workers", []any{phObject{"session_id": pane, "result": "legacy", "message": strings.Repeat("m", 300)}}, 0)
			phDaemonResponse(t, fake, "rotation-supervisor-rpc", phObject{"v": 1, "enabled": "yes"}, 0)
		}},
	}
	for index, s := range scenarios {
		t.Run(s.name, func(t *testing.T) {
			pane := "a1b2c3d4-0000-4000-8000-" + strings.Repeat("0", 11) + pyStr(int64(index))
			live := phSpawnPane(t, home, s.provider, s.openFile)
			s.setup(pane, live)
			want := phLiveReference(t, phLiveReferenceInput{Name: s.name, Pane: pane, Daemon: daemon, Boot: boot, Session: session, ClaudePath: transcriptPath, CodexPath: codexPath, Live: live})
			if want.Value == nil {
				t.Fatalf("oracle raised %s: %s", want.Raised, want.Message)
			}
			got := string(pyEncode(newPHReader(context.Background()).probe(pane, daemon), pyEncodeOptions{itemSep: ", ", keySep: ": "}))
			if got != *want.Value {
				t.Fatalf("live probe differs\n python %s\n go     %s", *want.Value, got)
			}
			t.Logf("%s: %.300s", s.name, got)
		})
	}
}
