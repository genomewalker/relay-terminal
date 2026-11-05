//go:build darwin

package nativemsg

import (
	"golang.org/x/sys/unix"
	"testing"
)

func TestOriginalDarwinCredentialFieldGuards(t *testing.T) {
	for _, c := range []struct {
		cred *unix.Xucred
		pid  int
	}{{nil, 123}, {&unix.Xucred{Version: 1, Uid: 501}, 123}, {&unix.Xucred{Version: 0, Uid: 501}, 0}} {
		if _, _, e := checkedDarwinPeer(c.cred, c.pid); e == nil {
			t.Fatal("invalid Darwin kernel credentials accepted", c)
		}
	}
	pid, uid, e := checkedDarwinPeer(&unix.Xucred{Version: 0, Uid: 501}, 123)
	if e != nil || pid != 123 || uid != 501 {
		t.Fatal("Darwin kernel fields changed", pid, uid, e)
	}
}
