//go:build darwin

package main

import (
	"bytes"
	"encoding/binary"

	"golang.org/x/sys/unix"
)

func parentPID(pid int) int {
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil {
		return 0
	}
	return int(info.Eproc.Ppid)
}

// processEnviron reads a same-user process's environment from
// kern.procargs2: argc, the executable path, argv, then the environment.
func processEnviron(pid int) ([]byte, bool) {
	raw, err := unix.SysctlRaw("kern.procargs2", pid)
	if err != nil || len(raw) < 4 {
		return nil, false
	}
	argc := int(binary.LittleEndian.Uint32(raw[:4]))
	rest := raw[4:]
	end := bytes.IndexByte(rest, 0) // executable path
	if end < 0 {
		return nil, false
	}
	rest = rest[end:]
	for len(rest) > 0 && rest[0] == 0 { // padding
		rest = rest[1:]
	}
	for i := 0; i < argc; i++ {
		end = bytes.IndexByte(rest, 0)
		if end < 0 {
			return nil, false
		}
		rest = rest[end+1:]
	}
	if end = bytes.Index(rest, []byte{0, 0}); end >= 0 {
		rest = rest[:end+1]
	}
	return rest, true
}
