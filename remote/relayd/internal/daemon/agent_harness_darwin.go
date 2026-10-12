//go:build darwin

package daemon

import (
	"bytes"
	"encoding/binary"
	"errors"
	"golang.org/x/sys/unix"
	"strings"
)

// Only the executable/argv section is inspected; environment values are never
// decoded or exposed by identification.
func darwinHarnessArguments(pid int) (string, error) {
	raw, err := unix.SysctlRaw("kern.procargs2", pid)
	if err != nil {
		return "", err
	}
	if len(raw) < 5 || len(raw) > 1<<20 {
		return "", errors.New("invalid process arguments")
	}
	argc := int(binary.LittleEndian.Uint32(raw[:4]))
	if argc < 1 || argc > 4096 {
		return "", errors.New("invalid argument count")
	}
	end := bytes.IndexByte(raw[4:], 0)
	if end < 0 {
		return "", errors.New("invalid executable argument")
	}
	offset := 4 + end + 1
	for offset < len(raw) && raw[offset] == 0 {
		offset++
	}
	args := []string{}
	for i := 0; i < argc && i < 16; i++ {
		if offset >= len(raw) {
			return "", errors.New("incomplete process arguments")
		}
		end := bytes.IndexByte(raw[offset:], 0)
		if end < 0 {
			return "", errors.New("incomplete process argument")
		}
		args = append(args, string(raw[offset:offset+end]))
		offset += end + 1
	}
	return strings.Join(args, "\x00"), nil
}

func harnessForegroundGroup(pid int) (int, error) {
	info, err := darwinProcessInfo(pid)
	if err != nil {
		return 0, err
	}
	return int(info.Eproc.Tpgid), nil
}
func harnessProcessGroup(pid int) (int, error) {
	info, err := darwinProcessInfo(pid)
	if err != nil {
		return 0, err
	}
	return int(info.Eproc.Pgid), nil
}
