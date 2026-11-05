//go:build !darwin && !linux

package desktoproute

import (
	"errors"
	"net"
)

func inspectProcess(int) (processInfo, error) {
	return processInfo{}, errors.New("native process identity unsupported on this platform")
}
func socketPeer(*net.UnixConn) (int, int, error) {
	return 0, 0, errors.New("kernel socket credentials unsupported on this platform")
}
