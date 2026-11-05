//go:build darwin

package daemon

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

type nativeSocketRow struct {
	pid                int
	device, peer, path string
}
type nativeCommandBuffer struct{ bytes.Buffer }

func (b *nativeCommandBuffer) Write(data []byte) (int, error) {
	if b.Len()+len(data) > 1<<20 {
		return 0, errors.New("native socket inventory exceeds limit")
	}
	return b.Buffer.Write(data)
}

var nativeLsofPath = "/usr/sbin/lsof"

func nativeLsof(ctx context.Context, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, nativeLsofPath, append([]string{"-nP"}, args...)...)
	var output, failure nativeCommandBuffer
	cmd.Stdout = &output
	cmd.Stderr = &failure
	if err := cmd.Run(); err != nil {
		// lsof exits 1 silently when no open file matched: an empty kernel
		// inventory, which the callers' uniqueness checks then refuse. Any
		// other status, diagnostic or partial output remains unavailable.
		var exit *exec.ExitError
		if ctx.Err() == nil && errors.As(err, &exit) && exit.ExitCode() == 1 && output.Len() == 0 && failure.Len() == 0 {
			return "", nil
		}
		return "", errors.New("native kernel socket inventory unavailable")
	}
	return output.String(), nil
}
func nativeUnixRows(output string) []nativeSocketRow {
	rows := []nativeSocketRow{}
	for _, line := range strings.Split(output, "\n") {
		f := strings.Fields(line)
		if len(f) < 8 {
			continue
		}
		pid, e := strconv.Atoi(f[1])
		if e != nil {
			continue
		}
		for i := 2; i+3 < len(f); i++ {
			if f[i] != "unix" || !strings.HasPrefix(f[i+1], "0x") {
				continue
			}
			row := nativeSocketRow{pid: pid, device: f[i+1]}
			name := f[len(f)-1]
			if strings.HasPrefix(name, "->0x") {
				row.peer = strings.TrimPrefix(name, "->")
			}
			if strings.HasPrefix(name, "/") {
				row.path = name
				if offset := strings.Index(line, " /"); offset >= 0 {
					row.path = strings.TrimSpace(line[offset+1:])
				}
			}
			rows = append(rows, row)
			break
		}
	}
	return rows
}
func nativeCodexEndpoint(ctx context.Context, frontend int) (NativeCodexEndpoint, error) {
	var empty NativeCodexEndpoint
	processes, err := unix.SysctlKinfoProcSlice("kern.proc.uid", os.Getuid())
	if err != nil || len(processes) > 16384 {
		return empty, errors.New("native process inventory unavailable")
	}
	candidates := []int{}
	for _, process := range processes {
		pid := int(process.Proc.P_pid)
		if darwinAgentCommand(process.Proc.P_comm[:]) != "codex" {
			continue
		}
		candidates = append(candidates, pid)
	}
	if len(candidates) > 64 {
		return empty, errors.New("native Codex inventory exceeds limit")
	}
	sort.Ints(candidates)
	ids := []string{}
	starts := map[int]uint64{}
	for _, pid := range candidates {
		start, e := processStartTime(pid)
		if e != nil {
			return empty, e
		}
		starts[pid] = start
		ids = append(ids, strconv.Itoa(pid))
	}
	if starts[frontend] == 0 {
		return empty, errors.New("native frontend unavailable")
	}
	output, err := nativeLsof(ctx, "-a", "-p", strings.Join(ids, ","), "-U")
	if err != nil {
		return empty, err
	}
	rows := nativeUnixRows(output)
	peers := map[string]string{}
	for _, row := range rows {
		if row.pid == frontend && row.peer != "" {
			peers[row.peer] = row.device
		}
	}
	matches := map[string]NativeCodexEndpoint{}
	for _, row := range rows {
		if row.pid == frontend || peers[row.device] == "" || row.path == "" {
			continue
		}
		info, e := os.Lstat(row.path)
		if e != nil || info.Mode()&os.ModeSocket == 0 {
			continue
		}
		s, ok := info.Sys().(*syscall.Stat_t)
		if !ok || int(s.Uid) != os.Getuid() {
			continue
		}
		parent, e := os.Lstat(filepath.Dir(row.path))
		if e != nil || !parent.IsDir() || parent.Mode().Perm()&0077 != 0 {
			continue
		}
		ps, ok := parent.Sys().(*syscall.Stat_t)
		if !ok || int(ps.Uid) != os.Getuid() {
			continue
		}
		value := NativeCodexEndpoint{Socket: row.path, FrontendSocket: peers[row.device], DaemonSocket: row.device, DaemonPID: row.pid, DaemonStart: starts[row.pid], Device: uint64(s.Dev), Inode: s.Ino}
		matches[fmt.Sprintf("%d:%s", row.pid, row.path)] = value
	}
	if len(matches) != 1 {
		return empty, errors.New("native frontend has no unique kernel daemon socket")
	}
	var endpoint NativeCodexEndpoint
	for _, value := range matches {
		endpoint = value
	}
	output, err = nativeLsof(ctx, "-a", "-p", strconv.Itoa(frontend), "-iTCP", "-sTCP:LISTEN", "-Fn")
	if err != nil {
		return empty, err
	}
	origins := map[string]bool{}
	for _, line := range strings.Split(output, "\n") {
		if strings.HasPrefix(line, "n127.0.0.1:") {
			port, e := strconv.Atoi(strings.TrimPrefix(line, "n127.0.0.1:"))
			if e == nil && port > 0 && port <= 65535 {
				origins["http://127.0.0.1:"+strconv.Itoa(port)] = true
			}
		}
	}
	if len(origins) != 1 {
		return empty, errors.New("native frontend has no unique loopback listener")
	}
	for origin := range origins {
		endpoint.Origin = origin
	}
	for _, pid := range []int{frontend, endpoint.DaemonPID} {
		if current, e := processStartTime(pid); e != nil || current != starts[pid] {
			return empty, errors.New("native socket process changed")
		}
	}
	return endpoint, nil
}
