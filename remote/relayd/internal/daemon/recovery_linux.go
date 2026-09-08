//go:build linux

package daemon

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// RecoverWorker selects an existing authenticated PTY owner explicitly. It does
// not restart or signal any worker or child. A separate node-local selection
// survives legacy workers continuing to write their original shared manifest.
func (server *Server) RecoverWorker(sessionID string, pid int) error {
	if !validSessionID.MatchString(sessionID) || pid <= 1 {
		return errors.New("invalid recovery target")
	}
	root := filepath.Join("/proc", strconv.Itoa(pid))
	info, err := os.Stat(root)
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(stat.Uid) != os.Getuid() {
		return errors.New("worker belongs to another user")
	}
	start, err := processStartTime(pid)
	if err != nil {
		return err
	}
	raw, err := os.ReadFile(filepath.Join(root, "cmdline"))
	if err != nil {
		return err
	}
	args := strings.Split(strings.TrimRight(string(raw), "\x00"), "\x00")
	if len(args) < 2 || args[1] != "worker" {
		return errors.New("target is not a Relay pane worker")
	}
	options := make(map[string]string)
	for i := 2; i+1 < len(args); i += 2 {
		options[args[i]] = args[i+1]
	}
	if options["--session"] != sessionID {
		return errors.New("worker owns a different session")
	}
	socketPath := options["--socket"]
	socketInfo, err := os.Lstat(socketPath)
	if errors.Is(err, os.ErrNotExist) {
		return errors.New("worker is alive but its attachment socket was deleted; ordinary attachment cannot recover it (the agent process has not been stopped)")
	}
	if err != nil {
		return err
	}
	socketStat, ok := socketInfo.Sys().(*syscall.Stat_t)
	if !ok || int(socketStat.Uid) != os.Getuid() || socketInfo.Mode()&os.ModeSocket == 0 {
		return errors.New("invalid worker socket")
	}
	environment, err := os.ReadFile(filepath.Join(root, "environ"))
	if err != nil {
		return err
	}
	token := ""
	for _, variable := range strings.Split(string(environment), "\x00") {
		if strings.HasPrefix(variable, "RELAY_WORKER_TOKEN=") {
			token = strings.TrimPrefix(variable, "RELAY_WORKER_TOKEN=")
		}
	}
	if token == "" {
		return errors.New("worker authentication key unavailable")
	}
	boot, err := nodeBootID()
	if err != nil {
		return err
	}
	children, err := os.ReadFile(filepath.Join(root, "task", strconv.Itoa(pid), "children"))
	if err != nil {
		return err
	}
	shellPID := 0
	for _, child := range strings.Fields(string(children)) {
		candidate, parseErr := strconv.Atoi(child)
		if parseErr == nil {
			shellPID = candidate
			break
		}
	}
	if shellPID <= 1 {
		return errors.New("worker no longer has a shell process")
	}
	cwd, _ := processWorkingDirectory(shellPID)
	manifest := workerManifest{Version: workerProtocolVersion, SessionID: sessionID,
		WorkerPID: pid, WorkerStartTime: start, ShellPID: shellPID, NodeBootID: boot,
		SocketPath: socketPath, Token: token, WorkingDirectory: cwd,
		State: "running", CreatedAt: time.Now().UTC()}
	state, err := server.workerState(manifest)
	if err != nil || state != "ready" {
		return fmt.Errorf("cannot authenticate a ready worker (state %q): %v", state, err)
	}
	if err := validateWorkerIdentity(manifest); err != nil {
		return err
	}
	return storeManifest(server.recoveredManifestPath(sessionID), manifest)
}
