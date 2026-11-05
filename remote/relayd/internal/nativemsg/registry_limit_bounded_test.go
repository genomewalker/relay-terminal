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
	"strings"
	"testing"
)

// Exhaustive bounded check of the real peerRecords against the Claude
// session registry: every registry of 0..4 records, each record live, dead,
// unreadable or relayProxy, crossed with recipient provider claude and codex
// and with four registry settings (dead padding x batch size). Named
// properties are checked after every case:
//
//	P1 a codex recipient never touches the Claude registry: (nil, nil) and
//	   no process inventory or environment read (which resolving the
//	   registry needs).
//	P2 dead records, including the padding, are never returned.
//	P3 no population limit: peerRecords never raises, whatever the number
//	   of dead padding records or live records, and with batches of 1 entry
//	   (every record and key in its own batch) as with the production 256.
//	   (Superseded P3: "the live-candidate limit and the directory scan cap
//	   still raise, exactly when exceeded" — the population policy without
//	   limits replaced it: the registry is streamed in batches, so no
//	   population count bounds memory.)
//	P4 for claude, the accepted set equals the accepted set of the original
//	   peerRecords (oldPeerRecords below, copied verbatim from orig/)
//	   whenever the original did not raise, and equals the live records
//	   in every case, including those where the original raised by its
//	   1024-name limit (padding 1025).
//
// Records are named <pid>.json as Claude names them (the domain of P4); a
// non-numeric name stays a candidate and takes the original path.

type recordState int

const (
	stateLive recordState = iota
	stateDead
	stateUnreadable
	stateRelayProxy
	stateCount
)

var stateNames = []string{"live", "dead", "unreadable", "relayProxy"}

const (
	recipientPID = int64(100)
	firstWorker  = int64(201)
)

// registryProc is a processSource with one recipient and the given live
// workers below it; it counts every inventory and environment read.
type registryProc struct {
	root  string
	alive map[int64]bool
	reads int
}

func (p *registryProc) linux() bool { return false }
func (p *registryProc) identity(pid int64) (string, error) {
	if pid == recipientPID || p.alive[pid] {
		return fmt.Sprintf("1:start-%d", pid), nil
	}
	return "", unbound("Process owner changed.")
}
func (p *registryProc) epoch(pid int64) (float64, error) { return 0, nil }
func (p *registryProc) processes() ([]psRow, error) {
	p.reads++
	uid := int64(os.Getuid())
	rows := []psRow{{pid: recipientPID, ppid: 1, uid: uid, comm: "claude"}}
	for pid := range p.alive {
		rows = append(rows, psRow{pid: pid, ppid: recipientPID, uid: uid, comm: "claude"})
	}
	return rows, nil
}
func (p *registryProc) executable(pid int64) (string, error)  { return "", unbound("no executable") }
func (p *registryProc) openPaths(pid int64) ([]string, error) { return nil, nil }
func (p *registryProc) environment(pid int64) ([][]byte, error) {
	p.reads++
	return [][]byte{[]byte("CLAUDE_CONFIG_DIR=" + p.root)}, nil
}

// oldPeerRecords is orig/ peerRecords (discover.go:84-114) verbatim; only
// its name changed. It is the P4 oracle.
func (r *runner) oldPeerRecords(pid int64, session string) ([]peerRecord, error) {
	processes, err := r.inventory()
	if err != nil {
		return nil, err
	}
	registry, err := r.claudeSessions(pid)
	if err != nil {
		return nil, err
	}
	names, err := globNames(registry, "*.json", false)
	if err != nil {
		return nil, err
	}
	if len(names) > 1024 {
		return nil, valueError("Native session registry exceeds limit")
	}
	var records []peerRecord
	for _, name := range names {
		record, err := r.peerRecord(pathJoin(registry, name), registry, pid, session, processes)
		if err != nil {
			if caught(err, classOS, classValue, classKey, classUnbound) {
				continue
			}
			return nil, err
		}
		if record != nil {
			records = append(records, *record)
		}
	}
	return records, nil
}

