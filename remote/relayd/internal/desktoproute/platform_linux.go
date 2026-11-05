//go:build linux

package desktoproute

import (
	"errors"
	"fmt"
	"golang.org/x/sys/unix"
	"net"
	"os"
	"strconv"
	"strings"
	"syscall"
)

func parseProcStat(data []byte, pid int) (string, error) {
	if len(data) > 65536 || pid <= 0 {
		return "", errors.New("invalid process stat")
	}
	s := string(data)
	first := strings.Index(s, " (")
	last := strings.LastIndex(s, ")")
	if first < 0 || last <= first || s[:first] != strconv.Itoa(pid) {
		return "", errors.New("process stat identity mismatch")
	}
	fields := strings.Fields(s[last+1:])
	if len(fields) < 20 || fields[0] == "Z" || fields[0] == "X" || !numericStart.MatchString(fields[19]) {
		return "", errors.New("process is ended or stat is truncated")
	}
	return fields[19], nil
}
func inspectProcess(pid int) (processInfo, error) {
	var result processInfo
	path := fmt.Sprintf("/proc/%d", pid)
	info, e := os.Stat(path)
	if e != nil {
		return result, e
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(owner.Uid) != os.Getuid() {
		return result, errors.New("process owner changed")
	}
	f, e := os.Open(path + "/stat")
	if e != nil {
		return result, e
	}
	defer f.Close()
	b, e := readBounded(f, 65536)
	if e != nil {
		return result, e
	}
	result.Start, e = parseProcStat(b, pid)
	if e != nil {
		return result, e
	}
	result.WorkStart = result.Start
	result.Executable, e = os.Readlink(path + "/exe")
	return result, e
}
func socketPeer(c *net.UnixConn) (pid, uid int, err error) {
	raw, e := c.SyscallConn()
	if e != nil {
		return 0, 0, e
	}
	var cred *unix.Ucred
	var se error
	e = raw.Control(func(fd uintptr) { cred, se = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED) })
	if e != nil {
		return 0, 0, e
	}
	if se != nil {
		return 0, 0, se
	}
	if cred.Pid <= 0 {
		return 0, 0, errors.New("invalid kernel peer")
	}
	return int(cred.Pid), int(cred.Uid), nil
}
