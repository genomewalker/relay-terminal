package daemon

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// A shared (NFS) state directory is seen by daemons on several nodes. Only the
// node whose workers own the configured panes may tick the controller; another
// node would replace every observation with "previous node boot" refusals.
func TestHostPaneHealthTickRunsOnlyOnThePanesNode(t *testing.T) {
	boot, err := nodeBootID()
	if err != nil || boot == "" {
		t.Skip("node boot identity unavailable")
	}
	root := t.TempDir()
	pane := "90a0f5b3-0cd9-4e54-9bd1-3239b6fd8bc0"
	controller := filepath.Join(root, "pane-health-controller")
	if err := os.MkdirAll(controller, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(controller, "configuration.json"),
		[]byte(`{"enabled":true,"generation":3,"panes":["`+pane+`"]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(root, pane+".json")
	writeBoot := func(id string) {
		if err := storeManifest(manifestPath, workerManifest{Version: workerProtocolVersion, SessionID: pane, WorkerPID: 4242, WorkerStartTime: 7, NodeBootID: id}); err != nil {
			t.Fatal(err)
		}
	}
	s := newHostPaneHealthSupervisor(root, "unused")
	s.manifest = func(id string) string { return filepath.Join(root, id+".json") }

	writeBoot("another-node-boot")
	if !s.configuredElsewhere() {
		t.Fatal("panes owned by another node's workers were treated as local")
	}
	writeBoot(boot)
	if s.configuredElsewhere() {
		t.Fatal("this node's own panes were skipped")
	}
	if err := os.Remove(manifestPath); err != nil {
		t.Fatal(err)
	}
	if s.configuredElsewhere() {
		t.Fatal("a pane without a manifest must keep the former behaviour")
	}
	s.manifest = nil
	writeBoot("another-node-boot")
	if s.configuredElsewhere() {
		t.Fatal("without a manifest locator the supervisor must keep ticking")
	}

	// The run loop does not call the controller while the panes are elsewhere,
	// and resumes when it is woken after they are local.
	s.manifest = func(id string) string { return filepath.Join(root, id+".json") }
	ticks := make(chan struct{}, 4)
	s.command = func(context.Context, string, any) (json.RawMessage, error) {
		ticks <- struct{}{}
		return json.RawMessage(`{"next_check_seconds":-1}`), nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stopped := make(chan struct{})
	go func() { s.run(ctx); close(stopped) }()
	select {
	case <-ticks:
		t.Fatal("another node's daemon ticked the shared controller")
	case <-time.After(300 * time.Millisecond):
	}
	writeBoot(boot)
	s.notify()
	select {
	case <-ticks:
	case <-time.After(3 * time.Second):
		t.Fatal("the panes' own node did not tick after being woken")
	}
	cancel()
	<-stopped
}
