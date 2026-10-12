//go:build !linux && !darwin

package daemon

import "errors"

func harnessForegroundGroup(pid int) (int, error) {
	return 0, errors.New("foreground process identification unavailable")
}
func harnessProcessGroup(pid int) (int, error) {
	return 0, errors.New("process identification unavailable")
}
