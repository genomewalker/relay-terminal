//go:build darwin

package daemon

import (
	"bytes"
	"fmt"
	"golang.org/x/sys/unix"
	"runtime"
	"strings"
	"time"
	"unsafe"
)

func nodeBootID() (string, error) {
	id, err := unix.Sysctl("kern.bootsessionuuid")
	if err != nil {
		return "", err
	}
	id = strings.TrimSpace(id)
	if id == "" {
		return "", fmt.Errorf("kernel boot identity is unavailable")
	}
	return "darwin:" + id, nil
}

func darwinProcessInfo(pid int) (*unix.KinfoProc, error) {
	if pid <= 0 {
		return nil, fmt.Errorf("invalid PID")
	}
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil {
		return nil, err
	}
	if info == nil || int(info.Proc.P_pid) != pid || info.Proc.P_starttime.Sec <= 0 ||
		info.Proc.P_starttime.Usec < 0 || info.Proc.P_starttime.Usec >= 1000000 {
		return nil, fmt.Errorf("process identity is unavailable")
	}
	return info, nil
}

func processStartTime(pid int) (uint64, error) {
	info, err := darwinProcessInfo(pid)
	if err != nil {
		return 0, err
	}
	sec := uint64(info.Proc.P_starttime.Sec)
	if sec > (^uint64(0)-999999)/1000000 {
		return 0, fmt.Errorf("invalid start time")
	}
	return sec*1000000 + uint64(info.Proc.P_starttime.Usec), nil
}

// Keep the existing peer discovery wire format. Worker incarnation validation
// uses the full microsecond kernel identity through processStartTime.
func processStartIdentity(pid int) (string, error) {
	info, err := darwinProcessInfo(pid)
	if err != nil {
		return "", err
	}
	return time.Unix(info.Proc.P_starttime.Sec, 0).UTC().Format("Mon Jan _2 15:04:05 2006"), nil
}

func processWorkingDirectory(pid int) (string, error) {
	if pid <= 1 {
		return "", fmt.Errorf("invalid PID")
	}
	// Darwin proc_vnodepathinfo contains two vnode_info_path records, each
	// with a 152-byte vnode_info followed by MAXPATHLEN (1024) path bytes.
	// Layout is identical on supported Darwin arm64 and amd64 SDKs.
	var info [2352]byte
	n, _, errno := unix.Syscall6(unix.SYS_PROC_INFO, 2, uintptr(pid), 9, 0, uintptr(unsafe.Pointer(&info[0])), uintptr(len(info)))
	runtime.KeepAlive(&info)
	if errno != 0 {
		return "", fmt.Errorf("process working directory lookup: %w", errno)
	}
	if n != uintptr(len(info)) {
		return "", fmt.Errorf("incomplete process working directory information")
	}
	path := info[152:1176]
	end := bytes.IndexByte(path, 0)
	if end <= 0 || path[0] != '/' {
		return "", fmt.Errorf("invalid process working directory")
	}
	return string(path[:end]), nil
}
