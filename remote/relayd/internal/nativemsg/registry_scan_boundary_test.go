//go:build linux || darwin

package nativemsg

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"sort"
	"strings"
	"testing"
)

// fillRegistry creates count entries in dir: every third one a .key file,
// the rest <n>.json, and returns the .json names sorted.
func fillRegistry(t *testing.T, dir string, first, count int, contents string) []string {
	t.Helper()
	var names []string
	for i := 0; i < count; i++ {
		name := fmt.Sprintf("%d.json", first+i)
		if i%3 == 2 {
			name = fmt.Sprintf("%d.0123456789abcdef.key", first+i)
		} else {
			names = append(names, name)
		}
		if err := os.WriteFile(filepath.Join(dir, name), []byte(contents), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	sort.Strings(names)
	return names
}

func isLimitError(err error) bool {
	return err != nil && strings.Contains(err.Error(), "Native session registry exceeds limit")
}

// directoryJSONNames is every *.json entry of dir in directory order, as
// globNames(dir, "*.json", false) lists it.
func directoryJSONNames(t *testing.T, dir string) []string {
	t.Helper()
	names, err := globNames(dir, "*.json", false)
	if err != nil {
		t.Fatal(err)
	}
	return names
}

// collectBatches runs forEachRegistryBatch over dir, checking that every
// visit holds 1..batch names, and returns the visited names in order and the
// number of visits.
func collectBatches(t *testing.T, dir string, batch int) ([]string, int) {
	t.Helper()
	saved := registryBatchSize
	registryBatchSize = batch
	defer func() { registryBatchSize = saved }()
	var got []string
	visits := 0
	denied, err := forEachRegistryBatch(dir, func(names []string) error {
		visits++
		if len(names) == 0 || len(names) > batch {
			t.Fatalf("batch=%d: a visit held %d names", batch, len(names))
		}
		got = append(got, names...)
		return nil
	})
	if err != nil || denied {
		t.Fatalf("batch=%d: denied=%v err=%v", batch, denied, err)
	}
	return got, visits
}

// Replaces TestRegistryNamesBatchBoundaries (which asserted the scan cap at
// each limit): around each 256-entry batch transition, and with batches of
// 1, 255, 256 and 257 entries, the stream visits every *.json name exactly
// once, in directory order, at most batch names per visit, and needs at
// least ceil(names/batch) visits; no count raises.
func TestRegistryBatchBoundaries(t *testing.T) {
	for _, count := range []int{0, 1, 255, 256, 257, 511, 512, 513, 768, 769} {
		dir := t.TempDir()
		want := fillRegistry(t, dir, 1000, count, "{}")
		ordered := directoryJSONNames(t, dir)
		for _, batch := range []int{1, 255, 256, 257} {
			got, visits := collectBatches(t, dir, batch)
			if !reflect.DeepEqual(got, ordered) && !(len(got) == 0 && len(ordered) == 0) {
				t.Fatalf("count=%d batch=%d: visited %d names out of directory order (want %d)", count, batch, len(got), len(ordered))
			}
			if minVisits := (len(want) + batch - 1) / batch; visits < minVisits {
				t.Fatalf("count=%d batch=%d: %d visits, want at least %d", count, batch, visits, minVisits)
			}
			sorted := append([]string(nil), got...)
			sort.Strings(sorted)
			if strings.Join(sorted, ",") != strings.Join(want, ",") {
				t.Fatalf("count=%d batch=%d: got %d names, want %d", count, batch, len(got), len(want))
			}
		}
	}
}

// Replaces TestRegistryNamesProductionScanCap (16384 entries pass, 16385
// raise): with the production batch size, 16384, 16385 and 49152 entries
// (three times the old cap) are all streamed completely and none raises.
func TestRegistryBatchesBeyondOldScanCap(t *testing.T) {
	if registryBatchSize != 256 {
		t.Fatalf("registryBatchSize = %d, want 256", registryBatchSize)
	}
	const oldScanCap = 16384
	dir := t.TempDir()
	want := fillRegistry(t, dir, 100000, oldScanCap, "{}")
	check := func(label string, want []string) {
		got, _ := collectBatches(t, dir, registryBatchSize)
		sort.Strings(got)
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("%s: streamed %d names, want %d", label, len(got), len(want))
		}
	}
	check("at the old cap", want)
	extra := filepath.Join(dir, "extra.json")
	if err := os.WriteFile(extra, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	want = append(want, "extra.json")
	sort.Strings(want)
	check("one past the old cap", want)
	want = append(want, fillRegistry(t, dir, 200000, 3*oldScanCap-oldScanCap-1, "{}")...)
	sort.Strings(want)
	check("three times the old cap", want)
}

// An unreadable or missing registry is empty, as globNames reads it, for the
// new and the original peerRecords.
func TestPeerRecordsUnreadableRegistry(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("root reads a mode-000 directory")
	}
	for _, tc := range []string{"unreadable", "missing", "file"} {
		t.Run(tc, func(t *testing.T) {
			root := t.TempDir()
			registry := filepath.Join(root, "sessions")
			switch tc {
			case "unreadable":
				if err := os.Mkdir(registry, 0o700); err != nil {
					t.Fatal(err)
				}
				fillRegistry(t, registry, 1000, 600, "{}")
				if err := os.Chmod(registry, 0o000); err != nil {
					t.Fatal(err)
				}
				defer os.Chmod(registry, 0o700)
			case "file":
				if err := os.WriteFile(registry, nil, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			proc := &registryProc{root: root, alive: map[int64]bool{1000: true}}
			r := &runner{ctx: context.Background(), proc: proc, uid: int64(os.Getuid()), home: "/nonexistent-home"}
			got, err := r.peerRecords(recipientPID, "claude", "")
			old, oldErr := r.oldPeerRecords(recipientPID, "")
			if err != nil || got != nil || oldErr != nil || old != nil {
				t.Fatalf("new=(%v, %v) original=(%v, %v); want both (nil, nil)", workerPIDs(got), err, workerPIDs(old), oldErr)
			}
		})
	}
}

// Replaces TestPeerRecordsProductionLimits (1025 live candidates or a
// 16385th entry raised): the same four populations, and populations far past
// both old limits, all pass with no record accepted (every live candidate is
// "{}", parsed and refused) and no error.
func TestPeerRecordsBeyondOldLimits(t *testing.T) {
	const deadFirst = 500000
	const oldScanCap = 16384
	for _, tc := range []struct {
		name       string
		live, dead int
	}{
		{"1024 live, dead to the old cap", 1024, oldScanCap - 1024},
		{"1025 live", 1025, 0},
		{"1024 live, one entry past the old cap", 1024, oldScanCap - 1024 + 1},
		{"4 live, 16000 dead", 4, 16000},
		{"4096 live, 3x the old cap dead", 4096, 3 * oldScanCap},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			registry := filepath.Join(root, "sessions")
			if err := os.Mkdir(registry, 0o700); err != nil {
				t.Fatal(err)
			}
			proc := &registryProc{root: root, alive: map[int64]bool{}}
			for i := 0; i < tc.live; i++ {
				worker := firstWorker + int64(i)
				proc.alive[worker] = true
				if err := os.WriteFile(filepath.Join(registry, fmt.Sprintf("%d.json", worker)), []byte("{}"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			for i := 0; i < tc.dead; i++ {
				name := filepath.Join(registry, fmt.Sprintf("%d.json", deadFirst+i))
				if err := os.WriteFile(name, []byte("{}"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			r := &runner{ctx: context.Background(), proc: proc, uid: int64(os.Getuid()), home: "/nonexistent-home"}
			got, err := r.peerRecords(recipientPID, "claude", "")
			if err != nil || len(got) != 0 {
				t.Fatalf("got %d records, err=%v; want none and no error", len(got), err)
			}
		})
	}
}

// acceptedRegistry writes count valid, live, socket-backed records (each its
// own private socket, kept on disk without a listener) and dead records
// into root/sessions. The first deadValid dead records are complete — key
// and socket included — and would be accepted if their worker were alive.
func acceptedRegistry(t *testing.T, root string, count, deadValid, deadPlain int) (*registryProc, []int64) {
	t.Helper()
	registry := filepath.Join(root, "sessions")
	sockets := filepath.Join(root, "s")
	for _, dir := range []string{registry, sockets} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	proc := &registryProc{root: root, alive: map[int64]bool{}}
	write := func(worker int64) {
		address := filepath.Join(sockets, fmt.Sprint(worker))
		listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: address, Net: "unix"})
		if err != nil {
			t.Fatal(err)
		}
		listener.SetUnlinkOnClose(false)
		listener.Close()
		if err := os.Chmod(address, 0o600); err != nil {
			t.Fatal(err)
		}
		record := fmt.Sprintf(`{"pid":%d,"procStart":"start-%d","sessionId":"%08d-0000-4000-8000-000000000000","messagingSocketPath":%q}`,
			worker, worker, worker%100000000, address)
		if err := os.WriteFile(filepath.Join(registry, fmt.Sprintf("%d.json", worker)), []byte(record), 0o600); err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256([]byte(address))
		key := filepath.Join(registry, fmt.Sprintf("%d.%s.key", worker, hex.EncodeToString(sum[:])))
		if err := os.WriteFile(key, []byte(`{"peerToken":"0123456789abcdef0123456789abcdef"}`), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	var live []int64
	for i := 0; i < count; i++ {
		worker := firstWorker + int64(i)
		proc.alive[worker] = true
		write(worker)
		live = append(live, worker)
	}
	for i := 0; i < deadValid; i++ {
		write(int64(300000 + i))
	}
	for i := 0; i < deadPlain; i++ {
		if err := os.WriteFile(filepath.Join(registry, fmt.Sprintf("%d.json", 500000+i)), []byte("{}"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return proc, live
}

func sortedPIDs(records []peerRecord) []int64 {
	pids := workerPIDs(records)
	sort.Slice(pids, func(i, j int) bool { return pids[i] < pids[j] })
	return pids
}

// Stale-population completeness past both old limits: 1100 valid live peers
// (past the 1024 live-candidate limit) among 64 complete dead records and
// 40000 plain dead records (past the 16384-entry scan cap) are all accepted,
// exactly, with no dead one, in directory order; the original refuses this
// registry outright. 1100 live records span at least nine 256-entry
// batches, which the test asserts, so stopping after any batch loses
// records.
func TestPeerRecordsCompletenessBeyondOldLimits(t *testing.T) {
	base, err := os.MkdirTemp("", "pc")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(base)
	proc, live := acceptedRegistry(t, base, 1100, 64, 40000)
	registry := filepath.Join(base, "sessions")
	ordered := directoryJSONNames(t, registry)
	var wantOrder []int64
	lastLive := -1
	for i, name := range ordered {
		if worker, ok := registryRecordPID(name); ok && proc.alive[worker] {
			wantOrder = append(wantOrder, worker)
			lastLive = i
		}
	}
	if lastLive < 8*registryBatchSize {
		t.Fatalf("fixture: last live record at directory position %d, not past the eighth batch", lastLive)
	}
	r := &runner{ctx: context.Background(), proc: proc, uid: int64(os.Getuid()), home: "/nonexistent-home"}
	got, err := r.peerRecords(recipientPID, "claude", "")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(sortedPIDs(got), live) {
		t.Fatalf("accepted %d records, want the %d live ones", len(got), len(live))
	}
	if !reflect.DeepEqual(workerPIDs(got), wantOrder) {
		t.Fatalf("accepted records out of directory order")
	}
	if _, oldErr := r.oldPeerRecords(recipientPID, ""); !isLimitError(oldErr) {
		t.Fatalf("original peerRecords: %v; want its limit error on this registry", oldErr)
	}
	// The session fence still selects exactly one record.
	one, err := r.peerRecords(recipientPID, "claude", fmt.Sprintf("%08d-0000-4000-8000-000000000000", live[1000]))
	if err != nil || !reflect.DeepEqual(workerPIDs(one), []int64{live[1000]}) {
		t.Fatalf("session fence: %v, %v", workerPIDs(one), err)
	}
	// A codex recipient still reads none of it.
	proc.reads = 0
	if none, err := r.peerRecords(recipientPID, "codex", ""); none != nil || err != nil || proc.reads != 0 {
		t.Fatalf("codex: %v, %v, reads=%d", workerPIDs(none), err, proc.reads)
	}
}

// Stale filenames are not accumulated: while each of 8 live records is
// parsed (at its socket identity check), the heap holds less than 1 MiB
// more than before peerRecords began, though the registry lists 60000 dead
// names (about 3 MiB as Go strings plus the slice). A version that lists
// the whole directory before parsing holds every name at each check.
func TestPeerRecordsDoesNotRetainStaleNames(t *testing.T) {
	base, err := os.MkdirTemp("", "ph")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(base)
	proc, live := acceptedRegistry(t, base, 8, 0, 60000)
	var stats runtime.MemStats
	var peak uint64
	checks := 0
	r := &runner{ctx: context.Background(), proc: proc, uid: int64(os.Getuid()), home: "/nonexistent-home",
		host: Host{beforeSocketCheck: func(string) {
			checks++
			runtime.GC()
			runtime.ReadMemStats(&stats)
			if stats.HeapAlloc > peak {
				peak = stats.HeapAlloc
			}
		}}}
	runtime.GC()
	runtime.ReadMemStats(&stats)
	baseline := stats.HeapAlloc
	got, err := r.peerRecords(recipientPID, "claude", "")
	if err != nil || !reflect.DeepEqual(sortedPIDs(got), live) {
		t.Fatalf("accepted %v, err=%v; want %v", workerPIDs(got), err, live)
	}
	if checks != len(live) {
		t.Fatalf("%d socket checks, want %d", checks, len(live))
	}
	const limit = 1 << 20
	growth := int64(peak) - int64(baseline)
	t.Logf("heap growth at the socket checks: %d bytes (baseline %d)", growth, baseline)
	if growth >= limit {
		t.Fatalf("heap grew %d bytes while parsing records; stale names retained?", growth)
	}
}
