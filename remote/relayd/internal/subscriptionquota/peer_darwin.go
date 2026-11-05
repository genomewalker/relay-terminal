//go:build darwin

package subscriptionquota

import (
	"golang.org/x/sys/unix"
	"net"
)

func checkPeer(conn *net.UnixConn, uid uint32) error {
	raw, err := conn.SyscallConn()
	if err != nil {
		return errUnavailable
	}
	var cred *unix.Xucred
	var sockErr error
	if err := raw.Control(func(fd uintptr) { cred, sockErr = unix.GetsockoptXucred(int(fd), 0, unix.LOCAL_PEERCRED) }); err != nil || sockErr != nil || cred == nil || cred.Version != 0 || cred.Uid != uid {
		return errUnavailable
	}
	return nil
}
