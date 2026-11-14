package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// A state directory shared by several nodes (an NFS home) is cleaned only by
// the daemon on the node that activated deletion. Another node's daemon may be
// an older release with older rules, so it archives and deletes nothing.
func TestOnlyTheActivationNodeDeletesFromASharedArchive(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	now := time.Now()
	activateCleanup(t, s, now.Add(-time.Hour))
	setActivationNode := func(node string) {
		t.Helper()
		path := filepath.Join(hostJobTombstoneDir(s.stateDir), hostJobActivationFile)
		activation, err := readHostJobActivation(s.stateDir)
		if err != nil {
			t.Fatal(err)
		}
		activation.Node = node
		raw, _ := json.Marshal(activation)
		if err := os.WriteFile(path, raw, 0600); err != nil {
			t.Fatal(err)
		}
	}
	writeLiveJob(t, s.stateDir, finishedJob("job-ancient", now.Add(-10*24*time.Hour), 0))

	setActivationNode("othernode.example.org")
	result, err := s.archiveAndCleanupHostJobs(now)
	if err != nil || result.Archived != 1 || result.Removed != 0 || result.CleanupOtherNode != "othernode.example.org" {
		t.Fatalf("other node pass %+v %v", result, err)
	}
	if _, err := os.Stat(filepath.Join(s.stateDir, "host-jobs-completed", "job-ancient", "record.json")); err != nil {
		t.Fatal("another node's daemon deleted an archived job")
	}

	setActivationNode(hostJobServerNode())
	result, err = s.archiveAndCleanupHostJobs(now)
	if err != nil || result.Removed != 1 || result.CleanupOtherNode != "" {
		t.Fatalf("activation node pass %+v %v", result, err)
	}
}

func TestActivationNodeNamesMatchWithOrWithoutDomain(t *testing.T) {
	for _, c := range []struct {
		activation, node string
		same             bool
	}{
		{"dandycomp07fl.unicph.domain", "dandycomp07fl.unicph.domain", true},
		{"dandycomp07fl", "dandycomp07fl.unicph.domain", true},
		{"SUN1028888", "sun1028888.local", true},
		{"dandycomp07fl.unicph.domain", "dandyhead01fl.unicph.domain", false},
		{"dandycomp07fl.unicph.domain", "dandycomp07fl.other.domain", false},
		{"dandycomp07fl", "dandycomp03fl", false},
		{"", "anything", true},
		{"unknown", "anything", true},
	} {
		if got := hostJobActivationNodeIs(c.activation, c.node); got != c.same {
			t.Errorf("%q vs %q: %v, want %v", c.activation, c.node, got, c.same)
		}
	}
}
