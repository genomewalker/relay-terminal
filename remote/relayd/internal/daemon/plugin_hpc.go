package daemon

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

const pluginHPCJobLimit = 500
const pluginHPCFormat = "%i\x1f%P\x1f%j\x1f%T\x1f%M\x1f%D\x1f%R\x1f%u\x1f%C"

type PluginHPCJob struct {
	Username  string `json:"username"`
	CPUs      string `json:"cpus"`
	ID        string `json:"id"`
	Partition string `json:"partition"`
	Name      string `json:"name"`
	State     string `json:"state"`
	Elapsed   string `json:"elapsed"`
	Nodes     string `json:"nodes"`
	Reason    string `json:"reason"`
}

type PluginHPCPage struct {
	Jobs      []PluginHPCJob
	Total     int
	Truncated bool
}

func inspectHPCJobs(root string, run func(string, ...string) (string, error), requests ...PluginRequest) (PluginHPCPage, error) {
	page := PluginHPCPage{Jobs: []PluginHPCJob{}}
	args := []string{"--me", "--noheader", "--format=" + pluginHPCFormat}
	if len(requests) > 0 {
		r := requests[0]
		if r.User != "" {
			if len(r.User) > 64 || strings.ContainsAny(r.User, " ,\t\n\r\x00") || strings.HasPrefix(r.User, "-") {
				return page, errors.New("invalid Slurm username")
			}
			args[0] = "--user=" + r.User
		} else if r.AllUsers {
			args = args[1:]
		}
	}
	output, err := run(root, args...)
	if err != nil {
		return page, err
	}
	if len(output) > 1<<20 {
		return page, errors.New("Slurm output exceeds 1 MiB; queue inspection was stopped")
	}
	seen := make(map[string]bool)
	for _, line := range strings.Split(output, "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		fields := strings.Split(strings.TrimSuffix(line, "\r"), "\x1f")
		if len(fields) != 7 && len(fields) != 9 {
			return PluginHPCPage{}, errors.New("unexpected Slurm output; no reliable job list can be shown")
		}
		for i := range fields {
			fields[i] = strings.TrimSpace(fields[i])
			if len(fields[i]) > 4096 {
				return PluginHPCPage{}, errors.New("Slurm field exceeds the display limit")
			}
		}
		if fields[0] == "" || fields[3] == "" || seen[fields[0]] {
			return PluginHPCPage{}, errors.New("Slurm returned empty or duplicate job identities")
		}
		seen[fields[0]] = true
		page.Total++
		if len(page.Jobs) < pluginHPCJobLimit {
			job := PluginHPCJob{ID: fields[0], Partition: fields[1], Name: fields[2], State: fields[3], Elapsed: fields[4], Nodes: fields[5], Reason: fields[6]}
			if len(fields) == 9 {
				job.Username, job.CPUs = fields[7], fields[8]
			}
			page.Jobs = append(page.Jobs, job)
		} else {
			page.Truncated = true
		}
	}
	return page, nil
}

func pluginHPCCommand(root string, arguments ...string) (string, error) {
	return pluginSchedulerCommand(root, "squeue", arguments...)
}

func pluginSchedulerCommand(root, name string, arguments ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, arguments...)
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	cmd.WaitDelay = time.Second
	var output, diagnostic pluginBuffer
	if name == "sacct" {
		output.limit = 6 << 20
	}
	cmd.Stdout, cmd.Stderr = &output, &diagnostic
	err := cmd.Run()
	if errors.Is(err, exec.ErrNotFound) {
		return "", fmt.Errorf("Slurm %s is not installed or not available on this host's PATH", name)
	}
	if ctx.Err() != nil {
		return "", errors.New("Slurm did not respond within 8 seconds; retry later")
	}
	if err != nil {
		message := diagnostic.String()
		if len(message) > 2000 {
			message = message[:2000]
		}
		return "", fmt.Errorf("Slurm query failed: %w\n%s", err, message)
	}
	return output.String(), nil
}
