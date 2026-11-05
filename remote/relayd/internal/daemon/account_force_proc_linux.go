//go:build linux

package daemon

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"unicode/utf8"
)

type forceLinuxProcess struct {
	Parent int
	Start  string
	Argv   []string
}

// forceLinuxProcStat parses the kernel stat record around the final close
// parenthesis because comm may itself contain spaces and parentheses.
func forceLinuxProcStat(data []byte) (int, string, error) {
	end := bytes.LastIndexByte(data, ')')
	if end < 0 || end+1 >= len(data) {
		return 0, "", errors.New("invalid process stat")
	}
	fields := strings.Fields(string(data[end+1:]))
	if len(fields) < 20 || len(fields[0]) != 1 {
		return 0, "", errors.New("short process stat")
	}
	parent, err := strconv.Atoi(fields[1])
	if err != nil || parent <= 1 {
		return 0, "", errors.New("invalid process parent")
	}
	start, err := strconv.ParseUint(fields[19], 10, 64)
	if err != nil || start == 0 {
		return 0, "", errors.New("invalid process start")
	}
	return parent, strconv.FormatUint(start, 10), nil
}

func forceLinuxReadBounded(path string, limit int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil || int64(len(data)) > limit {
		return nil, errors.New("process data unavailable or too large")
	}
	return data, nil
}

// forceLinuxReadProcess fails closed unless owner, parent and full kernel
// start remain stable around a bounded, exact, argument-separated read.
// An empty final argument is retained; malformed/non-UTF-8 argv is refused.
func forceLinuxReadProcess(procRoot string, pid int) (forceLinuxProcess, error) {
	var out forceLinuxProcess
	if pid <= 1 {
		return out, errors.New("invalid process PID")
	}
	dir := filepath.Join(procRoot, strconv.Itoa(pid))
	owner := func() error {
		info, err := os.Lstat(dir)
		if err != nil {
			return err
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || !info.IsDir() || int(stat.Uid) != os.Getuid() {
			return errors.New("process owner unavailable or changed")
		}
		return nil
	}
	identity := func() (int, string, error) {
		data, err := forceLinuxReadBounded(filepath.Join(dir, "stat"), 8192)
		if err != nil {
			return 0, "", err
		}
		return forceLinuxProcStat(data)
	}
	if err := owner(); err != nil {
		return out, err
	}
	parent, start, err := identity()
	if err != nil {
		return out, err
	}
	raw, err := forceLinuxReadBounded(filepath.Join(dir, "cmdline"), 65536)
	if err != nil || len(raw) == 0 || raw[len(raw)-1] != 0 {
		return out, errors.New("process arguments unavailable or incomplete")
	}
	parts := bytes.Split(raw[:len(raw)-1], []byte{0})
	if len(parts) == 0 || len(parts) > 128 {
		return out, errors.New("invalid process arguments")
	}
	argv := make([]string, 0, len(parts))
	for _, part := range parts {
		if !utf8.Valid(part) {
			return out, errors.New("invalid UTF-8 process argument")
		}
		argv = append(argv, string(part))
	}
	if err := owner(); err != nil {
		return out, err
	}
	afterParent, afterStart, err := identity()
	if err != nil || afterParent != parent || afterStart != start {
		return out, fmt.Errorf("process identity changed during argument read")
	}
	return forceLinuxProcess{Parent: parent, Start: start, Argv: argv}, nil
}
