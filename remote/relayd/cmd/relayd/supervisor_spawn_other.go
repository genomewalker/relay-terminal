//go:build !darwin || !cgo

package main

import (
	"os"
	"os/exec"
)

func startSupervisorProcess(child *exec.Cmd, _ *os.File) (*os.Process, error) {
	return startSupervisorProcessPortable(child)
}

// responsiblePID is a macOS concept; other builds have no lookup.
func responsiblePID(int) (int, bool) { return 0, false }
