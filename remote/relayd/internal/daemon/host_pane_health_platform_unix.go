//go:build linux || darwin

package daemon

import (
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

func phStatUID(info os.FileInfo) int {
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		return int(stat.Uid)
	}
	return -1
}

// phStatDevIno is (st_dev, st_ino).
func phStatDevIno(info os.FileInfo) (int64, uint64) {
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		return int64(stat.Dev), uint64(stat.Ino)
	}
	return -1, 0
}

// phMachine is os.uname().machine.
func phMachine() string {
	var name unix.Utsname
	if err := unix.Uname(&name); err != nil {
		phRaiseOS(err)
	}
	return unix.ByteSliceToString(name.Machine[:])
}
