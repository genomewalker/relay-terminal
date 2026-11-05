package providersetup

import "golang.org/x/sys/unix"

func syncDir(fd int) error { return unix.Fsync(fd) }
func closeFD(fd int)       { _ = unix.Close(fd) }
