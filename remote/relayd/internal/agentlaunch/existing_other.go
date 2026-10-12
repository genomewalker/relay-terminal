//go:build !linux

package agentlaunch

import "errors"

func CaptureExisting(directory, client string, pid int, expectedStart, expectedExecutable string) (string, error) {
	return "", errors.New("existing process argv capture is unsupported on this platform")
}
