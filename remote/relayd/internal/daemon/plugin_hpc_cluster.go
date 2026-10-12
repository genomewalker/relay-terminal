package daemon

import (
	"errors"
	"regexp"
	"strconv"
	"strings"
)

type PluginHPCCluster struct {
	Allocated          int `json:"allocated"`
	Idle               int `json:"idle"`
	Other              int `json:"other"`
	Total              int `json:"total"`
	Nodes              int `json:"nodes"`
	MemoryMiB          int `json:"memory_mib"`
	AllocatedMemoryMiB int `json:"allocated_memory_mib"`
	GPUs               int `json:"gpus"`
	UsedGPUs           int `json:"used_gpus"`
}

const pluginClusterFormat = "--Format=NodeList:100\x1f,CPUsState:80\x1f,Memory:40\x1f,AllocMem:40\x1f,Gres:200\x1f,GresUsed:200"

var pluginGPUCount = regexp.MustCompile(`(?:^|,)gpu(?::[^:,()]+)?:([0-9]+)`)

func gpuCount(value string) int {
	total := 0
	for _, match := range pluginGPUCount.FindAllStringSubmatch(value, -1) {
		n, _ := strconv.Atoi(match[1])
		total += n
	}
	return total
}

func inspectHPCCluster(root string, run func(string, string, ...string) (string, error)) (*PluginHPCCluster, error) {
	out, err := run(root, "sinfo", "--Node", "--noheader", pluginClusterFormat)
	if err != nil {
		return nil, err
	}
	if len(out) > 1<<20 {
		return nil, errors.New("cluster response exceeds display limit")
	}
	result := &PluginHPCCluster{}
	seen := map[string]bool{}
	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		fields := strings.Split(line, "\x1f")
		if len(fields) != 4 && len(fields) != 6 {
			return nil, errors.New("unexpected cluster response")
		}
		name := strings.TrimSpace(fields[0])
		if seen[name] {
			continue
		}
		seen[name] = true
		cpus := strings.Split(strings.TrimSpace(fields[1]), "/")
		if name == "" || len(cpus) != 4 {
			return nil, errors.New("invalid cluster CPU response")
		}
		values := make([]int, 4)
		for i, v := range cpus {
			n, e := strconv.Atoi(v)
			if e != nil || n < 0 || n > 10000000 {
				return nil, errors.New("invalid CPU count")
			}
			values[i] = n
		}
		if values[0]+values[1]+values[2] != values[3] {
			return nil, errors.New("inconsistent cluster CPU totals")
		}
		memory, e := strconv.Atoi(strings.TrimSpace(fields[2]))
		if e != nil || memory < 0 || memory > 1000000000 {
			return nil, errors.New("invalid node memory")
		}
		result.Allocated += values[0]
		result.Idle += values[1]
		result.Other += values[2]
		result.Total += values[3]
		result.MemoryMiB += memory
		if len(fields) == 6 {
			allocated, e := strconv.Atoi(strings.TrimSpace(fields[3]))
			if e != nil || allocated < 0 || allocated > memory {
				return nil, errors.New("invalid allocated memory")
			}
			result.AllocatedMemoryMiB += allocated
			result.GPUs += gpuCount(strings.TrimSpace(fields[4]))
			result.UsedGPUs += gpuCount(strings.TrimSpace(fields[5]))
		}
		result.Nodes++
	}
	return result, nil
}
