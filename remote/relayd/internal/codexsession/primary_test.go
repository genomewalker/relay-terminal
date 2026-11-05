package codexsession

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

const (
	rootThread  = "01a130eb-538a-7061-ac48-8948c8677b98"
	childThread = "01a135e5-6228-79a0-bd06-4e84a17c1568"
	grandchild  = "01a135e6-0000-7000-8000-000000000001"
	otherRoot   = "01a12f01-d52c-7f41-8972-0396293b5aff"
)

func parentsFrom(m map[string]string) func(string) (string, error) {
	return func(id string) (string, error) {
		parent, ok := m[id]
		if !ok {
			return "", errors.New("unreadable")
		}
		return parent, nil
	}
}

func TestSelectPrimaryThreadWithOwnedChildren(t *testing.T) {
	connected := func(ids ...string) []runtimeOrigin {
		rows := []runtimeOrigin{}
		for _, id := range ids {
			rows = append(rows, runtimeOrigin{ThreadID: id, Origin: "tui", Status: "connected"})
		}
		return rows
	}
	spawn := map[string]string{rootThread: "", childThread: rootThread, grandchild: childThread, otherRoot: ""}
	for name, tc := range map[string]struct {
		matches []runtimeOrigin
		parents map[string]string
		want    string
	}{
		"single":                      {connected(rootThread), spawn, rootThread},
		"root with child":             {connected(childThread, rootThread), spawn, rootThread},
		"root with nested children":   {connected(grandchild, rootThread, childThread), spawn, rootThread},
		"two top-level threads":       {connected(rootThread, otherRoot), spawn, ""},
		"only children":               {connected(childThread, grandchild), spawn, ""},
		"child of an unloaded thread": {connected(rootThread, grandchild), spawn, ""},
		"child of another root":       {connected(rootThread, otherRoot, childThread), spawn, ""},
		"unreadable child metadata":   {connected(rootThread, childThread), map[string]string{rootThread: ""}, ""},
		"self-parented thread":        {connected(rootThread, childThread), map[string]string{rootThread: "", childThread: childThread}, ""},
		"cycle without a root":        {connected(childThread, grandchild), map[string]string{childThread: grandchild, grandchild: childThread}, ""},
	} {
		got, err := selectPrimaryThread(tc.matches, parentsFrom(tc.parents))
		if got != tc.want || (tc.want == "") != (err != nil) {
			t.Errorf("%s: got %q, %v; want %q", name, got, err, tc.want)
		}
	}
	disconnected := connected(rootThread, childThread)
	disconnected[0].Status = "disconnected"
	if _, err := selectPrimaryThread(disconnected, parentsFrom(spawn)); err == nil {
		t.Error("a disconnected root was selected")
	}
}

func TestThreadSpawnParentReadsOnlyTheThreadsOwnRecord(t *testing.T) {
	dir := t.TempDir()
	write := func(name, line string, mode os.FileMode) string {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(line+"\n{\"type\":\"turn_context\"}\n"), mode); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, mode); err != nil {
			t.Fatal(err)
		}
		return path
	}
	root := write("root.jsonl", `{"type":"session_meta","payload":{"id":"`+rootThread+`","source":"vscode"}}`, 0o600)
	child := write("child.jsonl", `{"type":"session_meta","payload":{"id":"`+childThread+`","source":{"subagent":{"thread_spawn":{"parent_thread_id":"`+rootThread+`","depth":1}}}}}`, 0o600)
	review := write("review.jsonl", `{"type":"session_meta","payload":{"id":"`+childThread+`","source":{"subagent":"review"}}}`, 0o600)
	shared := write("shared.jsonl", `{"type":"session_meta","payload":{"id":"`+childThread+`","source":{"subagent":{"thread_spawn":{"parent_thread_id":"`+rootThread+`"}}}}}`, 0o622)
	if got, err := threadSpawnParent(root, rootThread); err != nil || got != "" {
		t.Fatalf("root = %q, %v", got, err)
	}
	if got, err := threadSpawnParent(child, childThread); err != nil || got != rootThread {
		t.Fatalf("child = %q, %v", got, err)
	}
	for name, check := range map[string]func() (string, error){
		"another thread's record": func() (string, error) { return threadSpawnParent(child, rootThread) },
		"unknown agent source":    func() (string, error) { return threadSpawnParent(review, childThread) },
		"group-writable file":     func() (string, error) { return threadSpawnParent(shared, childThread) },
		"missing file":            func() (string, error) { return threadSpawnParent(filepath.Join(dir, "missing"), rootThread) },
	} {
		if got, err := check(); err == nil {
			t.Errorf("%s: accepted with parent %q", name, got)
		}
	}
	link := filepath.Join(dir, "link.jsonl")
	if err := os.Symlink(child, link); err != nil {
		t.Fatal(err)
	}
	if _, err := threadSpawnParent(link, childThread); err == nil {
		t.Error("followed a symlinked transcript")
	}
}
