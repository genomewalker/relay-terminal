//go:build darwin

package daemon

import (
	"bytes"
	"encoding/binary"

	"golang.org/x/sys/unix"
)

const (
	phPlatformLinux  = false
	phPlatformDarwin = true
)

// phProcargs reads KERN_PROCARGS2 and returns the bytes after argc and the
// executable path with its padding, plus argc.
func phProcargs(pid int64, unavailable func()) ([]byte, int32) {
	raw, err := unix.SysctlRaw("kern.procargs2", int(pid))
	if err != nil || len(raw) < 4 {
		unavailable()
	}
	count := int32(binary.LittleEndian.Uint32(raw[:4]))
	end := bytes.IndexByte(raw[4:], 0)
	if end < 0 {
		phRaise(phValueError, "subsection not found")
	}
	pos := 4 + end + 1
	for pos < len(raw) && raw[pos] == 0 {
		pos++
	}
	return raw[pos:], count
}

// phProcessArguments is process_arguments(pid) on macOS: only argc arguments,
// never the following environment.
func phProcessArguments(pid int64) []string {
	raw, count := phProcargs(pid, func() { phRaise(phOSError, "Native process arguments are unavailable.") })
	if count < 1 || count > 128 {
		phRaise(phValueError, "Process argument count is unavailable.")
	}
	var result []string
	for i := int32(0); i < count; i++ {
		end := bytes.IndexByte(raw, 0)
		if end < 0 {
			phRaise(phValueError, "subsection not found")
		}
		result = append(result, phDecodeUTF8(raw[:end]))
		raw = raw[end+1:]
	}
	return result
}

// phProcessEnvironment is the entry list process_variable reads on macOS.
func phProcessEnvironment(_ *phReader, pid int64) [][]byte {
	raw, count := phProcargs(pid, func() { phRaise(phUnbound, "Process environment is unavailable.") })
	for i := int32(0); i < count; i++ {
		end := bytes.IndexByte(raw, 0)
		if end < 0 {
			phRaise(phValueError, "subsection not found")
		}
		raw = raw[end+1:]
	}
	var entries [][]byte
	for len(raw) > 0 {
		end := bytes.IndexByte(raw, 0)
		if end < 0 {
			phRaise(phValueError, "subsection not found")
		}
		if end == 0 {
			break
		}
		entries = append(entries, raw[:end])
		raw = raw[end+1:]
	}
	return entries
}

// phKernelStartNative is kernel_start's proc_bsdinfo branch.
func phKernelStartNative(r *phReader, pid any) int64 {
	key, ok := phIntKey(pid)
	if !ok {
		phRaise(phValueError, "Native process incarnation is unavailable.")
	}
	info, err := darwinProcessInfo(int(key))
	if err != nil {
		phRaise(phValueError, "Native process incarnation is unavailable.")
	}
	if int64(info.Proc.P_pid) != key || int(info.Eproc.Ucred.Uid) != r.uid {
		phRaise(phValueError, "Native process owner changed.")
	}
	return info.Proc.P_starttime.Sec*1000000 + int64(info.Proc.P_starttime.Usec)
}

// phProcessCwd is process_cwd(pid) on macOS.
func phProcessCwd(pid int64) string {
	path, err := processWorkingDirectory(int(pid))
	if err != nil {
		phRaise(phValueError, "The agent's working directory is unavailable.")
	}
	return phDecodeUTF8([]byte(path))
}
