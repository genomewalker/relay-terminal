package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/loopbackproxy"
	"golang.org/x/sys/unix"
)

func TestNodeStatsRemovesOnlyStaleFilesOfEndedNodes(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	old := now.Add(-2 * nodeStatsStaleAfter)
	write := func(name string, pid int, modified time.Time) string {
		data, err := json.Marshal(loopbackproxy.NodeStatsSnapshot{PID: pid, UpdatedAt: modified})
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(path, modified, modified); err != nil {
			t.Fatal(err)
		}
		return path
	}
	ended := write("101.json", 101, old)
	live := write("102.json", 102, old)
	justEnded := write("103.json", 103, now.Add(-time.Second))
	misnamed := write("104.json", 105, old)
	target := write("target", 106, old)
	link := filepath.Join(dir, "106.json")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	stale := unix.NsecToTimeval(old.UnixNano())
	if err := unix.Lutimes(link, []unix.Timeval{stale, stale}); err != nil {
		t.Fatal(err)
	}

	alive := func(pid int) bool { return pid == 102 }
	report, err := collectNodeStats(dir, now, alive)
	if err != nil {
		t.Fatal(err)
	}
	if len(report.Live) != 1 || report.Live[0].PID != 102 || report.Ended != 4 || report.Removed != 1 {
		t.Fatalf("report %+v", report)
	}
	if _, err := os.Lstat(ended); !os.IsNotExist(err) {
		t.Fatal("stale file of an ended node was kept")
	}
	for _, path := range []string{live, justEnded, misnamed, link, target} {
		if _, err := os.Lstat(path); err != nil {
			t.Fatalf("%s removed: %v", filepath.Base(path), err)
		}
	}

	// A second pass finds nothing more to remove.
	report, err = collectNodeStats(dir, now, alive)
	if err != nil || report.Ended != 3 || report.Removed != 0 {
		t.Fatalf("second pass %+v %v", report, err)
	}
}
