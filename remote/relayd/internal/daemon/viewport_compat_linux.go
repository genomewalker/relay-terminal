//go:build linux

package daemon

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"syscall"

	"github.com/creack/pty"
)

// commitLegacyWorkerViewport applies an atomic final grid to a durable worker
// that predates viewport_commit_v1. The supervisor validates the recorded
// worker identity, opens that worker's existing PTY slave through procfs, and
// notifies only its foreground process group. No process is restarted.
func commitLegacyWorkerViewport(manifest workerManifest, cols, rows uint16) error {
	if cols == 0 || rows == 0 {
		return fmt.Errorf("invalid legacy viewport %dx%d", cols, rows)
	}
	if err := validateWorkerIdentity(manifest); err != nil {
		return err
	}
	terminal, err := os.OpenFile(
		fmt.Sprintf("/proc/%d/fd/0", manifest.ShellPID),
		os.O_RDWR|syscall.O_NOCTTY,
		0,
	)
	if err != nil {
		return err
	}
	defer terminal.Close()
	current, currentErr := pty.GetsizeFull(terminal)
	knownCurrent := currentErr == nil && current != nil
	currentCols, currentRows := uint16(0), uint16(0)
	if knownCurrent {
		currentCols, currentRows = current.Cols, current.Rows
	}
	if err := pty.Setsize(terminal, &pty.Winsize{Cols: cols, Rows: rows}); err != nil {
		return err
	}
	// A changed TIOCSWINSZ already signals the foreground process group on
	// Linux. Only synthesize SIGWINCH for the unchanged-grid repaint case; this
	// gives legacy workers the same exactly-once contract as v2 workers.
	if !viewportResizeNeedsExplicitSignal(
		currentCols, currentRows, cols, rows, knownCurrent,
	) {
		return nil
	}
	processGroup, err := foregroundProcessGroupFromProc(manifest.ShellPID)
	if err != nil {
		return err
	}
	if processGroup <= 0 {
		return nil
	}
	if err := syscall.Kill(-processGroup, syscall.SIGWINCH); err != nil && err != syscall.ESRCH {
		return err
	}
	return nil
}

// TIOCGPGRP rejects a slave PTY that is not relayd's own controlling terminal.
// The durable shell remains the session leader, and Linux exposes its active
// foreground terminal process group as field 8 (`tpgid`) in /proc/<pid>/stat.
func foregroundProcessGroupFromProc(pid int) (int, error) {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return 0, err
	}
	return parseForegroundProcessGroup(string(data))
}

func parseForegroundProcessGroup(stat string) (int, error) {
	closing := strings.LastIndexByte(stat, ')')
	if closing < 0 || closing+1 >= len(stat) {
		return 0, fmt.Errorf("invalid proc stat")
	}
	fields := strings.Fields(stat[closing+1:])
	// fields starts at state (field 3), so tpgid (field 8) is index 5.
	if len(fields) <= 5 {
		return 0, fmt.Errorf("incomplete proc stat")
	}
	processGroup, err := strconv.Atoi(fields[5])
	if err != nil {
		return 0, fmt.Errorf("invalid proc tpgid: %w", err)
	}
	return processGroup, nil
}
