//go:build darwin

package desktoproute

import (
	"bytes"
	"errors"
	"golang.org/x/sys/unix"
	"net"
	"os"
	goruntime "runtime"
	"syscall"
	"time"
	"unsafe"
)

func inspectProcess(pid int) (processInfo, error) {
	var result processInfo
	if pid <= 0 || pid > 1<<31-1 {
		return result, errors.New("invalid process identity")
	}
	info, e := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if e != nil || info == nil || int(info.Proc.P_pid) != pid || int(info.Eproc.Ucred.Uid) != os.Getuid() || info.Proc.P_stat == 5 {
		return result, errors.New("process is absent, ended or foreign")
	}
	start := time.Unix(info.Proc.P_starttime.Sec, 0)
	result.Start = start.UTC().Format("Mon Jan _2 15:04:05 2006")
	result.WorkStart = start.Local().Format("Mon Jan _2 15:04:05 2006")
	// PROC_INFO_CALL_PIDINFO / PROC_PIDPATHINFO: kernel executable path,
	// not argv[0] or process-authored metadata.
	var path [4096]byte
	_, _, errno := unix.Syscall6(unix.SYS_PROC_INFO, 2, uintptr(pid), 11, 0, uintptr(unsafe.Pointer(&path[0])), uintptr(len(path)))
	goruntime.KeepAlive(&path)
	result.Executable, e = decodeDarwinProcessPath(path[:], errno)
	if e != nil {
		return processInfo{}, e
	}
	return result, nil
}

// The Darwin proc_info syscall can return zero on success while filling the
// buffer. Its return value is not a reliable path length on this interface.
func decodeDarwinProcessPath(path []byte, errno syscall.Errno) (string, error) {
	if errno != 0 {
		return "", errno
	}
	end := bytes.IndexByte(path, 0)
	if end <= 0 {
		return "", errors.New("empty or unterminated process path")
	}
	return string(path[:end]), nil
}
func socketPeer(c *net.UnixConn) (pid, uid int, err error) {
	raw, e := c.SyscallConn()
	if e != nil {
		return 0, 0, e
	}
	var cred *unix.Xucred
	var se error
	e = raw.Control(func(fd uintptr) {
		cred, se = unix.GetsockoptXucred(int(fd), 0, unix.LOCAL_PEERCRED)
		if se == nil {
			pid, se = unix.GetsockoptInt(int(fd), 0, unix.LOCAL_PEERPID)
		}
	})
	if e != nil {
		return 0, 0, e
	}
	if se != nil {
		return 0, 0, se
	}
	if cred.Version != 0 || pid <= 0 {
		return 0, 0, errors.New("invalid kernel socket credentials")
	}
	return pid, int(cred.Uid), nil
}
