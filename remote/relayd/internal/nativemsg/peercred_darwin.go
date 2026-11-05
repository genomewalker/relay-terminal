//go:build darwin

package nativemsg

import "golang.org/x/sys/unix"

// nativePeerOwner reads LOCAL_PEERCRED and LOCAL_PEERPID (SOL_LOCAL).
func nativePeerOwner(s *pySocket) (pid, uid int64, err error) {
	raw, err := s.conn.SyscallConn()
	if err != nil {
		return 0, 0, fromOS(err)
	}
	var credentials *unix.Xucred
	var peer int
	var socketErr error
	if err := raw.Control(func(fd uintptr) {
		credentials, socketErr = unix.GetsockoptXucred(int(fd), 0, unix.LOCAL_PEERCRED)
		if socketErr == nil {
			peer, socketErr = unix.GetsockoptInt(int(fd), 0, unix.LOCAL_PEERPID)
		}
	}); err != nil {
		return 0, 0, fromOS(err)
	}
	if socketErr != nil {
		return 0, 0, fromOS(socketErr)
	}
	return checkedDarwinPeer(credentials, peer)
}

func checkedDarwinPeer(credentials *unix.Xucred, peer int) (int64, int64, error) {
	if credentials == nil || credentials.Version != 0 || peer <= 0 {
		return 0, 0, valueError("Invalid native inbox kernel credentials")
	}
	return int64(peer), int64(credentials.Uid), nil
}

// checkDaemonPeer compares only LOCAL_PEERPID, as the adapter did on Darwin.
func checkDaemonPeer(s *pySocket, peerPID any, _ int64) error {
	raw, err := s.conn.SyscallConn()
	if err != nil {
		return fromOS(err)
	}
	var peer int
	var socketErr error
	if err := raw.Control(func(fd uintptr) {
		peer, socketErr = unix.GetsockoptInt(int(fd), 0, unix.LOCAL_PEERPID)
	}); err != nil {
		return fromOS(err)
	}
	if socketErr != nil {
		return fromOS(socketErr)
	}
	if !pyEqual(int64(peer), peerPID) {
		return valueError("Native daemon kernel peer identity changed")
	}
	return nil
}
