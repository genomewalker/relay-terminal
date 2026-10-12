package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"golang.org/x/sys/unix"
)

func capsuleWorkerDirectory(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	return dir
}

func capsuleSourceFixture() hostRotationSource {
	return hostRotationSource{Enrollment: hostRotationFixture(),
		Boundary:        hostRotationSourceBoundary{TurnID: "completed-turn", TurnSeq: 12, TranscriptMtimeMS: 1000, TranscriptBytes: 100},
		BindingRevision: "binding-v1", TranscriptSHA256: strings.Repeat("a", 64),
		EvidenceSHA256: strings.Repeat("b", 64), Chunks: []string{"public evidence"}}
}

func TestHostRotationCapsulePersistsExactBytesAndReusesCompleteArtifact(t *testing.T) {
	dir := capsuleWorkerDirectory(t)
	source, draft := capsuleSourceFixture(), preparationDraftFixture()
	draft.Summary = "Keep café, 🧬, <tags>, literal \\\\, and\nnewlines."
	ctx := context.Background()
	receipt, err := stageHostRotationCapsule(ctx, dir, source, draft)
	if err != nil {
		t.Fatal(err)
	}
	body, err := readHostRotationCapsule(ctx, dir, *receipt, source)
	expected, _ := json.Marshal(draft)
	if err != nil || body != string(expected) || receipt.SHA256 != hostRotationCapsuleHash(expected) || receipt.Bytes != len(expected) {
		t.Fatalf("exact bytes not retained: %+v %v", receipt, err)
	}
	if strings.Contains(body, "enrollment") || strings.Contains(body, "source_sha256") {
		t.Fatal("physical identity leaked into restored capsule")
	}
	path := filepath.Join(dir, hostRotationCapsuleDirectory, receipt.ArtifactID+".json")
	before, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	again, err := stageHostRotationCapsule(ctx, dir, source, draft)
	after, _ := os.Stat(path)
	if err != nil || *again != *receipt || !sameRotationSourceFile(before, after) {
		t.Fatalf("completed staging replay changed artifact: %v", err)
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil || len(entries) != 1 {
		t.Fatal("staging created duplicate artifacts")
	}
}

func TestHostRotationCapsuleReadRequiresExactSourceAndReceipt(t *testing.T) {
	dir, source := capsuleWorkerDirectory(t), capsuleSourceFixture()
	receipt, err := stageHostRotationCapsule(context.Background(), dir, source, preparationDraftFixture())
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"session", "client", "cwd", "pane", "agent", "agent_start", "worker", "worker_start", "boot", "turn", "sequence", "mtime", "bytes", "source", "evidence", "revision", "chunks", "artifact", "digest", "length"} {
		t.Run(name, func(t *testing.T) {
			changed, r := source, *receipt
			switch name {
			case "session":
				changed.Enrollment.SessionID = "other"
			case "client":
				changed.Enrollment.Client = "codex"
			case "cwd":
				changed.Enrollment.CWD = "/elsewhere"
			case "pane":
				changed.Enrollment.PaneID = "other-pane"
			case "agent":
				changed.Enrollment.AgentPID++
			case "agent_start":
				changed.Enrollment.AgentStart++
			case "worker":
				changed.Enrollment.WorkerPID++
			case "worker_start":
				changed.Enrollment.WorkerStart++
			case "boot":
				changed.Enrollment.NodeBootID = "other-boot"
			case "turn":
				changed.Boundary.TurnID = "other"
			case "sequence":
				changed.Boundary.TurnSeq++
			case "mtime":
				changed.Boundary.TranscriptMtimeMS++
			case "bytes":
				changed.Boundary.TranscriptBytes++
			case "source":
				changed.TranscriptSHA256 = strings.Repeat("c", 64)
			case "evidence":
				changed.EvidenceSHA256 = strings.Repeat("c", 64)
			case "revision":
				changed.BindingRevision = "different"
			case "chunks":
				changed.Chunks = []string{"one", "two"}
			case "artifact":
				r.ArtifactID = "../../other"
			case "digest":
				r.SHA256 = strings.Repeat("d", 64)
			case "length":
				r.Bytes++
			}
			if _, err := readHostRotationCapsule(context.Background(), dir, r, changed); err == nil {
				t.Fatal("accepted changed identity")
			}
		})
	}
}

