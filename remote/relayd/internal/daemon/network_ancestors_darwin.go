//go:build darwin

package daemon

import "fmt"

func networkAncestors(pid int, expected string) ([]int, error) {
	start, err := processStartIdentity(pid)
	if err != nil || start != expected {
		return nil, fmt.Errorf("process identity changed")
	}
	initial, err := processStartTime(pid)
	if err != nil {
		return nil, err
	}
	chain := []int{}
	starts := map[int]uint64{}
	for current := pid; current > 1; {
		if len(chain) >= 64 {
			return nil, fmt.Errorf("ancestry exceeds limit")
		}
		if _, seen := starts[current]; seen {
			return nil, fmt.Errorf("ancestry cycle")
		}
		info, err := darwinProcessInfo(current)
		if err != nil {
			return nil, err
		}
		starts[current] = uint64(info.Proc.P_starttime.Sec)*1000000 + uint64(info.Proc.P_starttime.Usec)
		chain = append(chain, current)
		current = int(info.Eproc.Ppid)
	}
	for _, member := range chain {
		after, err := processStartTime(member)
		if err != nil || after != starts[member] {
			return nil, fmt.Errorf("ancestry identity changed")
		}
	}
	after, err := processStartTime(pid)
	if err != nil || after != initial {
		return nil, fmt.Errorf("process identity changed")
	}
	return chain, nil
}
