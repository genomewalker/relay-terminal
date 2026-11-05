//go:build linux

package nativemsg

import "syscall"

func defaultSource() processSource { return procfs{root: "/proc", uid: int64(syscall.Getuid())} }

func ucred(s *pySocket) (*syscall.Ucred, error) {
	raw, err := s.conn.SyscallConn()
	if err != nil {
		return nil, fromOS(err)
	}
	var credentials *syscall.Ucred
	var socketErr error
	if err := raw.Control(func(fd uintptr) {
		credentials, socketErr = syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
	}); err != nil {
		return nil, fromOS(err)
	}
	if socketErr != nil {
		return nil, fromOS(socketErr)
	}
	return credentials, nil
}

// nativePeerOwner is the adapter's native_peer_owner: SO_PEERCRED unpacked as
// three signed ints.
func nativePeerOwner(s *pySocket) (pid, uid int64, err error) {
	credentials, err := ucred(s)
	if err != nil {
		return 0, 0, err
	}
	return int64(credentials.Pid), int64(int32(credentials.Uid)), nil
}

// checkDaemonPeer is UnixWebSocket's kernel peer check before the handshake.
func checkDaemonPeer(s *pySocket, peerPID any, uid int64) error {
	pid, owner, err := nativePeerOwner(s)
	if err != nil {
		return err
	}
	if !pyEqual(pid, peerPID) || owner != uid {
		return valueError("Native daemon kernel peer identity changed")
	}
	return nil
}
