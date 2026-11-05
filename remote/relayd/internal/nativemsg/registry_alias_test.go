//go:build linux || darwin

package nativemsg

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func aliasFixture(t *testing.T) (string, *registryProc, [][]byte) {
	t.Helper()
	base, err := os.MkdirTemp("/tmp", "nca-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(base) })
	proc, live := acceptedRegistry(t, base, 2, 0, 0)
	var data [][]byte
	for _, pid := range live {
		path := filepath.Join(base, "sessions", fmt.Sprintf("%d.json", pid))
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		data = append(data, raw)
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
	}
	return base, proc, data
}

func aliasRunner(proc *registryProc) *runner {
	return &runner{ctx: context.Background(), proc: proc, uid: int64(os.Getuid()), home: "/nonexistent-home"}
}

func requireDuplicateRefusal(t *testing.T, got []peerRecord, err error) {
	t.Helper()
	if len(got) != 0 || err == nil || !strings.Contains(err.Error(), "duplicate live worker records") {
		t.Fatalf("duplicate accepted: records=%d error=%v; want no records and explicit duplicate refusal", len(got), err)
	}
}

// The original counterexample: one live identity published under 2049
// filenames. Rejection is required, not choosing the first or silently
// deduplicating possibly conflicting publications. This uses real files and
// socket nodes, with registryProc trusted for process identities.
func TestRegistryAliasPopulationRefused(t *testing.T) {
	base, proc, data := aliasFixture(t)
	delete(proc.alive, firstWorker+1)
	for i := 0; i < 2049; i++ {
		name := fmt.Sprintf("alias-%04d.json", i)
		if i == 0 {
			name = fmt.Sprintf("%d.json", firstWorker)
		}
		if err := os.WriteFile(filepath.Join(base, "sessions", name), data[0], 0600); err != nil {
			t.Fatal(err)
		}
	}
	got, err := aliasRunner(proc).peerRecords(recipientPID, "claude", "")
	requireDuplicateRefusal(t, got, err)
}

// Reject conflicts across batches, while preserving the existing exact-session
// filter: a nonmatching session is not a candidate for the selected session.
func TestRegistryAliasConflictAndSessionFence(t *testing.T) {
	base, proc, data := aliasFixture(t)
	registry := filepath.Join(base, "sessions")
	conflict := []byte(strings.ReplaceAll(string(data[0]), "00000201-0000-4000-8000-000000000000", "99999999-0000-4000-8000-000000000000"))
	if reflect.DeepEqual(conflict, data[0]) {
		t.Fatal("conflict fixture unchanged")
	}
	for name, raw := range map[string][]byte{"first.json": data[0], "conflict.json": conflict} {
		if err := os.WriteFile(filepath.Join(registry, name), raw, 0600); err != nil {
			t.Fatal(err)
		}
	}
	old := registryBatchSize
	registryBatchSize = 1
	t.Cleanup(func() { registryBatchSize = old })
	r := aliasRunner(proc)
	got, err := r.peerRecords(recipientPID, "claude", "")
	requireDuplicateRefusal(t, got, err)
	got, err = r.peerRecords(recipientPID, "claude", "00000201-0000-4000-8000-000000000000")
	if err != nil || !reflect.DeepEqual(workerPIDs(got), []int64{firstWorker}) {
		t.Fatalf("session fence: %v %v", workerPIDs(got), err)
	}
}

// Enumerate every ordered registry publication sequence of length 0..4 over
// six kinds: worker A, conflicting session for A, worker B, dead record,
// relayProxy, malformed JSON. Cross with Claude/Codex and batches 1/256.
// 1555 sequences x 2 providers x 2 batches = 6220 cases.
// P1 Codex performs no inventory or environment read.
// P2 Every accepted worker occurs at most once; output has no dead/proxy rows.
// P3 Duplicate accepted workers reject the entire result (no partial prefix).
// P4 Nonconflicting accepted sets equal the independently counted model.
func TestRegistryAliasBoundedSequences(t *testing.T) {
	base, proc, data := aliasFixture(t)
	registry := filepath.Join(base, "sessions")
	a := string(data[0])
	choices := [][]byte{
		data[0],
		[]byte(strings.ReplaceAll(a, "00000201-0000-4000-8000-000000000000", "99999999-0000-4000-8000-000000000000")),
		data[1],
		[]byte(strings.ReplaceAll(a, `"pid":201`, `"pid":999999`)),
		[]byte(strings.TrimSuffix(a, "}") + `,"relayProxy":true}`),
		[]byte(`{"pid":`),
	}
	originalBatch := registryBatchSize
	t.Cleanup(func() { registryBatchSize = originalBatch })
	cases := 0
	var visit func([]int)
	visit = func(seq []int) {
		counts := map[int64]int{}
		paths := make([]string, len(seq))
		for i, kind := range seq {
			paths[i] = filepath.Join(registry, fmt.Sprintf("sequence-%02d.json", i))
			if err := os.WriteFile(paths[i], choices[kind], 0600); err != nil {
				t.Fatal(err)
			}
			switch kind {
			case 0, 1:
				counts[firstWorker]++
			case 2:
				counts[firstWorker+1]++
			}
		}
		duplicate := counts[firstWorker] > 1 || counts[firstWorker+1] > 1
		want := []int64{}
		for _, pid := range []int64{firstWorker, firstWorker + 1} {
			if counts[pid] > 0 {
				want = append(want, pid)
			}
		}
		for _, batch := range []int{1, 256} {
			registryBatchSize = batch
			for _, provider := range []string{"claude", "codex"} {
				before := proc.reads
				got, err := aliasRunner(proc).peerRecords(recipientPID, provider, "")
				cases++
				if provider == "codex" {
					if len(got) != 0 || err != nil || proc.reads != before {
						t.Fatalf("P1 seq=%v got=%d err=%v reads=%d", seq, len(got), err, proc.reads-before)
					}
				} else if duplicate {
					requireDuplicateRefusal(t, got, err)
				} else {
					if err != nil || !reflect.DeepEqual(sortedPIDs(got), want) {
						t.Fatalf("P2/P4 seq=%v batch=%d got=%v want=%v err=%v", seq, batch, workerPIDs(got), want, err)
					}
				}
			}
		}
		for _, path := range paths {
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
		}
		if len(seq) < 4 {
			for kind := range choices {
				visit(append(append([]int{}, seq...), kind))
			}
		}
	}
	visit(nil)
	if cases != 6220 {
		t.Fatalf("case bound changed: %d", cases)
	}
	t.Logf("6220 cases over all 1555 publication sequences, length 0..4; P1-P4 checked")
}
