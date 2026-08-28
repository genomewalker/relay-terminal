//go:build linux

package daemon

import (
	"fmt"
	"net"
	"syscall"
)

// RequirePeerUID authenticates the process on the other end of a Unix socket.
// Filesystem permissions remain the first barrier; SO_PEERCRED prevents a
// pre-bound or inherited socket from impersonating the user's daemon.
func PeerCredentials(connection net.Conn) (uid int, pid int, err error) {
	unixConnection, ok := connection.(*net.UnixConn)
	if !ok {
		return 0, 0, fmt.Errorf("peer credentials require a Unix socket")
	}
	raw, err := unixConnection.SyscallConn()
	if err != nil {
		return 0, 0, err
	}
	var credentials *syscall.Ucred
	var socketErr error
	if err := raw.Control(func(fd uintptr) {
		credentials, socketErr = syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
	}); err != nil {
		return 0, 0, err
	}
	if socketErr != nil {
		return 0, 0, socketErr
	}
	if credentials == nil {
		return 0, 0, fmt.Errorf("missing relayd peer credentials")
	}
	return int(credentials.Uid), int(credentials.Pid), nil
}

func RequirePeerUID(connection net.Conn, expected int) error {
	uid, _, err := PeerCredentials(connection)
	if err != nil {
		return err
	}
	if uid != expected {
		return fmt.Errorf("relayd peer uid mismatch")
	}
	return nil
}
