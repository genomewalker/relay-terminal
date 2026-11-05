package nativechat

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestResumeRequiresGoneOwnersAccountAndSettledReceipts(t *testing.T) {
	root := t.TempDir()
	source := Identity{"old-pane", "old-instance", "codex"}
	account := filepath.Join(root, "account")
	dir, e := instanceDirectory(root, source)
	if e != nil {
		t.Fatal(e)
	}
	if e = privateDirectory(dir); e != nil {
		t.Fatal(e)
	}
	descriptor := Descriptor{Version: 1, Identity: source, PID: 11, ProcessStart: "old-worker", ProviderPID: 12, ProviderStart: "old-provider"}
	if e = atomicJSON(filepath.Join(dir, "descriptor.json"), descriptor); e != nil {
		t.Fatal(e)
	}
	snapshot := Snapshot{Version: 1, Identity: source, SessionID: "saved-session", CWD: root, Model: "saved-model", AccountRoot: account}
	if e = atomicJSON(filepath.Join(dir, "snapshot.json"), snapshot); e != nil {
		t.Fatal(e)
	}
	journal := filepath.Join(dir, "actions.jsonl")
	if e = os.WriteFile(journal, nil, 0600); e != nil {
		t.Fatal(e)
	}
	gone := map[int]bool{11: true, 12: false}
	kernel := Kernel{ProcessGone: func(pid int, start string) (bool, error) { return gone[pid], nil }}
	if _, e = ReadResumePlan(root, source, account, kernel); e == nil {
		t.Fatal("live source provider admitted resume")
	}
	gone[12] = true
	gone[11] = false
	if _, e = ReadResumePlan(root, source, account, kernel); e == nil {
		t.Fatal("live source worker admitted resume")
	}
	gone[11] = true
	if _, e = ReadResumePlan(root, source, account+"-other", kernel); e == nil {
		t.Fatal("resume crossed account")
	}
	writeReceipt := func(state string) {
		t.Helper()
		data := append(wire(Receipt{ID: "action", Digest: "digest", State: state}), 10)
		if e = os.WriteFile(journal, data, 0600); e != nil {
			t.Fatal(e)
		}
	}
	writeReceipt("claimed")
	if _, e = ReadResumePlan(root, source, account, kernel); e == nil {
		t.Fatal("unresolved action admitted resume")
	}
	writeReceipt("uncertain")
	if _, e = ReadResumePlan(root, source, account, kernel); e == nil {
		t.Fatal("uncertain action admitted resume")
	}
	writeReceipt("sent")
	plan, e := ReadResumePlan(root, source, account, kernel)
	if e != nil || plan.Session != "saved-session" || plan.CWD != root || plan.Model != "saved-model" || plan.AccountRoot != account {
		t.Fatalf("valid saved resume %v %+v", e, plan)
	}
	kernel.ProcessGone = func(int, string) (bool, error) { return false, errors.New("unobservable") }
	if _, e = ReadResumePlan(root, source, account, kernel); e == nil {
		t.Fatal("unknown owner observation admitted resume")
	}
}
func TestSessionLeaseExcludesSecondOwner(t *testing.T) {
	root := t.TempDir()
	account := filepath.Join(root, "account")
	first, e := sessionLease(root, "codex", account, "session")
	if e != nil {
		t.Fatal(e)
	}
	if second, e := sessionLease(root, "codex", account, "session"); e == nil {
		_ = second.Close()
		t.Fatal("second session owner admitted")
	}
	_ = first.Close()
	second, e := sessionLease(root, "codex", account, "session")
	if e != nil {
		t.Fatal("released session cannot be explicitly resumed", e)
	}
	_ = second.Close()
}
func TestReceiptJournalRequiresCompleteLines(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "actions.jsonl")
	data := wire(Receipt{ID: "action", Digest: "digest", State: "sent"})
	if e := os.WriteFile(path, data, 0600); e != nil {
		t.Fatal(e)
	}
	if e := settledReceiptFile(path); e == nil {
		t.Fatal("truncated receipt journal accepted")
	}
	if e := os.WriteFile(path, append(data, 10), 0600); e != nil {
		t.Fatal(e)
	}
	if e := settledReceiptFile(path); e != nil {
		t.Fatal(e)
	}
}
func FuzzSettledReceipts(f *testing.F) {
	f.Add([]byte(wire(Receipt{ID: "action", Digest: "digest", State: "sent"})))
	for _, state := range []string{"claimed", "sent", "uncertain", "rejected"} {
		f.Add([]byte(append(wire(Receipt{ID: "action", Digest: "digest", State: state}), 10)))
	}
	f.Add([]byte("{"))
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 65536 {
			return
		}
		path := filepath.Join(t.TempDir(), "actions.jsonl")
		if e := os.WriteFile(path, data, 0600); e != nil {
			t.Fatal(e)
		}
		if settledReceiptFile(path) != nil {
			return
		}
		if len(data) > 0 && data[len(data)-1] != 10 {
			t.Fatal("partial journal accepted")
		}
		// Accepted individual records retain their meaning on JSON round trip.
		records := splitReceiptLines(data)
		for _, record := range records {
			var r Receipt
			if json.Unmarshal(record, &r) != nil {
				t.Fatal("invalid accepted receipt")
			}
			var again Receipt
			if json.Unmarshal(wire(r), &again) != nil || r != again {
				t.Fatal("receipt round trip changed")
			}
		}
	})
}
func splitReceiptLines(data []byte) [][]byte {
	var lines [][]byte
	start := 0
	for i, b := range data {
		if b == 10 {
			lines = append(lines, data[start:i])
			start = i + 1
		}
	}
	return lines
}
