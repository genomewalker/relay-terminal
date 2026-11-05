//go:build linux

package agentlaunch

import (
	"errors"
	"path/filepath"
	"strconv"
)

// ProcessEnvironment returns the named variables from pid's initial environment.
func ProcessEnvironment(pid int, keys ...string) (map[string]string, error) {
	if pid <= 1 {
		return nil, errors.New("invalid agent process")
	}
	raw, err := boundedRead(filepath.Join("/proc", strconv.Itoa(pid), "environ"))
	if err != nil {
		return nil, errors.New("agent environment unavailable")
	}
	return selectEnvironment(raw, keys)
}
