package desktoproute

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// Native provider sockets are authenticated with their peer token and exact
// process identity. The historical provider registry contract is socket + UID;
// unlike desktop/Work IPC, it does not require mode 0600. Keep these separate.
func nativePeerSocketInfo(info os.FileInfo, uid int) bool {
	owner, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(owner.Uid) == uid && info.Mode()&os.ModeSocket != 0
}
func checkPeerSocket(path string) (socketIdentity, error) {
	if !filepath.IsAbs(path) {
		return socketIdentity{}, errors.New("native socket must be absolute")
	}
	info, e := os.Lstat(path)
	if e != nil {
		return socketIdentity{}, e
	}
	if !nativePeerSocketInfo(info, os.Getuid()) {
		return socketIdentity{}, errors.New("native socket must be owned by this user")
	}
	owner := info.Sys().(*syscall.Stat_t)
	return socketIdentity{path, uint64(owner.Dev), uint64(owner.Ino)}, nil
}
func dialPeerSocket(ctx context.Context, path string) (*net.UnixConn, error) {
	before, e := checkPeerSocket(path)
	if e != nil {
		return nil, e
	}
	conn, e := (&net.Dialer{Timeout: 3 * time.Second}).DialContext(ctx, "unix", path)
	if e != nil {
		return nil, e
	}
	socket := conn.(*net.UnixConn)
	after, e := checkPeerSocket(path)
	if e != nil || before != after {
		socket.Close()
		return nil, errors.New("native socket changed while connecting")
	}
	_, uid, e := socketPeer(socket)
	if e != nil || uid != os.Getuid() {
		socket.Close()
		return nil, errors.New("native socket kernel owner changed")
	}
	deadline := time.Now().Add(5 * time.Second)
	if when, ok := ctx.Deadline(); ok && when.Before(deadline) {
		deadline = when
	}
	socket.SetDeadline(deadline)
	return socket, nil
}
