//go:build linux

package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func validateSupervisorProcess(pid int, socket string, expectedUID int) error {
	status, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "status"))
	if err != nil {
		return err
	}
	uidOK := false
	for _, line := range strings.Split(string(status), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[0] == "Uid:" {
			uid, parseErr := strconv.Atoi(fields[1])
			uidOK = parseErr == nil && uid == expectedUID
			break
		}
	}
	if !uidOK {
		return fmt.Errorf("supervisor pid %d is not owned by the current user", pid)
	}
	commandLine, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "cmdline"))
	if err != nil {
		return err
	}
	arguments := splitNullArguments(commandLine)
	if !isSupervisorCommand(arguments, socket) {
		return fmt.Errorf("pid %d is not the relayd supervisor for %s", pid, socket)
	}
	return nil
}

func splitNullArguments(value []byte) []string {
	parts := bytes.Split(bytes.TrimRight(value, "\x00"), []byte{0})
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		if len(part) > 0 {
			result = append(result, string(part))
		}
	}
	return result
}

func isSupervisorCommand(arguments []string, socket string) bool {
	if len(arguments) < 2 || arguments[1] != "daemon" {
		return false
	}
	for index := 2; index < len(arguments); index++ {
		if arguments[index] == "--socket" && index+1 < len(arguments) && arguments[index+1] == socket {
			return true
		}
		if strings.HasPrefix(arguments[index], "--socket=") && strings.TrimPrefix(arguments[index], "--socket=") == socket {
			return true
		}
	}
	return false
}
