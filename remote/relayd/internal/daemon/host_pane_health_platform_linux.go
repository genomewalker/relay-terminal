//go:build linux

package daemon

import (
	"bytes"
	"os"
)

const (
	phPlatformLinux  = true
	phPlatformDarwin = false
)

// phProcessArguments is process_arguments(pid) on Linux.
func phProcessArguments(pid int64) []string {
	raw, err := os.ReadFile("/proc/" + pyStr(pid) + "/cmdline")
	if err != nil {
		phRaiseOS(err)
	}
	if len(raw) > 65536 {
		phRaise(phValueError, "Process arguments exceed the maintenance limit.")
	}
	var result []string
	for _, part := range bytes.Split(bytes.TrimRight(raw, "\x00"), []byte{0}) {
		result = append(result, phDecodeUTF8(part))
	}
	return result
}

// phProcessEnvironment is the entry list process_variable reads on Linux.
func phProcessEnvironment(_ *phReader, pid int64) [][]byte {
	raw, err := os.ReadFile("/proc/" + pyStr(pid) + "/environ")
	if err != nil {
		phRaiseOS(err)
	}
	if len(raw) > 1<<20 {
		phRaise(phUnbound, "Process environment exceeds its limit.")
	}
	return bytes.Split(raw, []byte{0})
}

// phKernelStartNative is never reached on Linux: kernel_start reads identity.
func phKernelStartNative(_ *phReader, _ any) int64 {
	phRaise(phValueError, "Native process incarnation is unavailable.")
	return 0
}

// phProcessCwd is process_cwd(pid) on Linux.
func phProcessCwd(pid int64) string {
	path, err := os.Readlink("/proc/" + pyStr(pid) + "/cwd")
	if err != nil {
		phRaiseOS(err)
	}
	return path
}
