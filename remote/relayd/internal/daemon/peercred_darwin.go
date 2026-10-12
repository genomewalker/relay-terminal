//go:build darwin

package daemon

import (
	"fmt"
	"golang.org/x/sys/unix"
	"net"
)

// PeerCredentials uses kernel identity rather than claimed event metadata.
func PeerCredentials(connection net.Conn) (uid int, pid int, err error) {
	c, ok := connection.(*net.UnixConn)
	if !ok {
		return 0, 0, fmt.Errorf("peer credentials require a Unix socket")
	}
	raw, err := c.SyscallConn()
	if err != nil {
		return 0, 0, err
	}
	var credentials *unix.Xucred
	var peerPID int
	var socketErr error
	if err = raw.Control(func(fd uintptr) {
		credentials, socketErr = unix.GetsockoptXucred(int(fd), 0, unix.LOCAL_PEERCRED)
		if socketErr == nil {
			peerPID, socketErr = unix.GetsockoptInt(int(fd), 0, unix.LOCAL_PEERPID)
		}
	}); err != nil {
		return 0, 0, err
	}
	if socketErr != nil {
		return 0, 0, socketErr
	}
	if credentials == nil || credentials.Version != 0 || peerPID <= 0 {
		return 0, 0, fmt.Errorf("missing relayd peer credentials")
	}
	return int(credentials.Uid), peerPID, nil
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
