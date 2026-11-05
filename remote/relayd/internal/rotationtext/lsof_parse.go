package rotationtext

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// Strict parsers for lsof's field output (-F). Anything outside the grammar
// is an error: an unparsable scan never counts as "no holders".
//
// Holder scan (-F p): one or more records, each "p<pid>\n" followed by at
// least one "f<fd>\n"; fd is [0-9A-Za-z]+. The output ends with "\n".
//
// Image scan (-F Din, -d txt, one pid): "p<pid>\n" then one or more groups
// "f<fd>\nD0x<hex device>\ni<inode>\nn<name>\n". The first group is the
// executable and its fd must be "txt".

const (
	lsofOutputLimit = 1 << 20
	lsofRecordLimit = 1 << 14
)

var errLsofGrammar = errors.New("lsof output outside the expected grammar")

func lsofLines(out []byte) ([]string, error) {
	if len(out) == 0 || len(out) > lsofOutputLimit || out[len(out)-1] != '\n' {
		return nil, errLsofGrammar
	}
	lines := strings.Split(string(out[:len(out)-1]), "\n")
	if len(lines) > lsofRecordLimit {
		return nil, errLsofGrammar
	}
	return lines, nil
}

func lsofPID(field string) (int, error) {
	if len(field) == 0 || len(field) > 10 || field[0] == '0' {
		return 0, errLsofGrammar
	}
	for _, c := range field {
		if c < '0' || c > '9' {
			return 0, errLsofGrammar
		}
	}
	pid, err := strconv.Atoi(field)
	if err != nil || pid <= 0 || pid > 1<<31-1 {
		return 0, errLsofGrammar
	}
	return pid, nil
}

func lsofFD(field string) bool {
	if len(field) == 0 || len(field) > 32 {
		return false
	}
	for _, c := range field {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z') {
			return false
		}
	}
	return true
}

// parseLsofHolders returns the distinct pids, in order of first appearance.
func parseLsofHolders(out []byte) ([]int, error) {
	lines, err := lsofLines(out)
	if err != nil {
		return nil, err
	}
	pids, seen := []int{}, map[int]bool{}
	fds := 0
	for i, line := range lines {
		switch {
		case strings.HasPrefix(line, "p"):
			if i > 0 && fds == 0 {
				return nil, errLsofGrammar // a process record without a descriptor
			}
			pid, err := lsofPID(line[1:])
			if err != nil {
				return nil, err
			}
			if !seen[pid] {
				seen[pid] = true
				pids = append(pids, pid)
			}
			fds = 0
		case strings.HasPrefix(line, "f") && i > 0:
			if !lsofFD(line[1:]) {
				return nil, errLsofGrammar
			}
			fds++
		default:
			return nil, errLsofGrammar
		}
	}
	if fds == 0 {
		return nil, errLsofGrammar
	}
	return pids, nil
}

// parseLsofImage returns the executable (first txt) device, inode and path of
// pid.
func parseLsofImage(out []byte, pid int) (uint64, uint64, string, error) {
	lines, err := lsofLines(out)
	if err != nil {
		return 0, 0, "", err
	}
	if len(lines) < 5 || (len(lines)-1)%4 != 0 || lines[0] != "p"+strconv.Itoa(pid) {
		return 0, 0, "", errLsofGrammar
	}
	var device, inode uint64
	var name string
	for i := 1; i < len(lines); i += 4 {
		fd, dev, ino, path := lines[i], lines[i+1], lines[i+2], lines[i+3]
		if !strings.HasPrefix(fd, "f") || !lsofFD(fd[1:]) || !strings.HasPrefix(dev, "D0x") || !strings.HasPrefix(ino, "i") ||
			!strings.HasPrefix(path, "n") || len(path) < 2 || path[1] != '/' || strings.ContainsRune(path, 0) {
			return 0, 0, "", errLsofGrammar
		}
		devValue, err := strconv.ParseUint(dev[3:], 16, 64)
		if err != nil || len(dev) < 4 || len(dev) > 19 || dev[3] == '+' {
			return 0, 0, "", errLsofGrammar
		}
		value, err := strconv.ParseUint(ino[1:], 10, 64)
		if err != nil || len(ino) < 2 || ino[1] == '+' || value == 0 {
			return 0, 0, "", errLsofGrammar
		}
		if i == 1 {
			if fd != "ftxt" {
				return 0, 0, "", fmt.Errorf("%w: first descriptor %q is not the executable", errLsofGrammar, fd)
			}
			device, inode, name = devValue, value, path[1:]
		}
	}
	return device, inode, name, nil
}
