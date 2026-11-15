package appupdate

import (
	"errors"
	"fmt"
	"reflect"
	"sort"
	"strings"
	"testing"
)

// A preserved process that exits after staging must fail the restart while
// the UI is still running, with a message that names the cause. Before this,
// the bare EIO surfaced as "input/output error" after the UI had already quit.
func TestRestartStaleBaselineFailsBeforeQuit(t *testing.T) {
	f := newFixture(t)
	root := f.stage()
	f.ui = []int{10}
	delete(f.ident, 100) // The staged agent process has exited.
	f.e.Kernel = func(pid int) (string, error) {
		id, ok := f.ident[pid]
		if !ok {
			return "", fmt.Errorf("%w: pid %d", ErrProcessExited, pid)
		}
		return id, nil
	}
	_, e := f.e.Restart(RestartOptions{Preservation: root, Timeout: 1})
	if !errors.Is(e, ErrProcessExited) || !strings.Contains(e.Error(), "stage the update again") {
		t.Fatal("stale baseline must name the exited process", e)
	}
	for _, c := range f.calls {
		if c.Args[0] == "/usr/bin/osascript" {
			t.Fatal("stale baseline quit the UI")
		}
	}
	if f.opened != 0 || f.binary() != "old" || len(f.ui) != 1 {
		t.Fatal("stale baseline touched the UI or the bundle")
	}
}

func TestStageRecordsOnlyPaneAgents(t *testing.T) {
	f := newFixture(t)
	root := f.stage()
	b, e := f.e.baseline(root)
	if e != nil {
		t.Fatal(e)
	}
	got := []string{}
	for p := range b.Identities {
		got = append(got, p)
	}
	sort.Strings(got)
	if want := []string{"100", "200", "300", "400"}; !reflect.DeepEqual(got, want) {
		t.Fatal("baseline must hold the pane agent, supervisor, worker and shell", got)
	}
}

func TestPaneAgentSelection(t *testing.T) {
	const ui, daemon, worker, shell = 10, 20, 30, 40
	rows := map[int]string{
		ui: "/Applications/Relay.app/Contents/MacOS/Relay", daemon: "/Applications/Relay.app/Contents/MacOS/relayd",
		worker: "/Applications/Relay.app/Contents/MacOS/relayd", shell: "/bin/bash",
		50: "claude",                                      // pane agent in the worker's shell
		51: "/bin/sh",                                     // hook launched by the pane agent
		52: "/Users/u/.local/share/claude/versions/2.1.3", // claude -p below the pane agent's hook
		53: "/Users/u/.local/share/claude/versions/2.1.3", // relayd's own claude -p helper
		54: "/Users/u/.local/bin/claude",                  // orphaned claude
		55: "/Applications/ChatGPT.app/Contents/MacOS/codex",
		56: "/bin/zsh", 57: "codex", // agent in a UI-owned shell
		58: "codex", 59: "codex", // parent cycle
		60: "codex", 61: "/Applications/Relay.app/Contents/MacOS/relayd", 62: "/Users/u/.codex/bin/codex", // managed backend
	}
	parents := map[int]int{ui: 1, daemon: 1, worker: 1, shell: worker, 50: shell, 51: 50, 52: 51, 53: daemon, 54: 1, 55: 1, 56: ui, 57: 56, 58: 59, 59: 58, 60: shell, 61: 60, 62: 61}
	got := paneAgents(rows, parents, map[int]bool{ui: true, worker: true, shell: true})
	sort.Ints(got)
	if !reflect.DeepEqual(got, []int{50, 52, 57, 60, 62}) {
		t.Fatal("pane agent selection changed", got)
	}
}

func TestParseParentsBounds(t *testing.T) {
	if m, e := parseParents([]byte(" 1 0\n 22 1\n\n")); e != nil || !reflect.DeepEqual(m, map[int]int{1: 0, 22: 1}) {
		t.Fatal("parent listing parse changed", m, e)
	}
	for _, bad := range []string{"1\n", "x 1\n", "1 -1\n", "1 0\n1 0\n", "1 2 3\n"} {
		if _, e := parseParents([]byte(bad)); e == nil {
			t.Fatal("malformed parent row accepted", bad)
		}
	}
}
