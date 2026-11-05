package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// phNativeWithoutText is the native backend whose text journal cannot open:
// probes answer from the fake harness, the journal never opens.
func phNativeWithoutText(h *phHarness, starts *atomic.Int32) *paneHealthNativeBackend {
	native := newPaneHealthNativeBackend(context.Background(), h.root, "/relayd")
	native.probe = func(_ context.Context, pane, _ string) *pyObject {
		value, err := h.backend.Probe(pane)
		if err != nil {
			panic(err)
		}
		return value.(*pyObject)
	}
	native.startText = func(context.Context, string) (*paneHealthTextBackend, error) {
		starts.Add(1)
		return nil, errors.New("text journal unavailable")
	}
	return native
}

// Native checks never open the text journal; only an operation reaching
// text_backend needs it, and fails as a lost backend when it cannot open.
func TestPaneHealthProbesRunWithoutTextJournalAndOnlyTextOperationsFail(t *testing.T) {
	h := newPHHarness(t)
	h.ok(h.configure("haiku_enabled", false))
	var starts atomic.Int32
	run := func(operation string, request any) *pyObject {
		return runPaneHealthController(h.root, phNativeWithoutText(h, &starts), h.now, func() bool { return true }, operation, request)
	}
	state := h.ok(run("tick", newPyObject())).Get("state").(*pyObject)
	if starts.Load() != 0 || !pyIndex(state, "observations").(*pyObject).Has(phPane) {
		t.Fatalf("probe-only tick opened the text journal (%d starts): %s", starts.Load(), pyCompact(state))
	}
	row := h.observe(phPane).Get("facts")
	h.failed(run("desktop_facts", pyObj("owner_id", phOwner, "generation", pyIndex(h.load("configuration.json"), "generation"), "facts", pyListOf(row))),
		"controller_state_or_backend_unavailable")
	if starts.Load() != 1 {
		t.Fatalf("desktop_facts text starts = %d", starts.Load())
	}
	if h.load("desktop-facts.json").(*pyObject).Len() != 0 {
		t.Fatal("facts stored without text validation")
	}
}

// One operation opens at most one text journal, however its calls arrive.
func TestPaneHealthNativeBackendOpensOneTextJournalUnderConcurrency(t *testing.T) {
	backend := newPaneHealthNativeBackend(context.Background(), t.TempDir(), "/relayd")
	var starts, active, overlapped atomic.Int32
	backend.startText = func(context.Context, string) (*paneHealthTextBackend, error) {
		starts.Add(1)
		if active.Add(1) > 1 {
			overlapped.Store(1)
		}
		time.Sleep(20 * time.Millisecond)
		active.Add(-1)
		return nil, errors.New("text journal unavailable")
	}
	var wait sync.WaitGroup
	for range 16 {
		wait.Add(1)
		go func() {
			defer wait.Done()
			if _, err := backend.Status("op"); !errors.Is(err, errPaneHealthBackendLost) {
				t.Errorf("status = %v", err)
			}
		}()
	}
	wait.Wait()
	backend.Close()
	if starts.Load() != 1 || overlapped.Load() != 0 {
		t.Fatalf("text starts = %d, overlapped = %d", starts.Load(), overlapped.Load())
	}
}

// A diverged text ledger (an older relayd wrote the legacy journal after the
// import) stops only the text path: probes keep running, the text service
// reports journal_diverged with its recovery message, and pane health's text
// calls fail as a lost backend.
func TestPaneHealthProbesSurviveADivergedTextLedger(t *testing.T) {
	h := newPHHarness(t)
	h.ok(h.configure("haiku_enabled", false))
	status := func() map[string]any {
		raw, err := hostRotationTextService(context.Background(), h.root, "status", map[string]any{})
		if err != nil {
			t.Fatal(err)
		}
		var result map[string]any
		if json.Unmarshal(raw, &result) != nil {
			t.Fatal("invalid status")
		}
		return result
	}
	if err := os.Mkdir(filepath.Join(h.root, "rotation-text"), 0o700); err != nil {
		t.Fatal(err)
	}
	if result := status(); result["status"] != "ready" {
		t.Fatalf("fresh ledger status: %v", result)
	}
	legacy := filepath.Join(h.root, "rotation-text", "operations.sqlite3")
	if err := os.WriteFile(legacy, []byte("written by an older relayd"), 0o600); err != nil {
		t.Fatal(err)
	}
	if result := status(); result["code"] != "journal_diverged" || !strings.Contains(fmt.Sprint(result["message"]), legacy) {
		t.Fatalf("diverged status: %v", result)
	}
	native := newPaneHealthNativeBackend(context.Background(), h.root, "/relayd")
	native.probe = func(_ context.Context, pane, _ string) *pyObject {
		value, err := h.backend.Probe(pane)
		if err != nil {
			panic(err)
		}
		return value.(*pyObject)
	}
	defer native.Close()
	run := func(operation string, request any) *pyObject {
		return runPaneHealthController(h.root, native, h.now, func() bool { return true }, operation, request)
	}
	state := h.ok(run("tick", newPyObject())).Get("state").(*pyObject)
	if !pyIndex(state, "observations").(*pyObject).Has(phPane) {
		t.Fatalf("probe stopped with the text ledger: %s", pyCompact(state))
	}
	row := h.observe(phPane).Get("facts")
	h.failed(run("desktop_facts", pyObj("owner_id", phOwner, "generation", pyIndex(h.load("configuration.json"), "generation"), "facts", pyListOf(row))),
		"controller_state_or_backend_unavailable")
	if _, err := native.Status("op"); !errors.Is(err, errPaneHealthBackendLost) {
		t.Fatalf("text call on a diverged ledger = %v", err)
	}
}
