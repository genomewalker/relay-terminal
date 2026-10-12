//go:build !linux && !darwin

package daemon

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

func networkAncestors(pid int, expected string) ([]int, error) {
	start, err := processStartIdentity(pid)
	if err != nil || start != expected {
		return nil, fmt.Errorf("process identity changed")
	}
	chain := []int{}
	seen := map[int]bool{}
	for current := pid; current > 1 && len(chain) < 64; {
		if seen[current] {
			return nil, fmt.Errorf("ancestry cycle")
		}
		seen[current] = true
		chain = append(chain, current)
		command := exec.Command("/bin/ps", "-p", strconv.Itoa(current), "-o", "ppid=")
		command.Env = stableProcessEnvironment(os.Environ())
		data, e := command.Output()
		if e != nil {
			return nil, e
		}
		parent, e := strconv.Atoi(strings.TrimSpace(string(data)))
		if e != nil {
			return nil, fmt.Errorf("invalid parent PID")
		}
		current = parent
	}
	after, err := processStartIdentity(pid)
	if err != nil || after != start {
		return nil, fmt.Errorf("process identity changed")
	}
	return chain, nil
}
