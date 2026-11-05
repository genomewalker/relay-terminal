package nativemsg

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// psRow is one line of `ps -u UID -o pid=,ppid=,uid=,comm=`.
type psRow struct {
	pid, ppid, uid int64
	comm           string
}

// processSource is the process inventory the adapter read through /proc on
// Linux and ps/lsof/sysctl elsewhere.
type processSource interface {
	linux() bool
	// identity is agent_conversation.identity: the owner-checked start time.
	identity(pid int64) (string, error)
	// epoch is the start time in seconds since the Unix epoch.
	epoch(pid int64) (float64, error)
	processes() ([]psRow, error)
	executable(pid int64) (string, error)
	openPaths(pid int64) ([]string, error)
	// environment is the process's initial environment entries.
	environment(pid int64) ([][]byte, error)
}

// procfs reads a Linux /proc tree; root is "/proc" except in tests.
type procfs struct {
	root string
	uid  int64
}

func (p procfs) linux() bool { return true }

func (p procfs) path(pid int64, names ...string) string {
	return strings.Join(append([]string{p.root, strconv.FormatInt(pid, 10)}, names...), "/")
}

func (p procfs) identity(pid int64) (string, error) {
	dir := p.path(pid)
	info, err := os.Stat(dir)
	if err != nil {
		return "", fromOS(err, dir)
	}
	if int64(info.Sys().(*syscall.Stat_t).Uid) != p.uid {
		return "", unbound("Process owner changed.")
	}
	fields, err := p.statFields(pid)
	if err != nil {
		return "", err
	}
	if len(fields) <= 19 {
		return "", &pyErr{class: classIndex, msg: "list index out of range"}
	}
	return "linux:" + fields[19], nil
}

// statFields are /proc/PID/stat's fields after the command name.
func (p procfs) statFields(pid int64) ([]string, error) {
	name := p.path(pid, "stat")
	data, err := os.ReadFile(name)
	if err != nil {
		return nil, fromOS(err, name)
	}
	line := string(data)
	end := strings.LastIndex(line, ")")
	if end+2 > len(line) {
		return nil, nil
	}
	return pySplit(line[end+2:]), nil
}

func (p procfs) epoch(pid int64) (float64, error) {
	data, err := os.ReadFile(p.root + "/stat")
	if err != nil {
		return 0, fromOS(err, p.root+"/stat")
	}
	boot := int64(-1)
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "btime ") {
			fields := pySplit(line)
			if len(fields) < 2 {
				return 0, &pyErr{class: classIndex, msg: "list index out of range"}
			}
			boot, err = strconv.ParseInt(fields[1], 10, 64)
			if err != nil {
				return 0, valueError("invalid literal for int() with base 10: " + reprString(fields[1]))
			}
			break
		}
	}
	if boot < 0 {
		return 0, &pyErr{class: classInternal, msg: "StopIteration"}
	}
	start, err := p.identity(pid)
	if err != nil {
		return 0, err
	}
	ticks, err := strconv.ParseInt(strings.TrimPrefix(start, "linux:"), 10, 64)
	if err != nil {
		return 0, valueError("invalid literal for int() with base 10: " + reprString(strings.TrimPrefix(start, "linux:")))
	}
	// os.sysconf("SC_CLK_TCK") is USER_HZ, fixed at 100 for Linux userspace.
	return float64(boot) + float64(ticks)/100, nil
}

// processes lists the user's processes as procps ps prints them: the
// effective UID, and the stat command name escaped for the C locale with
// " <defunct>" after a zombie's.
func (p procfs) processes() ([]psRow, error) {
	entries, err := os.ReadDir(p.root)
	if err != nil {
		return nil, unbound("Process discovery is unavailable.")
	}
	var rows []psRow
	for _, entry := range entries {
		pid, err := strconv.ParseInt(entry.Name(), 10, 64)
		if err != nil || pid <= 0 {
			continue
		}
		status, err := os.ReadFile(p.path(pid, "status"))
		if err != nil {
			continue
		}
		euid := int64(-1)
		for _, line := range strings.Split(string(status), "\n") {
			if strings.HasPrefix(line, "Uid:") {
				fields := strings.Fields(line)
				if len(fields) >= 3 {
					euid, _ = strconv.ParseInt(fields[2], 10, 64)
				}
			}
		}
		if euid != p.uid {
			continue
		}
		data, err := os.ReadFile(p.path(pid, "stat"))
		if err != nil {
			continue
		}
		open, close := bytes.IndexByte(data, '('), bytes.LastIndexByte(data, ')')
		if open < 0 || close < open {
			continue
		}
		fields := strings.Fields(string(data[close+1:]))
		if len(fields) < 2 {
			continue
		}
		ppid, err := strconv.ParseInt(fields[1], 10, 64)
		if err != nil {
			continue
		}
		comm := make([]byte, 0, close-open)
		for _, c := range data[open+1 : close] {
			if c < 0x20 || c > 0x7E {
				c = '?'
			}
			comm = append(comm, c)
		}
		name := string(comm)
		if fields[0] == "Z" {
			name += " <defunct>"
		}
		rows = append(rows, psRow{pid: pid, ppid: ppid, uid: euid, comm: name})
	}
	return rows, nil
}

func (p procfs) executable(pid int64) (string, error) {
	name := p.path(pid, "exe")
	target, err := os.Readlink(name)
	if err != nil {
		return "", fromOS(err, name)
	}
	return target, nil
}

// openPaths is the targets of /proc/PID/fd, at most 8192, in directory order.
func (p procfs) openPaths(pid int64) ([]string, error) {
	dir := p.path(pid, "fd")
	names, err := readDirNames(dir)
	if err != nil {
		return nil, fromOS(err, dir)
	}
	if len(names) > 8192 {
		names = names[:8192]
	}
	var result []string
	for _, name := range names {
		if target, err := os.Readlink(dir + "/" + name); err == nil {
			result = append(result, target)
		}
	}
	return result, nil
}

func readDirNames(dir string) ([]string, error) {
	f, err := os.Open(dir)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return f.Readdirnames(-1)
}

func (p procfs) environment(pid int64) ([][]byte, error) {
	name := p.path(pid, "environ")
	raw, err := os.ReadFile(name)
	if err != nil {
		return nil, fromOS(err, name)
	}
	if len(raw) > 1<<20 {
		return nil, unbound("Process environment exceeds its limit.")
	}
	return bytes.Split(raw, []byte{0}), nil
}

// globNames lists dir's entries whose names match pattern the way
// pathlib's wildcard selector does: every entry, hidden or not, in
// directory order. dirOnly keeps directories (following symlinks).
func globNames(dir, pattern string, dirOnly bool) ([]string, error) {
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		return nil, nil
	}
	names, err := readDirNames(dir)
	if err != nil {
		if os.IsPermission(err) {
			return nil, nil
		}
		return nil, fromOS(err, dir)
	}
	var result []string
	for _, name := range names {
		if ok, _ := filepath.Match(pattern, name); !ok {
			continue
		}
		if dirOnly {
			if info, err := os.Stat(dir + "/" + name); err != nil || !info.IsDir() {
				continue
			}
		}
		result = append(result, name)
	}
	return result, nil
}