func workerPIDs(records []peerRecord) []int64 {
	result := []int64{}
	for _, record := range records {
		worker, _ := pyGet(record.row, "pid", nil)
		n, _ := pidOf(worker)
		result = append(result, n)
	}
	return result
}

// registrySetting is one registry configuration of the bounded check: pad
// dead <pid>.json records already in the directory, and the batch size.
type registrySetting struct{ pad, batch int }

// padPID is the first pid of the padding records; none is ever alive.
const padPID = 900000

func TestPeerRecordsRegistryBoundedExhaustive(t *testing.T) {
	// Short root: macOS limits Unix socket paths to 104 bytes.
	base, err := os.MkdirTemp("", "pr")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(base)
	sockets := filepath.Join(base, "s")
	if err := os.Mkdir(sockets, 0o700); err != nil {
		t.Fatal(err)
	}
	const maxRecords = 4
	socketPath := map[int64]string{}
	for i := 0; i < maxRecords; i++ {
		worker := firstWorker + int64(i)
		path := filepath.Join(sockets, fmt.Sprint(worker))
		listener, err := net.Listen("unix", path)
		if err != nil {
			t.Fatal(err)
		}
		defer listener.Close()
		if err := os.Chmod(path, 0o600); err != nil {
			t.Fatal(err)
		}
		socketPath[worker] = path
	}
	savedBatch := registryBatchSize
	defer func() { registryBatchSize = savedBatch }()
	settings := []registrySetting{{0, 1}, {0, savedBatch}, {1025, 1}, {1025, savedBatch}}

	explored, compared, oldRaised, multiBatch := 0, 0, 0, 0
	for si, setting := range settings {
		// One registry per setting holds the padding; each case adds its
		// records and removes them afterwards.
		root := filepath.Join(base, fmt.Sprintf("r%d", si))
		registry := filepath.Join(root, "sessions")
		if err := os.MkdirAll(registry, 0o700); err != nil {
			t.Fatal(err)
		}
		for i := 0; i < setting.pad; i++ {
			name := filepath.Join(registry, fmt.Sprintf("%d.json", padPID+i))
			if err := os.WriteFile(name, []byte(`{"pid":`+fmt.Sprint(padPID+i)+`}`), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		for n := 0; n <= maxRecords; n++ {
			total := 1
			for i := 0; i < n; i++ {
				total *= int(stateCount)
			}
			for code := 0; code < total; code++ {
				states := make([]recordState, n)
				for i, c := 0, code; i < n; i, c = i+1, c/int(stateCount) {
					states[i] = recordState(c % int(stateCount))
				}
				for _, provider := range []string{"claude", "codex"} {
					explored++
					label := fmt.Sprintf("n=%d states=%v provider=%s setting=%v", n, stateLabels(states), provider, setting)
					proc, written := writeRegistry(t, root, states, socketPath)
					r := &runner{ctx: context.Background(), proc: proc, uid: int64(os.Getuid()), home: "/nonexistent-home"}

					registryBatchSize = setting.batch
					got, gotErr := r.peerRecords(recipientPID, provider, "")
					newReads := proc.reads
					registryBatchSize = savedBatch

					live, dead := []int64{}, map[int64]bool{}
					for i, state := range states {
						worker := firstWorker + int64(i)
						if state == stateDead {
							dead[worker] = true
						}
						if state == stateLive {
							live = append(live, worker)
						}
					}

					// P1
					if provider == "codex" {
						if gotErr != nil || got != nil || newReads != 0 {
							t.Fatalf("P1 %s: codex recipient read the Claude registry: records=%v err=%v reads=%d", label, workerPIDs(got), gotErr, newReads)
						}
						removeAll(t, written)
						continue
					}
					// P2
					for _, worker := range workerPIDs(got) {
						if dead[worker] || worker >= padPID {
							t.Fatalf("P2 %s: dead record %d returned", label, worker)
						}
					}
					// P3
					if gotErr != nil {
						t.Fatalf("P3 %s: raised with %d records and %d padding: %v", label, n, setting.pad, gotErr)
					}
					if setting.batch < 2*n+setting.pad {
						multiBatch++
					}
					// P4
					proc.reads = 0
					old, oldErr := r.oldPeerRecords(recipientPID, "")
					if oldErr == nil {
						compared++
						if !reflect.DeepEqual(workerPIDs(got), workerPIDs(old)) {
							t.Fatalf("P4 %s: accepted %v, original accepted %v", label, workerPIDs(got), workerPIDs(old))
						}
					} else if strings.Contains(oldErr.Error(), "Native session registry exceeds limit") {
						oldRaised++
					} else {
						t.Fatalf("P4 %s: original raised %v", label, oldErr)
					}
					if !reflect.DeepEqual(workerPIDs(got), live) {
						t.Fatalf("P4 %s: accepted %v, want the live records %v", label, workerPIDs(got), live)
					}
					removeAll(t, written)
				}
			}
		}
		if left, err := os.ReadDir(registry); err != nil || len(left) != setting.pad {
			t.Fatalf("setting %v: %d entries left after the cases, err=%v", setting, len(left), err)
		}
	}
	t.Logf("bound: 0..%d records x %d states x 2 providers x %d registry settings %v; explored %d cases; multi-batch cases %d, P4 comparisons with the original %d, cases where the original raised by its limit %d",
		maxRecords, stateCount, len(settings), settings, explored, multiBatch, compared, oldRaised)
	if explored != 341*2*len(settings) {
		t.Fatalf("explored %d cases", explored)
	}
	// Every claude case is either compared with the original or is one the
	// original refused (padding 1025 exceeds its 1024-name limit).
	if compared != 341*2 || oldRaised != 341*2 || multiBatch == 0 {
		t.Fatalf("a property was never exercised: compared=%d oldRaised=%d multiBatch=%d", compared, oldRaised, multiBatch)
	}
}

func removeAll(t *testing.T, paths []string) {
	t.Helper()
	for _, path := range paths {
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
	}
}

func stateLabels(states []recordState) []string {
	result := []string{}
	for _, s := range states {
		result = append(result, stateNames[s])
	}
	return result
}

// writeRegistry writes into root/sessions one <pid>.json and one
// <pid>.<sha256(socket)>.key per record, as Claude does, and returns the
// paths it wrote.
func writeRegistry(t *testing.T, root string, states []recordState, socketPath map[int64]string) (*registryProc, []string) {
	t.Helper()
	registry := filepath.Join(root, "sessions")
	if err := os.MkdirAll(registry, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	proc := &registryProc{root: root, alive: map[int64]bool{}}
	var written []string
	for i, state := range states {
		worker := firstWorker + int64(i)
		if state != stateDead {
			proc.alive[worker] = true
		}
		address := socketPath[worker]
		proxy := ""
		if state == stateRelayProxy {
			proxy = `,"relayProxy":true`
		}
		record := fmt.Sprintf(`{"pid":%d,"procStart":"start-%d","sessionId":"%08d-0000-4000-8000-000000000000","messagingSocketPath":%q%s}`,
			worker, worker, worker, address, proxy)
		name := filepath.Join(registry, fmt.Sprintf("%d.json", worker))
		if err := os.WriteFile(name, []byte(record), 0o600); err != nil {
			t.Fatal(err)
		}
		written = append(written, name)
		if state == stateUnreadable {
			if err := os.Chmod(name, 0o000); err != nil {
				t.Fatal(err)
			}
		}
		sum := sha256.Sum256([]byte(address))
		key := filepath.Join(registry, fmt.Sprintf("%d.%s.key", worker, hex.EncodeToString(sum[:])))
		if err := os.WriteFile(key, []byte(`{"peerToken":"0123456789abcdef0123456789abcdef"}`), 0o600); err != nil {
			t.Fatal(err)
		}
		written = append(written, key)
	}
	return proc, written
}
