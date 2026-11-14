package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A state directory shared by several nodes (an NFS home) is cleaned only by
// the daemon on the node that activated deletion while that node's daemon is
// running passes. Another node's daemon may be an older release with older
// rules, so it archives and deletes nothing. When the activation node stops
// checking in (gone, or renamed), this node cleans and warns on every pass.
func TestOnlyTheActivationNodeDeletesFromASharedArchive(t *testing.T) {
	now := time.Now()
	setup := func(t *testing.T, node string, refreshed *time.Time) *Server {
		t.Helper()
		s := &Server{stateDir: t.TempDir()}
		activateCleanup(t, s, now.Add(-time.Hour))
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
		if refreshed != nil {
			marker := hostJobServerMarker{Node: node, PID: 99999, ProcessStart: "1", Version: "0.5.49",
				Protocol: hostJobServerProtocol, StateDir: s.stateDir, FirstSeen: now.Add(-48 * time.Hour).UTC().Format(time.RFC3339Nano),
				StartedAt: refreshed.UTC().Format(time.RFC3339Nano), RefreshedAt: refreshed.UTC().Format(time.RFC3339Nano)}
			raw, _ := json.Marshal(marker)
			if err := os.WriteFile(filepath.Join(hostJobServerDir(s.stateDir), node+".json"), raw, 0600); err != nil {
				t.Fatal(err)
			}
		}
		writeLiveJob(t, s.stateDir, finishedJob("job-ancient", now.Add(-10*24*time.Hour), 0))
		return s
	}
	archivedStillThere := func(s *Server) bool {
		_, err := os.Stat(filepath.Join(s.stateDir, "host-jobs-completed", "job-ancient", "record.json"))
		return err == nil
	}

	t.Run("activation node active elsewhere", func(t *testing.T) {
		recent := now.Add(-20 * time.Minute)
		s := setup(t, "othernode.example.org", &recent)
		result, err := s.archiveAndCleanupHostJobs(now)
		if err != nil || result.Archived != 1 || result.Removed != 0 || result.CleanupOtherNode != "othernode.example.org" || result.CleanupFallback != "" {
			t.Fatalf("pass %+v %v", result, err)
		}
		if !archivedStillThere(s) {
			t.Fatal("another node's daemon deleted an archived job")
		}
	})
	t.Run("activation node stopped checking in", func(t *testing.T) {
		stale := now.Add(-hostJobActivationNodeStale - time.Minute)
		s := setup(t, "othernode.example.org", &stale)
		result, err := s.archiveAndCleanupHostJobs(now)
		if err != nil || result.Removed != 1 || result.CleanupOtherNode != "" || !strings.Contains(result.CleanupFallback, "othernode.example.org") {
			t.Fatalf("pass %+v %v", result, err)
		}
	})
	t.Run("activation node never registered", func(t *testing.T) {
		s := setup(t, "renamed-mac", nil)
		result, err := s.archiveAndCleanupHostJobs(now)
		if err != nil || result.Removed != 1 || result.CleanupFallback == "" {
			t.Fatalf("pass %+v %v", result, err)
		}
	})
	t.Run("this node is the activation node", func(t *testing.T) {
		s := setup(t, hostJobServerNode(), nil)
		result, err := s.archiveAndCleanupHostJobs(now)
		if err != nil || result.Removed != 1 || result.CleanupOtherNode != "" || result.CleanupFallback != "" {
			t.Fatalf("pass %+v %v", result, err)
		}
	})
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
