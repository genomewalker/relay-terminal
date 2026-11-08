package main

import (
	"os"
	"os/exec"
)

// startSupervisorProcessPortable is the exec.Cmd launch every build uses
// unless the macOS disclaimed spawn is available.
func startSupervisorProcessPortable(child *exec.Cmd) (*os.Process, error) {
	if err := child.Start(); err != nil {
		return nil, err
	}
	return child.Process, nil
}
