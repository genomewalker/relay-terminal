//go:build darwin

package nativemsg

import (
	"bytes"
	"encoding/binary"
	"os"
	"runtime"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

// darwinSource reads what the adapter took from ps and lsof through the
// kernel's sysctl and proc_info interfaces.
type darwinSource struct{ uid int64 }

func defaultSource() processSource { return darwinSource{uid: int64(os.Getuid())} }

func (darwinSource) linux() bool { return false }

func darwinInfo(pid int64) (*unix.KinfoProc, bool) {
	if pid <= 0 || pid > 1<<31-1 {
		return nil, false
	}
	info, err := unix.SysctlKinfoProc("kern.proc.pid", int(pid))
	if err != nil || info == nil || int64(info.Proc.P_pid) != pid {
		return nil, false
	}
	return info, true
}

// lstart is `ps -o lstart=` with TZ=UTC and LC_ALL=C.
func lstart(info *unix.KinfoProc) string {
	return time.Unix(info.Proc.P_starttime.Sec, 0).UTC().Format("Mon Jan _2 15:04:05 2006")
}

func (d darwinSource) identity(pid int64) (string, error) {
	info, ok := darwinInfo(pid)
	if !ok || int64(info.Eproc.Ucred.Uid) != d.uid {
		return "", unbound("Process owner changed.")
	}
	return "darwin:" + lstart(info), nil
}

func (d darwinSource) epoch(pid int64) (float64, error) {
	info, ok := darwinInfo(pid)
	if !ok || int64(info.Eproc.Ucred.Uid) != d.uid {
		return 0, unbound("Process owner changed.")
	}
	return float64(info.Proc.P_starttime.Sec), nil
}

// processes names each process by argv[0], as Darwin ps prints comm.
func (d darwinSource) processes() ([]psRow, error) {
	infos, err := unix.SysctlKinfoProcSlice("kern.proc.uid", int(d.uid))
	if err != nil {
		return nil, unbound("Process discovery is unavailable.")
	}
	rows := make([]psRow, 0, len(infos))
	for _, info := range infos {
		pid := int64(info.Proc.P_pid)
		name := darwinArgv0(pid)
		if name == "" {
			raw := info.Proc.P_comm[:]
			if end := bytes.IndexByte(raw, 0); end >= 0 {
				raw = raw[:end]
			}
			name = string(raw)
		}
		rows = append(rows, psRow{pid: pid, ppid: int64(info.Eproc.Ppid), uid: int64(info.Eproc.Ucred.Uid), comm: name})
	}
	return rows, nil
}

func procargs(pid int64) ([]byte, error) {
	if pid <= 0 || pid > 1<<31-1 {
		return nil, unix.EINVAL
	}
	return unix.SysctlRaw("kern.procargs2", int(pid))
}

func darwinArgv0(pid int64) string {
	raw, err := procargs(pid)
	if err != nil || len(raw) < 4 {
		return ""
	}
	end := bytes.IndexByte(raw[4:], 0)
	if end < 0 {
		return ""
	}
	pos := 4 + end
	for pos < len(raw) && raw[pos] == 0 {
		pos++
	}
	argv0 := raw[pos:]
	if end := bytes.IndexByte(argv0, 0); end >= 0 {
		argv0 = argv0[:end]
	}
	return string(argv0)
}

func (darwinSource) executable(int64) (string, error) {
	return "", unix.ENOTSUP
}

// openPaths lists the process's open vnode descriptors (lsof -Fn's n/ lines
// for descriptors; lsof also lists cwd and mapped images, which never name
// a transcript).
func (darwinSource) openPaths(pid int64) ([]string, error) {
	if pid <= 0 || pid > 1<<31-1 {
		return nil, unbound("Process discovery is unavailable.")
	}
	buffer := make([]byte, 8*8192)
	n, _, errno := unix.Syscall6(unix.SYS_PROC_INFO, 2, uintptr(pid), 1, 0,
		uintptr(unsafe.Pointer(&buffer[0])), uintptr(len(buffer)))
	runtime.KeepAlive(buffer)
	if errno != 0 {
		return nil, nil
	}
	var result []string
	for offset := 0; offset+8 <= int(n); offset += 8 {
		fd := int32(binary.LittleEndian.Uint32(buffer[offset:]))
		if binary.LittleEndian.Uint32(buffer[offset+4:]) != 1 { // PROX_FDTYPE_VNODE
			continue
		}
		// vnode_fdinfowithpath: proc_fileinfo (24) + vnode_info (152) + path.
		var info [24 + 152 + 1024]byte
		got, _, errno := unix.Syscall6(unix.SYS_PROC_INFO, 3, uintptr(pid), 2, uintptr(fd),
			uintptr(unsafe.Pointer(&info[0])), uintptr(len(info)))
		runtime.KeepAlive(&info)
		if errno != 0 || got != uintptr(len(info)) {
			continue
		}
		path := info[176:]
		if end := bytes.IndexByte(path, 0); end >= 0 {
			path = path[:end]
		}
		if len(path) > 0 && path[0] == '/' {
			result = append(result, string(path))
		}
	}
	return result, nil
}

// environment parses KERN_PROCARGS2 as the adapter's ctypes reader did.
func (darwinSource) environment(pid int64) ([][]byte, error) {
	raw, err := procargs(pid)
	if err != nil || len(raw) < 4 {
		return nil, unbound("Process environment is unavailable.")
	}
	notFound := valueError("subsection not found")
	count := int32(binary.LittleEndian.Uint32(raw))
	end := bytes.IndexByte(raw[4:], 0)
	if end < 0 {
		return nil, notFound
	}
	pos := 4 + end + 1
	for pos < len(raw) && raw[pos] == 0 {
		pos++
	}
	for i := int32(0); i < count; i++ {
		if pos > len(raw) {
			return nil, notFound
		}
		end := bytes.IndexByte(raw[pos:], 0)
		if end < 0 {
			return nil, notFound
		}
		pos += end + 1
	}
	var entries [][]byte
	for pos < len(raw) {
		end := bytes.IndexByte(raw[pos:], 0)
		if end < 0 {
			return nil, notFound
		}
		if end == 0 {
			break
		}
		entries = append(entries, raw[pos:pos+end])
		pos += end + 1
	}
	return entries, nil
}
