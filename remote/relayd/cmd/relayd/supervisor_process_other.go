//go:build !linux

package main

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

func validateSupervisorProcess(pid int, socket string, expectedUID int) error {
	uidOutput, err := exec.Command("ps", "-o", "uid=", "-p", strconv.Itoa(pid)).Output()
	if err != nil || strings.TrimSpace(string(uidOutput)) != strconv.Itoa(expectedUID) {
		return fmt.Errorf("supervisor pid %d is not owned by the current user", pid)
	}
	commandOutput, err := exec.Command("ps", "-o", "command=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return err
	}
	command := string(commandOutput)
	if !strings.Contains(command, " daemon ") ||
		!(strings.Contains(command, "--socket "+socket) || strings.Contains(command, "--socket="+socket)) {
		return fmt.Errorf("pid %d is not the relayd supervisor for %s", pid, socket)
	}
	return nil
}
