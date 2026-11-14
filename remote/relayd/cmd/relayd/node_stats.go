package main

import (
	"encoding/json"
	"errors"
	"flag"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/relay-terminal/relayd/internal/loopbackproxy"
)

// Node statistics live next to the daemon socket, which is node-local even
// when $HOME is shared between HPC nodes.
func nodeStatsDir(socket string) string {
	return filepath.Join(filepath.Dir(socket), "node-stats")
}

type nodeStatsEntry struct {
	loopbackproxy.NodeStatsSnapshot
	AgeSeconds float64 `json:"age_seconds"`
}

type nodeStatsReport struct {
	Host    string           `json:"host"`
	Dir     string           `json:"dir"`
	Live    []nodeStatsEntry `json:"live"`
	Ended   int              `json:"ended_files"`
	Removed int              `json:"removed_files"`
}

// A live node rewrites its snapshot every five seconds. A file is left behind
// only when its node is killed before it can remove it. collectNodeStats
// removes such a file when its pid is not running and the file has not changed
// for nodeStatsStaleAfter, so a node that is starting or exiting, or one on
// another host if the directory is ever shared, keeps its file.
const nodeStatsStaleAfter = time.Minute

func collectNodeStats(dir string, now time.Time, alive func(int) bool) (nodeStatsReport, error) {
	host, _ := os.Hostname()
	report := nodeStatsReport{Host: host, Dir: dir, Live: []nodeStatsEntry{}}
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return report, nil
	}
	if err != nil {
		return report, err
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, entry.Name()))
		if err != nil {
			continue
		}
		var snap loopbackproxy.NodeStatsSnapshot
		if json.Unmarshal(data, &snap) != nil || snap.PID <= 0 {
			continue
		}
		if !alive(snap.PID) {
			report.Ended++
			if removeEndedNodeStats(dir, entry.Name(), snap.PID, now) {
				report.Removed++
			}
			continue
		}
		report.Live = append(report.Live, nodeStatsEntry{NodeStatsSnapshot: snap, AgeSeconds: now.Sub(snap.UpdatedAt).Seconds()})
	}
	sort.Slice(report.Live, func(i, j int) bool { return report.Live[i].PID < report.Live[j].PID })
	return report, nil
}

// removeEndedNodeStats removes only the regular file <pid>.json written by
// that node, and only once it has been unchanged for nodeStatsStaleAfter.
func removeEndedNodeStats(dir, name string, pid int, now time.Time) bool {
	if name != strconv.Itoa(pid)+".json" {
		return false
	}
	path := filepath.Join(dir, name)
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || now.Sub(info.ModTime()) < nodeStatsStaleAfter {
		return false
	}
	return os.Remove(path) == nil
}

func processAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

func runNodeStats(arguments []string) {
	flags := flag.NewFlagSet("node-stats", flag.ExitOnError)
	socket := flags.String("socket", defaultSocket(), "Unix socket path")
	_ = flags.Parse(arguments)
	if flags.NArg() != 0 {
		fatal("usage: relayd node-stats [--socket path]")
	}
	report, err := collectNodeStats(nodeStatsDir(*socket), time.Now(), processAlive)
	if err != nil {
		fatal(err.Error())
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	_ = encoder.Encode(report)
}
