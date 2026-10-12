package daemon

import "sort"

type detectedAgentProcess struct {
	agent         string
	startIdentity string
}

type agentProcessTransition struct {
	pid     int
	process detectedAgentProcess
	event   string
}

// Keep the incarnation observed while the process is alive. Its /proc entry
// is unavailable by the time an exit is published.
func observedAgentProcesses(current map[int]string, known map[int]detectedAgentProcess, readStart func(int) (string, error)) map[int]detectedAgentProcess {
	observed := make(map[int]detectedAgentProcess, len(current))
	for pid, agent := range current {
		start, err := readStart(pid)
		if err == nil && start != "" && start != "unavailable" {
			observed[pid] = detectedAgentProcess{agent: agent, startIdentity: start}
		} else if prior, exists := known[pid]; exists && prior.agent == agent {
			// An observed process with a temporarily unreadable identity is
			// uncertain, not proof that the previous incarnation exited.
			observed[pid] = prior
		}
	}
	return observed
}

func agentProcessTransitions(known, current map[int]detectedAgentProcess) []agentProcessTransition {
	var ended, started []int
	for pid, prior := range known {
		if next, exists := current[pid]; !exists || next != prior {
			ended = append(ended, pid)
		}
	}
	for pid, next := range current {
		if prior, exists := known[pid]; !exists || prior != next {
			started = append(started, pid)
		}
	}
	sort.Ints(ended)
	sort.Ints(started)
	result := make([]agentProcessTransition, 0, len(ended)+len(started))
	for _, pid := range ended {
		result = append(result, agentProcessTransition{pid: pid, process: known[pid], event: "SessionEnd"})
	}
	for _, pid := range started {
		result = append(result, agentProcessTransition{pid: pid, process: current[pid], event: "SessionStart"})
	}
	return result
}
