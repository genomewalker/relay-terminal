//go:build linux

package daemon

import (
	"errors"
	"os"
	"strconv"
	"strings"
)

func harnessProcessGroups(pid int) (int, int, error) {
	data, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return 0, 0, err
	}
	end := strings.LastIndex(string(data), ")")
	if end < 0 {
		return 0, 0, errors.New("invalid process stat")
	}
	fields := strings.Fields(string(data)[end+1:])
	if len(fields) < 6 {
		return 0, 0, errors.New("invalid process groups")
	}
	group, err := strconv.Atoi(fields[2])
	if err != nil {
		return 0, 0, err
	}
	foreground, err := strconv.Atoi(fields[5])
	return group, foreground, err
}
func harnessForegroundGroup(pid int) (int, error) {
	_, foreground, err := harnessProcessGroups(pid)
	return foreground, err
}
func harnessProcessGroup(pid int) (int, error) {
	group, _, err := harnessProcessGroups(pid)
	return group, err
}
