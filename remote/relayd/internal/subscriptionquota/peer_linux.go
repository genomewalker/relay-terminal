//go:build linux

package subscriptionquota

import (
	"net"
	"syscall"
)

func checkPeer(conn *net.UnixConn, uid uint32) error {
	raw, err := conn.SyscallConn()
	if err != nil {
		return errUnavailable
	}
	var cred *syscall.Ucred
	var sockErr error
	if err := raw.Control(func(fd uintptr) {
		cred, sockErr = syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
	}); err != nil || sockErr != nil || cred == nil || cred.Uid != uid || cred.Pid <= 0 {
		return errUnavailable
	}
	return nil
}
