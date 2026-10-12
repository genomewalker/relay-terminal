package daemon

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/relay-terminal/relayd/internal/peernet"
)

type hostProcess struct {
	PID          int     `json:"pid"`
	ParentPID    int     `json:"parent_pid"`
	UID          int     `json:"uid"`
	GroupPID     int     `json:"group_pid"`
	CPU          float64 `json:"cpu_percent"`
	Memory       int64   `json:"memory_bytes"`
	TTY          string  `json:"tty"`
	Name         string  `json:"name"`
	Start        string  `json:"start"`
	PaneID       string  `json:"pane_id,omitempty"`
	Terminal     string  `json:"terminal,omitempty"`
	JobID        string  `json:"job_id,omitempty"`
	Relationship string  `json:"relationship"`
	CanSignal    bool    `json:"can_signal"`
}

type processBuffer struct{ bytes.Buffer }

func (b *processBuffer) Write(data []byte) (int, error) {
	if b.Len()+len(data) > 2<<20 {
		return 0, errors.New("process inventory exceeds limit")
	}
	return b.Buffer.Write(data)
}

func (s *Server) processInventory() ([]hostProcess, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, "/bin/ps", "-u", strconv.Itoa(os.Getuid()), "-o", "pid=,ppid=,uid=,pgid=,pcpu=,rss=,tty=,comm=")
	command.Env = append(os.Environ(), "LC_ALL=C", "LANG=C")
	var output processBuffer
	command.Stdout = &output
	if err := command.Run(); err != nil {
		return nil, err
	}
	all := map[int]hostProcess{}
	roots := map[int]hostProcess{os.Getpid(): {Relationship: "Relay supervisor"}}
	for _, line := range strings.Split(output.String(), "\n") {
		f := strings.Fields(line)
		if len(f) < 8 {
			continue
		}
		pid, e1 := strconv.Atoi(f[0])
		parent, e2 := strconv.Atoi(f[1])
		uid, e3 := strconv.Atoi(f[2])
		group, e4 := strconv.Atoi(f[3])
		cpu, e5 := strconv.ParseFloat(f[4], 64)
		rss, e6 := strconv.ParseInt(f[5], 10, 64)
		if e1 != nil || e2 != nil || e3 != nil || e4 != nil || e5 != nil || e6 != nil || uid != os.Getuid() || pid < 2 {
			continue
		}
		name := strings.Join(f[7:], " ")
		all[pid] = hostProcess{PID: pid, ParentPID: parent, UID: uid, GroupPID: group, CPU: cpu, Memory: rss * 1024, TTY: f[6], Name: name}
		base := filepath.Base(name)
		if base == "Relay" || base == "relayd" || base == "relay-mcp" || base == "relay-peer-link" || base == "relay-connection" || base == "relay-workspace" {
			roots[pid] = hostProcess{Relationship: "Relay service"}
		}
	}
	catalog, err := s.CatalogSnapshot()
	if err != nil {
		return nil, err
	}
	for _, pane := range catalog.Panes {
		if !pane.Recoverable || pane.State != "running" {
			continue
		}
		root := hostProcess{PaneID: pane.PaneID, Terminal: pane.Title, Relationship: "Relay terminal"}
		if pane.WorkerPID > 1 {
			roots[pane.WorkerPID] = root
		}
		if pane.ShellPID > 1 {
			roots[pane.ShellPID] = root
		}
	}
	s.hostJobs.Range(func(_, value any) bool {
		job := value.(*hostJob)
		job.mu.Lock()
		if job.record.State == "running" && job.record.PID > 1 {
			roots[job.record.PID] = hostProcess{JobID: job.record.JobID, Relationship: "Relay job"}
		}
		job.mu.Unlock()
		return true
	})
	home, _ := os.UserHomeDir()
	// Launch services are reparented to launchd/systemd, so ancestry alone
	// cannot find the existing Python routing and MCP adapters. Inspect their
	// executable/script arguments for classification without exposing argv.
	arguments := exec.CommandContext(ctx, "/bin/ps", "-u", strconv.Itoa(os.Getuid()), "-o", "pid=,args=")
	arguments.Env = append(os.Environ(), "LC_ALL=C", "LANG=C")
	var argumentOutput processBuffer
	arguments.Stdout = &argumentOutput
	if arguments.Run() == nil {
		for _, line := range strings.Split(argumentOutput.String(), "\n") {
			fields := strings.Fields(line)
			if len(fields) < 3 || !strings.HasPrefix(filepath.Base(fields[1]), "python") {
				continue
			}
			pid, e := strconv.Atoi(fields[0])
			if e != nil {
				continue
			}
			if strings.HasPrefix(fields[2], filepath.Join(home, ".local", "share", "relay")+string(os.PathSeparator)) {
				if process, ok := all[pid]; ok {
					process.Name = fields[2]
					all[pid] = process
					roots[pid] = hostProcess{Relationship: "Relay adapter"}
				}
			}
		}
	}
	if discovery, e := peernet.Discover(home); e == nil {
		for _, peer := range discovery.Peers {
			current := peer.PID
			inherited := false
			for depth := 0; depth < 128 && current > 1; depth++ {
				if _, ok := roots[current]; ok {
					inherited = true
					break
				}
				process, ok := all[current]
				if !ok {
					break
				}
				current = process.ParentPID
			}
			if !inherited {
				roots[peer.PID] = hostProcess{Relationship: "Registered agent"}
			}
		}
	}

	result := []hostProcess{}
	for pid, process := range all {
		current := pid
		visited := map[int]bool{}
		var relation hostProcess
		related := false
		for depth := 0; depth < 128 && current > 1 && !visited[current]; depth++ {
			visited[current] = true
			if root, ok := roots[current]; ok {
				relation = root
				related = true
				break
			}
			parent, ok := all[current]
			if !ok {
				break
			}
			current = parent.ParentPID
		}
		if !related {
			continue
		}
		start, e := processStartIdentity(pid)
		if e != nil {
			continue
		}
		process.Start = start
		process.PaneID = relation.PaneID
		process.Terminal = relation.Terminal
		process.JobID = relation.JobID
		process.Relationship = relation.Relationship
		process.CanSignal = pid != os.Getpid()
		result = append(result, process)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].PID < result[j].PID })
	return result, nil
}

func (s *Server) hostProcessRPC(r hostRequest) (any, error) {
	processes, err := s.processInventory()
	if err != nil {
		return nil, err
	}
	if r.Operation == "process_list" {
		return map[string]any{"processes": processes, "captured_at": time.Now().UTC().Format(time.RFC3339Nano)}, nil
	}
	if r.ProcessPID < 2 || r.ProcessPID == os.Getpid() || r.ProcessStart == "" {
		return nil, errors.New("exact stoppable process identity required")
	}
	signal := syscall.SIGTERM
	if r.Signal == "kill" {
		signal = syscall.SIGKILL
	} else if r.Signal != "terminate" {
		return nil, errors.New("choose terminate or kill")
	}
	for _, process := range processes {
		if process.PID != r.ProcessPID || process.Start != r.ProcessStart {
			continue
		}
		// Revalidate immediately before signalling; never signal a process group.
		start, e := processStartIdentity(process.PID)
		if e != nil || start != r.ProcessStart {
			return nil, errors.New("process incarnation changed")
		}
		if e = syscall.Kill(process.PID, signal); e != nil {
			return nil, e
		}
		return map[string]any{"pid": process.PID, "start": start, "status": "signal_sent", "signal": r.Signal}, nil
	}
	return nil, errors.New("process is gone, changed, or no longer related to Relay")
}
