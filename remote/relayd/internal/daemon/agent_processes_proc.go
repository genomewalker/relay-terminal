//go:build !darwin

package daemon

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func descendantAgentProcesses(rootPID int) map[int]string {
	result := make(map[int]string)
	stack := []int{rootPID}
	seen := make(map[int]bool)
	for len(stack) > 0 {
		pid := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if seen[pid] {
			continue
		}
		seen[pid] = true
		command, _ := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "comm"))
		arguments, _ := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "cmdline"))
		if agent := classifyAgentProcess(string(command), string(arguments)); agent != "" {
			result[pid] = agent
		}
		children, _ := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "task", strconv.Itoa(pid), "children"))
		for _, value := range strings.Fields(string(children)) {
			if child, err := strconv.Atoi(value); err == nil {
				stack = append(stack, child)
			}
		}
	}
	return result
}

func descendantAgentProcess(rootPID int) (string, int) {
	stack := []int{rootPID}
	seen := make(map[int]bool)
	for len(stack) > 0 {
		pid := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if seen[pid] {
			continue
		}
		seen[pid] = true
		command, _ := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "comm"))
		arguments, _ := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "cmdline"))
		if agent := classifyAgentProcess(string(command), string(arguments)); agent != "" {
			return agent, pid
		}
		children, _ := os.ReadFile(filepath.Join(
			"/proc", strconv.Itoa(pid), "task", strconv.Itoa(pid), "children",
		))
		for _, value := range strings.Fields(string(children)) {
			if child, err := strconv.Atoi(value); err == nil {
				stack = append(stack, child)
			}
		}
	}
	return "", 0
}