func TestHostRotationCapsuleRefusesUnsafeOrIncompleteStorage(t *testing.T) {
	for _, name := range []string{"truncated", "tampered", "oversized", "file_symlink", "root_symlink", "worker_symlink", "hardlink", "public_file", "public_root", "public_worker", "directory", "fifo"} {
		t.Run(name, func(t *testing.T) {
			dir, source := capsuleWorkerDirectory(t), capsuleSourceFixture()
			draft := preparationDraftFixture()
			receipt, err := stageHostRotationCapsule(context.Background(), dir, source, draft)
			if err != nil {
				t.Fatal(err)
			}
			root := filepath.Join(dir, hostRotationCapsuleDirectory)
			path := filepath.Join(root, receipt.ArtifactID+".json")
			var mutateErr error
			switch name {
			case "truncated":
				mutateErr = os.WriteFile(path, []byte("{"), 0o600)
			case "tampered":
				data, e := os.ReadFile(path)
				if e != nil {
					t.Fatal(e)
				}
				data[len(data)/2] ^= 1
				mutateErr = os.WriteFile(path, data, 0o600)
			case "oversized":
				mutateErr = os.WriteFile(path, []byte(strings.Repeat("x", hostRotationCapsuleLimit+1)), 0o600)
			case "file_symlink":
				saved := filepath.Join(dir, "saved")
				if err := os.Rename(path, saved); err != nil {
					t.Fatal(err)
				}
				mutateErr = os.Symlink(saved, path)
			case "root_symlink":
				saved := filepath.Join(dir, "saved")
				if err := os.Rename(root, saved); err != nil {
					t.Fatal(err)
				}
				mutateErr = os.Symlink(saved, root)
			case "worker_symlink":
				link := filepath.Join(capsuleWorkerDirectory(t), "worker")
				mutateErr = os.Symlink(dir, link)
				dir = link
			case "hardlink":
				mutateErr = os.Link(path, filepath.Join(dir, "alias"))
			case "public_file":
				mutateErr = os.Chmod(path, 0o644)
			case "public_root":
				mutateErr = os.Chmod(root, 0o755)
			case "public_worker":
				mutateErr = os.Chmod(dir, 0o755)
			case "directory":
				if err := os.Remove(path); err != nil {
					t.Fatal(err)
				}
				mutateErr = os.Mkdir(path, 0o700)
			case "fifo":
				if err := os.Remove(path); err != nil {
					t.Fatal(err)
				}
				mutateErr = unix.Mkfifo(path, 0o600)
			}
			if mutateErr != nil {
				t.Fatal(mutateErr)
			}
			if _, err := readHostRotationCapsule(context.Background(), dir, *receipt, source); err == nil {
				t.Fatal("unsafe stored capsule accepted")
			}
			if _, err := stageHostRotationCapsule(context.Background(), dir, source, draft); err == nil {
				t.Fatal("unsafe artifact overwritten or reused")
			}
			if name == "truncated" {
				data, _ := os.ReadFile(path)
				if string(data) != "{" {
					t.Fatal("partial artifact overwritten")
				}
			}
		})
	}
}

func TestHostRotationCapsuleCancellationAndConcurrentStaging(t *testing.T) {
	dir, source := capsuleWorkerDirectory(t), capsuleSourceFixture()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := stageHostRotationCapsule(ctx, dir, source, preparationDraftFixture()); !errors.Is(err, context.Canceled) {
		t.Fatal("cancelled staging proceeded")
	}
	if _, err := os.Lstat(filepath.Join(dir, hostRotationCapsuleDirectory)); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("cancelled staging created storage")
	}
	var group sync.WaitGroup
	for i := 0; i < 8; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			// Racing with an incomplete first write may refuse. It must never
			// overwrite it or create another artifact.
			_, _ = stageHostRotationCapsule(context.Background(), dir, source, preparationDraftFixture())
		}()
	}
	group.Wait()
	receipt, err := stageHostRotationCapsule(context.Background(), dir, source, preparationDraftFixture())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := readHostRotationCapsule(context.Background(), dir, *receipt, source); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(filepath.Join(dir, hostRotationCapsuleDirectory))
	if err != nil || len(entries) != 1 {
		t.Fatal("concurrent staging created duplicate artifacts")
	}
}

func TestHostRotationCapsuleRejectsInvalidDraftAndSource(t *testing.T) {
	for _, name := range []string{"nul", "utf8", "large", "empty", "hash", "boundary", "owner", "missing_chunks"} {
		t.Run(name, func(t *testing.T) {
			source, draft := capsuleSourceFixture(), preparationDraftFixture()
			switch name {
			case "nul":
				draft.Summary = "text\x00more"
			case "utf8":
				draft.Summary = string([]byte{0xff})
			case "large":
				draft.Summary = strings.Repeat("x", 6401)
			case "empty":
				draft.NextAction = ""
			case "hash":
				source.EvidenceSHA256 = strings.Repeat("Z", 64)
			case "boundary":
				source.Boundary.TranscriptBytes = 0
			case "owner":
				source.Enrollment.AgentPID = 0
			case "missing_chunks":
				source.Chunks = nil
			}
			if _, _, err := encodeHostRotationCapsule(source, draft); err == nil {
				t.Fatal("invalid capsule encoded")
			}
		})
	}
}

func TestHostRotationPreparationStagesAndRechecksCapsule(t *testing.T) {
	for _, name := range []string{"success", "storage_failure", "stale_source", "cancelled", "wrong_receipt", "missing_stager"} {
		t.Run(name, func(t *testing.T) {
			h, dir := newPreparationHarness(1), capsuleWorkerDirectory(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			var source hostRotationSource
			h.deps.stage = func(ctx context.Context, s hostRotationSource, draft hostRotationDraft) (*hostRotationCapsuleReceipt, error) {
				source = s
				if name == "storage_failure" {
					return nil, errors.New("disk unavailable")
				}
				r, err := stageHostRotationCapsule(ctx, dir, s, draft)
				if err != nil {
					return nil, err
				}
				switch name {
				case "stale_source":
					h.changedAfter = 1
				case "cancelled":
					cancel()
				case "wrong_receipt":
					r.Bytes++
				}
				return r, nil
			}
			if name == "missing_stager" {
				h.deps.stage = nil
			}
			result := prepareHostRotationDraft(ctx, h.e, func() error { return ctx.Err() }, func(hostRotationPreparation) error { return nil }, h.deps)
			if name == "success" {
				if result.State != "prepared" || result.Capsule == nil || result.Draft == nil {
					t.Fatalf("no stored capsule: %+v", result)
				}
				if _, err := readHostRotationCapsule(ctx, dir, *result.Capsule, source); err != nil {
					t.Fatal(err)
				}
			} else if result.State == "prepared" || result.Capsule != nil || result.Draft != nil {
				t.Fatalf("published invalid capsule: %+v", result)
			}
		})
	}
}
