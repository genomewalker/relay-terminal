//go:build darwin

package agentlaunch

import (
	"bytes"
	"encoding/binary"
	"errors"

	"golang.org/x/sys/unix"
)

// ProcessEnvironment returns the named variables from pid's initial
// environment, read through KERN_PROCARGS2. The kernel serves it only for the
// caller's own non-platform processes, which includes the agent CLIs.
func ProcessEnvironment(pid int, keys ...string) (map[string]string, error) {
	if pid <= 1 {
		return nil, errors.New("invalid agent process")
	}
	raw, err := unix.SysctlRaw("kern.procargs2", pid)
	if err != nil || len(raw) < 4 || len(raw) > 1<<20 {
		return nil, errors.New("agent environment unavailable")
	}
	block, err := procargsEnvironment(raw)
	if err != nil {
		return nil, err
	}
	// The kernel withholds the environment of platform binaries and serves an
	// empty block. A real agent always has variables, so an empty block is unread.
	if !bytes.Contains(block, []byte("=")) {
		return nil, errors.New("agent environment unavailable")
	}
	return selectEnvironment(block, keys)
}

// procargsEnvironment skips argc, the executable path and its padding and the
// argv strings. The environment ends at the first empty string; the Apple
// loader strings that follow are never part of the result.
func procargsEnvironment(raw []byte) ([]byte, error) {
	argc := int(binary.LittleEndian.Uint32(raw[:4]))
	rest := raw[4:]
	end := bytes.IndexByte(rest, 0)
	if argc < 0 || argc > 4096 || end < 0 {
		return nil, errors.New("agent process arguments are invalid")
	}
	rest = rest[end:]
	for len(rest) > 0 && rest[0] == 0 {
		rest = rest[1:]
	}
	for i := 0; i < argc; i++ {
		end = bytes.IndexByte(rest, 0)
		if end < 0 {
			return nil, errors.New("agent process arguments are truncated")
		}
		rest = rest[end+1:]
	}
	var block []byte
	for len(rest) > 0 {
		end = bytes.IndexByte(rest, 0)
		if end <= 0 {
			break
		}
		block = append(append(block, rest[:end]...), 0)
		rest = rest[end+1:]
	}
	return block, nil
}
