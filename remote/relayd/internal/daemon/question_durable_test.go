package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// durableFixture runs the production paths: the store and journal live under the
// real defaultWorkerStateDir layout of a fresh XDG_STATE_HOME.
func durableFixture(t *testing.T) (*questionFixture, func(func(name string) error)) {
	t.Helper()
	// durableDirectory syncs real paths, so the expectations use one.
	stateHome, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("XDG_STATE_HOME", stateHome)
	fx := newQuestionFixture(t, "claude")
	fx.deps.store = questionThreadStore{dir: filepath.Join(defaultWorkerStateDir(), questionThreadDirectory)}
	fx.deps.lock = lockCommunicationRootForQuestions
	saved := questionJournalSync
	t.Cleanup(func() { questionJournalSync = saved })
	return fx, func(fail func(name string) error) {
		questionJournalSync = func(file *os.File) error {
			if err := fail(filepath.Clean(file.Name())); err != nil {
				return err
			}
			return saved(file)
		}
	}
}

// Every directory from the root to the state directory is synced before the
// first claim is dispatched, on a fresh state root.
func TestQuestionFirstUseSyncsEveryAncestorBeforeClaim(t *testing.T) {
	// Exercise the original all-the-way-to-root guarantee on one logical
	// filesystem. The separate mount tests retain the real-device and mount
	// boundary requirements, including failure at every in-filesystem ancestor.
	savedDevice := durableDirectoryDevice
	t.Cleanup(func() { durableDirectoryDevice = savedDevice })
	durableDirectoryDevice = func(string) (uint64, error) { return 7, nil }
	fx, install := durableFixture(t)
	synced := map[string]bool{}
	install(func(name string) error { synced[name] = true; return nil })
	ledger := fx.deps.ledger
	fx.deps.ledger = func(ctx context.Context, op string, args any) (json.RawMessage, error) {
		if op == questionLeaseClaim {
			for dir := filepath.Clean(defaultWorkerStateDir()); ; dir = filepath.Dir(dir) {
				if !synced[dir] {
					t.Fatalf("first claim dispatched before syncing %s", dir)
				}
				if filepath.Dir(dir) == dir {
					break
				}
			}
		}
		return ledger(ctx, op, args)
	}
	if _, err := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-1", "work", 60); err != nil {
		t.Fatal(err)
	}
}

// A failed sync anywhere on the path blocks the first claim.
func TestQuestionFailedAncestorSyncDispatchesNothing(t *testing.T) {
	fx, install := durableFixture(t)
	relayDir := filepath.Dir(defaultWorkerStateDir())
	install(func(name string) error {
		if name == relayDir {
			return errors.New("sync failed")
		}
		return nil
	})
	if _, err := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-1", "work", 60); err == nil {
		t.Fatal("bind must fail when an ancestor cannot be synced")
	}
	if n := countQuestionCalls(fx.chitta.calls, "lease_claim"); n != 0 {
		t.Fatalf("claim dispatched after a failed ancestor sync: %d", n)
	}
}

// The release stage is durable before any lease_release is sent.
func TestQuestionReleaseIntentIsDurableBeforeRelease(t *testing.T) {
	fx, install := durableFixture(t)
	ctx := context.Background()
	if _, err := bindQuestionThread(ctx, fx.deps, "pane-1", "thread-1", "work", 60); err != nil {
		t.Fatal(err)
	}
	install(func(name string) error {
		if name == fx.deps.store.dir {
			return errors.New("sync failed")
		}
		return nil
	})
	if _, err := unbindQuestionThread(ctx, fx.deps, "pane-1"); err == nil {
		t.Fatal("unbind must fail when the release stage cannot be made durable")
	}
	if n := countQuestionCalls(fx.chitta.calls, "lease_release"); n != 0 {
		t.Fatalf("release sent without a durable release stage: %d", n)
	}
}

// A final removal that cannot be made durable is reported, and the record is not
// treated as gone. The retry is the same release step.
func TestQuestionRemovalNotDurableIsReported(t *testing.T) {
	fx, install := durableFixture(t)
	ctx := context.Background()
	if _, err := bindQuestionThread(ctx, fx.deps, "pane-1", "thread-1", "work", 60); err != nil {
		t.Fatal(err)
	}
	released := false
	install(func(name string) error {
		if name == fx.deps.store.dir && released {
			return errors.New("sync failed")
		}
		return nil
	})
	ledger := fx.deps.ledger
	fx.deps.ledger = func(ctx context.Context, op string, args any) (json.RawMessage, error) {
		raw, err := ledger(ctx, op, args)
		if op == questionLeaseRelease {
			released = true
		}
		return raw, err
	}
	if _, err := unbindQuestionThread(ctx, fx.deps, "pane-1"); err == nil {
		t.Fatal("unbind must report a removal that is not durable")
	}
	stored, found, err := fx.deps.loadQuestionState("pane-1")
	if err != nil || !found || stored.ReleaseStage == "" {
		t.Fatalf("record should remain in a release stage: found=%v stage=%q err=%v", found, stored.ReleaseStage, err)
	}
}
