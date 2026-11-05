package daemon

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
)

func TestForceAccountDispatchConsumesUncertainCommit(t *testing.T) {
	dir := t.TempDir()
	id := "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
	argv := []string{"/bin/sh", "-c", "example"}
	target := forceAccountTarget{Pane: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", Provider: "claude", Session: "session", ProviderPID: 10, ProviderStart: "1", BlockerPID: 11, BlockerStart: "2", CommandDigest: forceAccountCommandDigest(argv)}
	request := &forceAccountRPCRequest{ActionID: id, Target: target, ReviewedArgv: argv}
	calls := 0
	backend := forceAccountRPCBackend{
		reserve: func(id string) error { return reserveForceRequest(dir, id) },
		commit: func(forceAccountTarget, []string) (forceAccountResult, error) {
			calls++
			return forceAccountUnknown, errors.New("uncertain")
		},
	}
	bad := *request
	bad.ReviewedArgv = []string{"other"}
	if _, err := dispatchForceAccountRPC("account_force_commit", &bad, backend); err == nil {
		t.Fatal("unreviewed argv accepted")
	}
	if _, err := dispatchForceAccountRPC("account_force_commit", request, backend); err == nil {
		t.Fatal("uncertain commit reported success")
	}
	if _, err := dispatchForceAccountRPC("account_force_commit", request, backend); err == nil || calls != 1 {
		t.Fatalf("uncertain commit replayed: calls=%d err=%v", calls, err)
	}
}

func TestForceAccountPreviewDoesNotReserveOrCommit(t *testing.T) {
	target := forceAccountTarget{Pane: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", Provider: "claude", Session: "session", ProviderPID: 10, ProviderStart: "1", BlockerPID: 11}
	called := false
	backend := forceAccountRPCBackend{preview: func(got forceAccountTarget) (any, error) {
		called = true
		if got != target {
			t.Fatal("selection changed")
		}
		return map[string]any{"status": "ready"}, nil
	}}
	if _, err := dispatchForceAccountRPC("account_force_preview", &forceAccountRPCRequest{Target: target}, backend); err != nil || !called {
		t.Fatalf("preview failed: %v", err)
	}
	if _, err := dispatchForceAccountRPC("account_force_commit", &forceAccountRPCRequest{Target: target}, backend); err == nil {
		t.Fatal("unresolved preview accepted as commit")
	}
}

func TestForceAccountReservationPersistsAndRejectsConcurrentReplay(t *testing.T) {
	dir := t.TempDir()
	id := "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
	var success atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if reserveForceRequest(dir, id) == nil {
				success.Add(1)
			}
		}()
	}
	wg.Wait()
	if success.Load() != 1 {
		t.Fatalf("reservations: %d", success.Load())
	}
	if reserveForceRequest(dir, "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE") == nil {
		t.Fatal("case-variant replay accepted")
	}
	if reserveForceRequest(dir, "../bad") == nil {
		t.Fatal("invalid id accepted")
	}
	if _, err := os.Stat(filepath.Join(dir, "account-force-requests", id)); err != nil {
		t.Fatal(err)
	}
}

func TestForceAccountRoutesUnavailable(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	for _, op := range []string{"account_force_preview", "account_force_commit"} {
		if _, err := s.hostRPC(hostRequest{Operation: op, RequestID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", JobID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"}); err == nil {
			t.Fatalf("%s unexpectedly exposed", op)
		}
	}
}
