//go:build linux

package daemon

import (
	"fmt"
	"os"
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
		data, e := os.ReadFile(fmt.Sprintf("/proc/%d/stat", current))
		if e != nil {
			return nil, e
		}
		end := strings.LastIndex(string(data), ")")
		if end < 0 {
			return nil, fmt.Errorf("invalid stat")
		}
		fields := strings.Fields(string(data)[end+1:])
		if len(fields) < 2 {
			return nil, fmt.Errorf("invalid stat")
		}
		current, e = strconv.Atoi(fields[1])
		if e != nil {
			return nil, e
		}
	}
	after, err := processStartIdentity(pid)
	if err != nil || after != start {
		return nil, fmt.Errorf("process identity changed")
	}
	return chain, nil
}
