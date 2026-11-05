package daemon

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// Test listeners run under /bin/sh with the listener's positional contract.
// Each prints a ready frame once the test supplies its kernel start identity.
const (
	drainingListener = `read start
printf '{"type":"ready","pid":%s,"start":"%s","drain":1}\n' "$$" "$start"
trap 'exit 0' TERM
while :; do sleep 0.05; done`
	legacyListener = `read start
printf '{"type":"ready","pid":%s,"start":"%s"}\n' "$$" "$start"
trap 'exit 0' TERM
while :; do sleep 0.05; done`
	failingListener = `read start
printf '{"type":"ready","pid":%s,"start":"%s","drain":1}\n' "$$" "$start"
trap 'exit 3' TERM
while :; do sleep 0.05; done`
	crashingListener = `read start
printf '{"type":"ready","pid":%s,"start":"%s","drain":1}\n' "$$" "$start"
trap 'kill -KILL $$' TERM
while :; do sleep 0.05; done`
	stubbornListener = `read start
printf '{"type":"ready","pid":%s,"start":"%s","drain":1}\n' "$$" "$start"
trap '' TERM
while :; do sleep 0.05; done`
)

type listenerFixture struct {
	t        *testing.T
	stateDir string
	owner    peerListenerOwner
	registry string
}

func newListenerFixture(t *testing.T) *listenerFixture {
	t.Helper()
	start, err := processStartIdentity(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	f := &listenerFixture{t: t, stateDir: t.TempDir(), registry: t.TempDir(),
		owner: peerListenerOwner{PID: os.Getpid(), Start: start, Session: "conversation-1"}}
	f.writeOwner(f.owner.PID, f.owner.Session, f.owner.Start)
	previous := peerListenerOwnerRegistry
	peerListenerOwnerRegistry = func() (string, error) { return f.registry, nil }
	t.Cleanup(func() { peerListenerOwnerRegistry = previous })
	return f
}

func (f *listenerFixture) writeOwner(pid int, session, start string) {
	data, _ := json.Marshal(map[string]any{"pid": pid, "sessionId": session, "procStart": start})
	if err := os.WriteFile(filepath.Join(f.registry, strconv.Itoa(pid)+".json"), data, 0600); err != nil {
		f.t.Fatal(err)
	}
}

func (f *listenerFixture) server() *Server { return &Server{stateDir: f.stateDir} }

func (f *listenerFixture) spec(route, script string) *peerListenerSpec {
	return &peerListenerSpec{Interpreter: "/bin/sh", Script: script, Route: route,
		OwnerPID: f.owner.PID, OwnerStart: f.owner.Start, OwnerSession: f.owner.Session}
}

func (f *listenerFixture) launch(s *Server, id, route, script string) (hostJobRecord, *hostJob) {
	f.t.Helper()
	result, err := s.startHostJob(hostRequest{JobID: id, Kind: hostJobKindPeerListener, KeepStdin: true, Listener: f.spec(route, script)})
	if err != nil {
		f.t.Fatal(err)
	}
	value, _ := s.hostJobs.Load(id)
	job := value.(*hostJob)
	record := result.(hostJobRecord)
	if record.State == "running" {
		f.ready(job)
	}
	return record, job
}

// Supply the start identity, wait for the ready frame, and reap at cleanup.
func (f *listenerFixture) ready(job *hostJob) {
	f.t.Helper()
	f.t.Cleanup(func() { killHostJob(job) })
	job.mu.Lock()
	pid, recorded := job.record.PID, job.record.ProcessStart
	job.mu.Unlock()
	start, err := processStartIdentity(pid)
	if err != nil || start != recorded {
		f.t.Fatalf("start identity %q/%q: %v", start, recorded, err)
	}
	if _, err := job.writeInput(hostRequest{InputSequence: 1, Stdin: []byte(start + "\n")}); err != nil {
		f.t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		data, _ := os.ReadFile(filepath.Join(job.directory, "stdout"))
		if strings.Contains(string(data), "\n") {
			return
		}
		if time.Now().After(deadline) {
			f.t.Fatal("listener did not publish its ready frame")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func killHostJob(job *hostJob) {
	job.mu.Lock()
	if job.record.State == "running" && job.cmd != nil {
		syscall.Kill(-job.cmd.Process.Pid, syscall.SIGKILL)
	}
	job.mu.Unlock()
	waitHostJobExited(job, time.Now().Add(5*time.Second))
}

func hostJobState(job *hostJob) string {
	job.mu.Lock()
	defer job.mu.Unlock()
	return job.record.State
}

func (f *listenerFixture) entry(s *Server, route string) (peerListenerEntry, error) {
	return s.readPeerListenerFile(s.peerListenerPath(route))
}

func (f *listenerFixture) servingListeners(s *Server, route string) []string {
	ids := []string{}
	s.hostJobs.Range(func(key, value any) bool {
		job := value.(*hostJob)
		job.mu.Lock()
		if job.listener != nil && job.listener.Route == route && job.record.State == "running" {
			ids = append(ids, key.(string))
		}
		job.mu.Unlock()
		return true
	})
	return ids
}

func TestPeerListenerRegistryIsPrivateAndRefusesUnsafeEntries(t *testing.T) {
	f := newListenerFixture(t)
	s := f.server()
	spec := f.spec("route-a", drainingListener)
	if err := s.recordPeerListener(spec, "/tmp", "job-a"); err != nil {
		t.Fatal(err)
	}
	path := s.peerListenerPath("route-a")
	info, err := os.Lstat(path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("entry mode %v: %v", info.Mode(), err)
	}
	if dir, _ := os.Lstat(s.peerListenerDir()); dir.Mode().Perm() != 0o700 {
		t.Fatalf("registry directory mode %v", dir.Mode())
	}
	entry, err := f.entry(s, "route-a")
	if err != nil || entry.Kind != hostJobKindPeerListener || entry.JobID != "job-a" || entry.State != "active" ||
		entry.Owner != f.owner || entry.Mailbox != peerListenerMailbox("route-a") || entry.Launch.Cwd != "/tmp" {
		t.Fatalf("entry = %+v, %v", entry, err)
	}
	raw, _ := os.ReadFile(path)
	for _, secret := range []string{"token", "secret", "env", "peerToken"} {
		if strings.Contains(strings.ToLower(string(raw)), strings.ToLower(secret)) {
			t.Fatalf("registry entry contains %q", secret)
		}
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := f.entry(s, "route-a"); err == nil {
		t.Fatal("group-readable entry accepted")
	}
	os.Chmod(path, 0o600)
	target := filepath.Join(t.TempDir(), "elsewhere.json")
	os.Rename(path, target)
	if err := os.Symlink(target, path); err != nil {
		t.Fatal(err)
	}
	if _, err := f.entry(s, "route-a"); err == nil {
		t.Fatal("symlinked entry accepted")
	}
	// A write replaces the planted link itself and never writes through it.
	if err := s.recordPeerListener(spec, "", "job-b"); err != nil {
		t.Fatal(err)
	}
	if info, _ := os.Lstat(path); info.Mode()&os.ModeSymlink != 0 {
		t.Fatal("write followed a symlink")
	}
	if prior, _ := os.ReadFile(target); strings.Contains(string(prior), "job-b") {
		t.Fatal("write went through the symlink")
	}
	// An entry must describe the route its file name is derived from.
	os.Rename(path, s.peerListenerPath("route-b"))
	if _, err := s.readPeerListenerFile(s.peerListenerPath("route-b")); err == nil {
		t.Fatal("misfiled entry accepted")
	}
}

func TestHostUpgradeSuspendsVerifiedListenerAndNewSupervisorResumesIt(t *testing.T) {
	f := newListenerFixture(t)
	old := f.server()
	_, job := f.launch(old, "job-listener", "route-a", drainingListener)
	if err := old.prepareHostUpgrade(); err != nil {
		t.Fatalf("verified listener blocked the upgrade: %v", err)
	}
	if state := hostJobState(job); state != "exited" {
		t.Fatalf("listener was not drained before handoff: %s", state)
	}
	if entry, err := f.entry(old, "route-a"); err != nil || entry.State != "suspended" || entry.JobID != "job-listener" {
		t.Fatalf("drained listener registry = %+v, %v", entry, err)
	}
	// The replacement supervisor knows only the durable state.
	next := f.server()
	if resumed := next.resumePeerListeners(); resumed != 1 {
		t.Fatalf("resumed %d listeners", resumed)
	}
	serving := f.servingListeners(next, "route-a")
	if len(serving) != 1 || serving[0] == "job-listener" {
		t.Fatalf("serving listeners = %v", serving)
	}
	value, _ := next.hostJobs.Load(serving[0])
	resumed := value.(*hostJob)
	f.ready(resumed)
	if entry, err := f.entry(next, "route-a"); err != nil || entry.State != "active" || entry.JobID != serving[0] {
		t.Fatalf("resumed registry = %+v, %v", entry, err)
	}
	if !reflectEqual(resumed.listener.argv(), f.spec("route-a", drainingListener).argv()) {
		t.Fatalf("resumed launch differs: %q", resumed.listener.argv())
	}
	// The drained job points its client at the resumed listener.
	status, err := next.hostRPC(hostRequest{RequestID: "rpc-1", Operation: "status", JobID: "job-listener"})
	if err != nil || status.(map[string]any)["job"].(hostJobRecord).Successor != serving[0] {
		t.Fatalf("drained job status = %v, %v", status, err)
	}
	// The resumed listener is itself verified and resumable again.
	if err := next.prepareHostUpgrade(); err != nil {
		t.Fatalf("resumed listener blocked a second upgrade: %v", err)
	}
}

func TestHostUpgradeAbandonedHandoffResumesInOldSupervisor(t *testing.T) {
	f := newListenerFixture(t)
	previous := hostUpgradeHandoff
	hostUpgradeHandoff = 300 * time.Millisecond
	t.Cleanup(func() { hostUpgradeHandoff = previous })
	old := f.server()
	_, job := f.launch(old, "job-listener", "route-a", drainingListener)
	if err := old.prepareHostUpgrade(); err != nil {
		t.Fatalf("verified listener blocked the upgrade: %v", err)
	}
	if state := hostJobState(job); state != "exited" {
		t.Fatalf("listener was not drained before handoff: %s", state)
	}
	// The supervisor was never replaced: when the barrier lapses it resumes
	// the drained listener itself, from the same registry entry.
	deadline := time.Now().Add(5 * time.Second)
	var serving []string
	for time.Now().Before(deadline) {
		if serving = f.servingListeners(old, "route-a"); len(serving) > 0 {
			break
		}
		time.Sleep(25 * time.Millisecond)
	}
	if len(serving) != 1 || serving[0] == "job-listener" {
		t.Fatalf("serving listeners after abandoned handoff = %v", serving)
	}
	value, _ := old.hostJobs.Load(serving[0])
	f.ready(value.(*hostJob))
	if entry, err := f.entry(old, "route-a"); err != nil || entry.State != "active" || entry.JobID != serving[0] {
		t.Fatalf("resumed registry = %+v, %v", entry, err)
	}
	status, err := old.hostRPC(hostRequest{RequestID: "rpc-1", Operation: "status", JobID: "job-listener"})
	if err != nil || status.(map[string]any)["job"].(hostJobRecord).Successor != serving[0] {
		t.Fatalf("drained job status = %v, %v", status, err)
	}
}

func TestHostUpgradeRearmedHandoffDefersAbandonedResume(t *testing.T) {
	f := newListenerFixture(t)
	s := f.server()
	f.launch(s, "job-listener", "route-a", drainingListener)
	if err := s.prepareHostUpgrade(); err != nil {
		t.Fatalf("verified listener blocked the upgrade: %v", err)
	}
	first := s.hostUpgradeUntil
	// A later preparation re-armed the barrier; the first timer must not
	// resume ahead of the handoff that now owns the listener.
	s.hostJobsMu.Lock()
	s.hostUpgradeUntil = first.Add(time.Second)
	s.hostJobsMu.Unlock()
	s.resumeAfterAbandonedUpgrade(first)
	if serving := f.servingListeners(s, "route-a"); len(serving) != 0 {
		t.Fatalf("stale handoff timer resumed %v", serving)
	}
	if entry, err := f.entry(s, "route-a"); err != nil || entry.State != "suspended" {
		t.Fatalf("registry = %+v, %v", entry, err)
	}
	s.resumeAfterAbandonedUpgrade(s.hostUpgradeUntil)
	if serving := f.servingListeners(s, "route-a"); len(serving) != 1 {
		t.Fatalf("current handoff timer resumed %v", serving)
	}
}

func TestHostUpgradeRepeatedPreparationStillResumesAbandonedListeners(t *testing.T) {
	f := newListenerFixture(t)
	previous := hostUpgradeHandoff
	hostUpgradeHandoff = 300 * time.Millisecond
	t.Cleanup(func() { hostUpgradeHandoff = previous })
	s := f.server()
	f.launch(s, "job-listener", "route-a", drainingListener)
	if err := s.prepareHostUpgrade(); err != nil {
		t.Fatalf("verified listener blocked the upgrade: %v", err)
	}
	// The operator retries before the first barrier lapses; this preparation
	// drains nothing, so its timer must still resume the earlier drain.
	time.Sleep(100 * time.Millisecond)
	if err := s.prepareHostUpgrade(); err != nil {
		t.Fatalf("repeated preparation: %v", err)
	}
	deadline := time.Now().Add(5 * time.Second)
	var serving []string
	for time.Now().Before(deadline) {
		if serving = f.servingListeners(s, "route-a"); len(serving) > 0 {
			break
		}
		time.Sleep(25 * time.Millisecond)
	}
	if len(serving) != 1 || serving[0] == "job-listener" {
		t.Fatalf("serving listeners after repeated abandoned handoff = %v", serving)
	}
	value, _ := s.hostJobs.Load(serving[0])
	f.ready(value.(*hostJob))
}

// waitNoListener waits until no listener job serves the route.
func (f *listenerFixture) waitNoListener(s *Server, route string) {
	f.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for len(f.servingListeners(s, route)) > 0 {
		if time.Now().After(deadline) {
			f.t.Fatalf("route %s still served by %v", route, f.servingListeners(s, route))
		}
		time.Sleep(25 * time.Millisecond)
	}
}

func (f *listenerFixture) cancel(s *Server, jobID string) hostJobRecord {
	f.t.Helper()
	result, err := s.hostRPC(hostRequest{RequestID: "rpc-cancel", Operation: "cancel", JobID: jobID})
	if err != nil {
		f.t.Fatalf("cancel %s: %v", jobID, err)
	}
	return result.(hostJobRecord)
}

// The client disconnects while it still names the drained job, before it has
// adopted the resumed one: the disconnect must reach the resumed inbox.
func TestPeerListenerDisconnectBeforeAdoptionStopsResumedInbox(t *testing.T) {
	t.Run("new supervisor", func(t *testing.T) {
		f := newListenerFixture(t)
		old := f.server()
		f.launch(old, "job-listener", "route-a", drainingListener)
		if err := old.prepareHostUpgrade(); err != nil {
			t.Fatal(err)
		}
		next := f.server()
		if next.resumePeerListeners() != 1 {
			t.Fatal("listener was not resumed")
		}
		resumed := f.servingListeners(next, "route-a")
		value, _ := next.hostJobs.Load(resumed[0])
		f.ready(value.(*hostJob))
		// The drained job exists only in the ledger here.
		if record := f.cancel(next, "job-listener"); record.JobID != "job-listener" || record.Successor != resumed[0] {
			t.Fatalf("cancel answered %+v", record)
		}
		f.waitNoListener(next, "route-a")
		if _, err := f.entry(next, "route-a"); !os.IsNotExist(err) {
			t.Fatalf("disconnected route still registered: %v", err)
		}
		if again := f.server(); again.resumePeerListeners() != 0 {
			t.Fatal("a later supervisor revived the disconnected inbox")
		}
	})
	t.Run("old supervisor after abandoned handoff", func(t *testing.T) {
		f := newListenerFixture(t)
		previous := hostUpgradeHandoff
		hostUpgradeHandoff = 200 * time.Millisecond
		t.Cleanup(func() { hostUpgradeHandoff = previous })
		s := f.server()
		f.launch(s, "job-listener", "route-a", drainingListener)
		if err := s.prepareHostUpgrade(); err != nil {
			t.Fatal(err)
		}
		deadline := time.Now().Add(5 * time.Second)
		var resumed []string
		for len(resumed) == 0 && time.Now().Before(deadline) {
			time.Sleep(25 * time.Millisecond)
			resumed = f.servingListeners(s, "route-a")
		}
		if len(resumed) != 1 {
			t.Fatal("abandoned handoff did not resume the listener")
		}
		value, _ := s.hostJobs.Load(resumed[0])
		f.ready(value.(*hostJob))
		// The drained job is still in memory here, already exited.
		f.cancel(s, "job-listener")
		f.waitNoListener(s, "route-a")
		if _, err := f.entry(s, "route-a"); !os.IsNotExist(err) {
			t.Fatalf("disconnected route still registered: %v", err)
		}
		if again := f.server(); again.resumePeerListeners() != 0 {
			t.Fatal("a later supervisor revived the disconnected inbox")
		}
	})
	t.Run("old supervisor before resume", func(t *testing.T) {
		f := newListenerFixture(t)
		s := f.server()
		f.launch(s, "job-listener", "route-a", drainingListener)
		if err := s.prepareHostUpgrade(); err != nil {
			t.Fatal(err)
		}
		f.cancel(s, "job-listener")
		s.resumeAfterAbandonedUpgrade(s.hostUpgradeUntil)
		if serving := f.servingListeners(s, "route-a"); len(serving) != 0 {
			t.Fatalf("cancelled inbox was resumed: %v", serving)
		}
		if again := f.server(); again.resumePeerListeners() != 0 {
			t.Fatal("a later supervisor revived the disconnected inbox")
		}
	})
	t.Run("superseded reservation", func(t *testing.T) {
		f := newListenerFixture(t)
		s := f.server()
		f.launch(s, "job-serving", "route-a", drainingListener)
		// A resend that lost the race is reserved with the serving successor.
		record, _ := f.launch(s, "job-superseded", "route-a", drainingListener)
		if record.State != "failed" || record.Successor != "job-serving" {
			t.Fatalf("respawn record %+v", record)
		}
		f.cancel(s, "job-superseded")
		f.waitNoListener(s, "route-a")
		if _, err := f.entry(s, "route-a"); !os.IsNotExist(err) {
			t.Fatalf("disconnected route still registered: %v", err)
		}
	})
}

func TestPeerListenerCancelNeverFollowsAnotherRouteOrOwner(t *testing.T) {
	f := newListenerFixture(t)
	s := f.server()
	_, own := f.launch(s, "job-own", "route-a", drainingListener)
	_, other := f.launch(s, "job-other", "route-b", drainingListener)
	killHostJob(own)
	// A link to another route's inbox is never followed.
	own.mu.Lock()
	own.record.Successor = "job-other"
	own.save()
	own.mu.Unlock()
	f.cancel(s, "job-own")
	if hostJobState(other) != "running" {
		t.Fatal("cancel crossed into another route")
	}
	if entry, err := f.entry(s, "route-b"); err != nil || entry.JobID != "job-other" {
		t.Fatalf("other route registry = %+v, %v", entry, err)
	}
	// Nor one to the same route under a different owner incarnation.
	other.mu.Lock()
	other.record.Listener = &peerListenerBinding{Route: "route-a", Owner: peerListenerOwner{PID: f.owner.PID, Start: "changed", Session: f.owner.Session}}
	other.mu.Unlock()
	f.cancel(s, "job-own")
	if hostJobState(other) != "running" {
		t.Fatal("cancel crossed into another owner")
	}
}

func TestPeerListenerCancelRacingResumeNeverLeavesAnInbox(t *testing.T) {
	for i := 0; i < 8; i++ {
		f := newListenerFixture(t)
		s := f.server()
		f.launch(s, "job-listener", "route-a", drainingListener)
		if err := s.prepareHostUpgrade(); err != nil {
			t.Fatal(err)
		}
		var group sync.WaitGroup
		group.Add(2)
		go func() {
			defer group.Done()
			s.resumeAfterAbandonedUpgrade(s.hostUpgradeUntilSnapshot())
		}()
		go func() {
			defer group.Done()
			if _, err := s.hostRPC(hostRequest{RequestID: "rpc-cancel", Operation: "cancel", JobID: "job-listener"}); err != nil {
				t.Error(err)
			}
		}()
		group.Wait()
		s.hostJobs.Range(func(_, value any) bool {
			job := value.(*hostJob)
			t.Cleanup(func() { killHostJob(job) })
			return true
		})
		f.waitNoListener(s, "route-a")
		if _, err := f.entry(s, "route-a"); !os.IsNotExist(err) {
			t.Fatalf("iteration %d: cancelled route still registered: %v", i, err)
		}
		if again := f.server(); again.resumePeerListeners() != 0 {
			t.Fatalf("iteration %d: a later supervisor revived the cancelled inbox", i)
		}
	}
}

// Resume holds hostJobsMu from reading an entry through launching it; a
// cancel waits for that decision instead of slipping between its steps.
func TestPeerListenerCancelIsSerializedWithResume(t *testing.T) {
	f := newListenerFixture(t)
	s := f.server()
	f.launch(s, "job-listener", "route-a", drainingListener)
	if err := s.prepareHostUpgrade(); err != nil {
		t.Fatal(err)
	}
	s.hostJobsMu.Lock()
	done := make(chan struct{})
	go func() {
		defer close(done)
		s.hostRPC(hostRequest{RequestID: "rpc-cancel", Operation: "cancel", JobID: "job-listener"})
	}()
	select {
	case <-done:
		s.hostJobsMu.Unlock()
		t.Fatal("cancel ran while a resume held the registry decision")
	case <-time.After(150 * time.Millisecond):
	}
	if entry, err := f.entry(s, "route-a"); err != nil || entry.State != "suspended" {
		t.Fatalf("entry changed under the resume lock: %+v, %v", entry, err)
	}
	resumed := s.resumePeerListenersLocked()
	s.hostJobsMu.Unlock()
	<-done
	if resumed != 1 {
		t.Fatalf("resumed %d", resumed)
	}
	// The cancel then followed the new link and stopped the resumed inbox.
	s.hostJobs.Range(func(_, value any) bool {
		job := value.(*hostJob)
		t.Cleanup(func() { killHostJob(job) })
		return true
	})
	f.waitNoListener(s, "route-a")
	if _, err := f.entry(s, "route-a"); !os.IsNotExist(err) {
		t.Fatalf("cancelled route still registered: %v", err)
	}
}

// The traversal bound v3 used; cancel no longer walks successor chains, and
// chains longer than this must still be cancelled completely.
const peerListenerMaxChain = 64

// A detached client may name a drained job many handoffs ago. The disconnect
// must still reach the current incarnation, whatever the chain length.
func TestPeerListenerCancelAfterManyHandoffsReachesCurrentInbox(t *testing.T) {
	for _, test := range []struct {
		name    string
		handoff int
		running bool
	}{
		{"suspended after one past the old bound", peerListenerMaxChain + 1, false},
		{"suspended after a long chain", 4 * peerListenerMaxChain, false},
		{"running after a long chain", 4 * peerListenerMaxChain, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := newListenerFixture(t)
			s := f.server()
			spec := f.spec("route-a", drainingListener)
			binding := spec.binding()
			zero := 0
			for i := 0; i < test.handoff; i++ {
				id := fmt.Sprintf("job-chain-%04d", i)
				directory := filepath.Join(s.stateDir, "host-jobs", id)
				if err := os.MkdirAll(directory, 0700); err != nil {
					t.Fatal(err)
				}
				next := fmt.Sprintf("job-chain-%04d", i+1)
				if i+1 == test.handoff && test.running {
					next = "job-current"
				}
				record := hostJobRecord{JobID: id, Kind: hostJobKindPeerListener, Listener: binding, State: "exited", ExitCode: &zero}
				if i+1 < test.handoff || test.running {
					record.Successor = next
				}
				job := &hostJob{directory: directory, record: record}
				if err := job.save(); err != nil {
					t.Fatal(err)
				}
			}
			var current *hostJob
			if test.running {
				_, current = f.launch(s, "job-current", "route-a", drainingListener)
			} else {
				last := fmt.Sprintf("job-chain-%04d", test.handoff-1)
				if err := s.recordPeerListener(spec, "", last); err != nil {
					t.Fatal(err)
				}
				if err := s.suspendPeerListener("route-a", last); err != nil {
					t.Fatal(err)
				}
			}
			if _, handled, err := s.cancelPeerListenerJob("job-chain-0000"); !handled || err != nil {
				t.Fatalf("cancel: handled=%v err=%v", handled, err)
			}
			if entry, err := f.entry(s, "route-a"); !os.IsNotExist(err) {
				t.Fatalf("inbox still registered after cancel: %+v, %v", entry, err)
			}
			if current != nil {
				f.waitNoListener(s, "route-a")
			}
			if f.server().resumePeerListeners() != 0 {
				t.Fatal("a later supervisor revived the cancelled inbox")
			}
		})
	}
}

// The owner fence holds for the direct resolution: a registration of the same
// route under another owner incarnation is not this client's inbox.
func TestPeerListenerCancelLeavesAnotherOwnersRegistration(t *testing.T) {
	f := newListenerFixture(t)
	s := f.server()
	spec := f.spec("route-a", drainingListener)
	directory := filepath.Join(s.stateDir, "host-jobs", "job-old")
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	stale := *spec.binding()
	stale.Owner.Start = "an earlier incarnation"
	old := &hostJob{directory: directory, record: hostJobRecord{JobID: "job-old", Kind: hostJobKindPeerListener, Listener: &stale, State: "exited"}}
	if err := old.save(); err != nil {
		t.Fatal(err)
	}
	_, current := f.launch(s, "job-current", "route-a", drainingListener)
	if _, handled, err := s.cancelPeerListenerJob("job-old"); !handled || err != nil {
		t.Fatalf("cancel: handled=%v err=%v", handled, err)
	}
	if hostJobState(current) != "running" {
		t.Fatal("cancel stopped another owner's inbox")
	}
	if entry, err := f.entry(s, "route-a"); err != nil || entry.JobID != "job-current" || entry.State != "active" {
		t.Fatalf("other owner's registration = %+v, %v", entry, err)
	}
}

func reflectEqual(a, b []string) bool {
	return strings.Join(a, "\x00") == strings.Join(b, "\x00")
}

func TestPeerListenerNotResumedWhenOwnerGoneOrChanged(t *testing.T) {
	gone := exec.Command("/bin/sh", "-c", "exit 0")
	if err := gone.Run(); err != nil {
		t.Fatal(err)
	}
	for name, mutate := range map[string]func(f *listenerFixture, e *peerListenerEntry){
		"owner exited": func(f *listenerFixture, e *peerListenerEntry) {
			e.Owner.PID = gone.Process.Pid
			f.writeOwner(gone.Process.Pid, e.Owner.Session, e.Owner.Start)
		},
		"owner start changed": func(f *listenerFixture, e *peerListenerEntry) {
			e.Owner.Start = "Thu Jan  1 00:00:00 1970"
			f.writeOwner(e.Owner.PID, e.Owner.Session, e.Owner.Start)
		},
		"conversation changed": func(f *listenerFixture, e *peerListenerEntry) {
			f.writeOwner(e.Owner.PID, "conversation-2", e.Owner.Start)
		},
		"owner registration gone": func(f *listenerFixture, e *peerListenerEntry) {
			os.Remove(filepath.Join(f.registry, strconv.Itoa(e.Owner.PID)+".json"))
		},
	} {
		t.Run(name, func(t *testing.T) {
			f := newListenerFixture(t)
			s := f.server()
			if err := s.recordPeerListener(f.spec("route-a", drainingListener), "", "job-old"); err != nil {
				t.Fatal(err)
			}
			entry, _ := f.entry(s, "route-a")
			entry.State = "suspended"
			mutate(f, &entry)
			if err := s.writePeerListenerEntry(entry); err != nil {
				t.Fatal(err)
			}
			if resumed := s.resumePeerListeners(); resumed != 0 || len(f.servingListeners(s, "route-a")) != 0 {
				t.Fatalf("resumed %d for a changed owner", resumed)
			}
			if _, err := os.Lstat(s.peerListenerPath("route-a")); !os.IsNotExist(err) {
				t.Fatalf("stale entry kept: %v", err)
			}
		})
	}
}

func TestPeerListenerActiveOrUnsafeEntriesAreNotResumed(t *testing.T) {
	f := newListenerFixture(t)
	s := f.server()
	if err := s.recordPeerListener(f.spec("route-a", drainingListener), "", "job-old"); err != nil {
		t.Fatal(err)
	}
	if resumed := s.resumePeerListeners(); resumed != 0 {
		t.Fatal("an active entry (not drained by an upgrade) was resumed")
	}
	os.Chmod(s.peerListenerPath("route-a"), 0o644)
	if resumed := s.resumePeerListeners(); resumed != 0 {
		t.Fatal("an unsafe entry was resumed")
	}
	if _, err := os.Lstat(s.peerListenerPath("route-a")); err != nil {
		t.Fatal("an unverifiable entry was deleted rather than left for inspection")
	}
}

func TestPeerListenerRespawnRacingResumeEndsWithOneListener(t *testing.T) {
	setup := func(t *testing.T) (*listenerFixture, *Server) {
		f := newListenerFixture(t)
		old := f.server()
		f.launch(old, "job-listener", "route-a", drainingListener)
		if err := old.prepareHostUpgrade(); err != nil {
			t.Fatal(err)
		}
		return f, f.server()
	}
	t.Run("resume first", func(t *testing.T) {
		f, next := setup(t)
		next.resumePeerListeners()
		serving := f.servingListeners(next, "route-a")
		record, _ := f.launch(next, "job-respawn", "route-a", drainingListener)
		if record.State != "failed" || record.Successor != serving[0] || record.PID != 0 {
			t.Fatalf("respawn after resume = %+v", record)
		}
		if got := f.servingListeners(next, "route-a"); len(got) != 1 {
			t.Fatalf("serving listeners = %v", got)
		}
		// The superseded reservation is durable: a resend never launches.
		again, err := next.startHostJob(hostRequest{JobID: "job-respawn", Kind: hostJobKindPeerListener, KeepStdin: true, Listener: f.spec("route-a", drainingListener)})
		if err != nil || again.(hostJobRecord).State != "failed" {
			t.Fatalf("resent respawn = %v, %v", again, err)
		}
	})
	t.Run("respawn first", func(t *testing.T) {
		f, next := setup(t)
		record, _ := f.launch(next, "job-respawn", "route-a", drainingListener)
		if record.State != "running" {
			t.Fatalf("respawn = %+v", record)
		}
		if resumed := next.resumePeerListeners(); resumed != 0 {
			t.Fatal("resume launched beside the client's listener")
		}
		if got := f.servingListeners(next, "route-a"); len(got) != 1 || got[0] != "job-respawn" {
			t.Fatalf("serving listeners = %v", got)
		}
	})
	t.Run("concurrent", func(t *testing.T) {
		f, next := setup(t)
		var wait sync.WaitGroup
		wait.Add(2)
		go func() { defer wait.Done(); next.resumePeerListeners() }()
		go func() {
			defer wait.Done()
			next.startHostJob(hostRequest{JobID: "job-respawn", Kind: hostJobKindPeerListener, KeepStdin: true, Listener: f.spec("route-a", drainingListener)})
		}()
		wait.Wait()
		serving := f.servingListeners(next, "route-a")
		for _, id := range serving {
			value, _ := next.hostJobs.Load(id)
			t.Cleanup(func() { killHostJob(value.(*hostJob)) })
		}
		if len(serving) != 1 {
			t.Fatalf("serving listeners = %v", serving)
		}
	})
}

func TestPeerListenerExplicitCancelOrNaturalExitIsNotResumed(t *testing.T) {
	f := newListenerFixture(t)
	s := f.server()
	_, job := f.launch(s, "job-cancel", "route-a", drainingListener)
	if _, err := s.hostRPC(hostRequest{RequestID: "rpc-1", Operation: "cancel", JobID: "job-cancel"}); err != nil {
		t.Fatal(err)
	}
	waitHostJobExited(job, time.Now().Add(5*time.Second))
	if _, err := os.Lstat(s.peerListenerPath("route-a")); !os.IsNotExist(err) {
		t.Fatal("cancelled listener remains resumable")
	}
	_, job = f.launch(s, "job-exit", "route-b", drainingListener)
	syscall.Kill(job.cmd.Process.Pid, syscall.SIGKILL)
	waitHostJobExited(job, time.Now().Add(5*time.Second))
	if _, err := os.Lstat(s.peerListenerPath("route-b")); !os.IsNotExist(err) {
		t.Fatal("exited listener remains resumable")
	}
}

func TestHostUpgradeOrdinaryRunningJobBlocksAndIsNotSignaled(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	if _, err := s.startHostJob(hostRequest{JobID: "job-plain", KeepStdin: true, Argv: []string{"/bin/sh", "-c", "trap 'exit 0' TERM; while :; do sleep 0.05; done"}}); err != nil {
		t.Fatal(err)
	}
	value, _ := s.hostJobs.Load("job-plain")
	job := value.(*hostJob)
	t.Cleanup(func() { killHostJob(job) })
	if err := s.prepareHostUpgrade(); err == nil || !strings.Contains(err.Error(), "1 active") {
		t.Fatalf("ordinary job did not block: %v", err)
	}
	time.Sleep(200 * time.Millisecond)
	if state := hostJobState(job); state != "running" || !s.hostUpgradeUntil.IsZero() {
		t.Fatalf("ordinary job state %s, barrier %v", state, s.hostUpgradeUntil)
	}
}

func TestHostUpgradeUnknownKindBlocks(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	s.hostJobs.Store("job-other", &hostJob{record: hostJobRecord{State: "running", Kind: "peer_listener_v2"}})
	if err := s.prepareHostUpgrade(); err == nil {
		t.Fatal("unknown kind did not block")
	}
	_, err := s.startHostJob(hostRequest{JobID: "job-new", Kind: "peer_listener_v2", KeepStdin: true, Argv: []string{"/must-not-execute"}})
	if err == nil || !strings.Contains(err.Error(), "unsupported host job kind") {
		t.Fatalf("unknown kind accepted at exec: %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(s.stateDir, "host-jobs", "job-new")); !os.IsNotExist(statErr) {
		t.Fatal("rejected kind left a reservation")
	}
}

func TestHostUpgradeListenerKindRequiresTypedSpecification(t *testing.T) {
	f := newListenerFixture(t)
	s := f.server()
	spec := f.spec("route-a", drainingListener)
	bad := *spec
	bad.Route = "../escape"
	for name, r := range map[string]hostRequest{
		"argv instead of spec": {Argv: []string{"/bin/true"}, KeepStdin: true},
		"spec with argv":       {Listener: spec, Argv: []string{"/bin/true"}, KeepStdin: true},
		"env":                  {Listener: spec, KeepStdin: true, Env: map[string]string{"X": "1"}},
		"no stdin":             {Listener: spec},
		"timeout":              {Listener: spec, KeepStdin: true, TimeoutSeconds: 5},
		"invalid route":        {Listener: &bad, KeepStdin: true},
	} {
		r.JobID, r.Kind = "job-shape", hostJobKindPeerListener
		if _, err := s.startHostJob(r); err == nil {
			t.Fatalf("%s: listener accepted", name)
		}
	}
	if _, err := s.startHostJob(hostRequest{JobID: "job-plain", Listener: spec, KeepStdin: true, Argv: []string{"/bin/true"}}); err == nil {
		t.Fatal("listener specification accepted without its kind")
	}
}

func TestHostUpgradeUnverifiedListenerBlocksAndIsNotSignaled(t *testing.T) {
	check := func(t *testing.T, s *Server, job *hostJob) {
		t.Helper()
		if err := s.prepareHostUpgrade(); err == nil {
			t.Fatal("unverified listener did not block")
		}
		if state := hostJobState(job); state != "running" {
			t.Fatalf("unverified listener was signaled: %s", state)
		}
	}
	t.Run("no drain capability", func(t *testing.T) {
		f := newListenerFixture(t)
		s := f.server()
		_, job := f.launch(s, "job-listener", "route-a", legacyListener)
		check(t, s, job)
	})
	t.Run("ready frame names another process", func(t *testing.T) {
		f := newListenerFixture(t)
		s := f.server()
		_, job := f.launch(s, "job-listener", "route-a", drainingListener)
		job.mu.Lock()
		job.record.PID++
		job.mu.Unlock()
		err := s.prepareHostUpgrade()
		job.mu.Lock()
		job.record.PID--
		job.mu.Unlock()
		if err == nil || hostJobState(job) != "running" {
			t.Fatalf("mismatched listener identity: %v", err)
		}
	})
	t.Run("start identity changed", func(t *testing.T) {
		f := newListenerFixture(t)
		s := f.server()
		_, job := f.launch(s, "job-listener", "route-a", drainingListener)
		job.mu.Lock()
		job.record.ProcessStart = "Thu Jan  1 00:00:00 1970"
		job.mu.Unlock()
		check(t, s, job)
	})
	t.Run("not resumable", func(t *testing.T) {
		f := newListenerFixture(t)
		s := f.server()
		_, job := f.launch(s, "job-listener", "route-a", drainingListener)
		os.Remove(s.peerListenerPath("route-a"))
		check(t, s, job)
	})
	t.Run("not controlled by this daemon", func(t *testing.T) {
		s := &Server{stateDir: t.TempDir()}
		s.hostJobs.Store("job-listener", &hostJob{directory: t.TempDir(), listener: &peerListenerSpec{Route: "route-a"}, record: hostJobRecord{
			State: "running", Kind: hostJobKindPeerListener, PID: os.Getpid(), ProcessStart: "x"}})
		if err := s.prepareHostUpgrade(); err == nil {
			t.Fatal("listener without a controlled process did not block")
		}
	})
}

func TestHostUpgradeListenerUntouchedWhileAnotherJobBlocks(t *testing.T) {
	f := newListenerFixture(t)
	s := f.server()
	_, listener := f.launch(s, "job-listener", "route-a", drainingListener)
	s.hostJobs.Store("job-other", &hostJob{record: hostJobRecord{State: "running"}})
	if err := s.prepareHostUpgrade(); err == nil {
		t.Fatal("ordinary job did not block")
	}
	time.Sleep(200 * time.Millisecond)
	if state := hostJobState(listener); state != "running" {
		t.Fatalf("deferred upgrade disturbed the listener: %s", state)
	}
	if entry, err := f.entry(s, "route-a"); err != nil || entry.State != "active" {
		t.Fatalf("deferred upgrade changed the registry: %+v, %v", entry, err)
	}
}

func TestHostUpgradeUndrainedListenerDefersAndDrainedOnesResumeHere(t *testing.T) {
	previous := hostUpgradeListenerDrain
	hostUpgradeListenerDrain = 300 * time.Millisecond
	t.Cleanup(func() { hostUpgradeListenerDrain = previous })
	f := newListenerFixture(t)
	s := f.server()
	_, stubborn := f.launch(s, "job-stubborn", "route-a", stubbornListener)
	_, drained := f.launch(s, "job-drained", "route-b", drainingListener)
	if err := s.prepareHostUpgrade(); err == nil || !strings.Contains(err.Error(), "did not drain") {
		t.Fatalf("undrained listener did not defer: %v", err)
	}
	if !s.hostUpgradeUntil.IsZero() {
		t.Fatal("failed drain armed the barrier")
	}
	if hostJobState(stubborn) != "running" || hostJobState(drained) != "exited" {
		t.Fatalf("states %s/%s", hostJobState(stubborn), hostJobState(drained))
	}
	if entry, err := f.entry(s, "route-a"); err != nil || entry.State != "active" || entry.JobID != "job-stubborn" {
		t.Fatalf("still-running listener registry = %+v, %v", entry, err)
	}
	serving := f.servingListeners(s, "route-b")
	if len(serving) != 1 || serving[0] == "job-drained" {
		t.Fatalf("drained listener was not resumed in place: %v", serving)
	}
	value, _ := s.hostJobs.Load(serving[0])
	f.ready(value.(*hostJob))
}

func TestHostUpgradeFailedDrainDefersAndLeavesLaterListenersUntouched(t *testing.T) {
	previous := hostUpgradeListenerDrain
	hostUpgradeListenerDrain = 500 * time.Millisecond
	t.Cleanup(func() { hostUpgradeListenerDrain = previous })
	for _, test := range []struct{ name, script, reason string }{
		{"nonzero exit", failingListener, "did not drain cleanly: exited with status 3"},
		{"killed by signal", crashingListener, "did not drain cleanly: exited with status -1 (signal: killed)"},
		{"timeout", stubbornListener, "did not drain in time"},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := newListenerFixture(t)
			s := f.server()
			// Drains run in job order, so the failing listener goes first.
			_, failing := f.launch(s, "job-a-failing", "route-a", test.script)
			_, later := f.launch(s, "job-b-later", "route-b", drainingListener)
			err := s.prepareHostUpgrade()
			if err == nil || !strings.Contains(err.Error(), test.reason) {
				t.Fatalf("failed drain did not defer with %q: %v", test.reason, err)
			}
			if !s.hostUpgradeUntil.IsZero() {
				t.Fatal("failed drain armed the barrier")
			}
			// The listener after the failure was never signaled or suspended.
			if state := hostJobState(later); state != "running" {
				t.Fatalf("later listener state %s", state)
			}
			if entry, err := f.entry(s, "route-b"); err != nil || entry.State != "active" || entry.JobID != "job-b-later" {
				t.Fatalf("later listener registry = %+v, %v", entry, err)
			}
			if test.script == stubbornListener {
				if hostJobState(failing) != "running" {
					t.Fatalf("stubborn listener state %s", hostJobState(failing))
				}
				if entry, err := f.entry(s, "route-a"); err != nil || entry.State != "active" || entry.JobID != "job-a-failing" {
					t.Fatalf("still-running listener registry = %+v, %v", entry, err)
				}
				return
			}
			// The failed listener's inbox comes back here, not at a successor.
			serving := f.servingListeners(s, "route-a")
			if len(serving) != 1 || serving[0] == "job-a-failing" {
				t.Fatalf("failed listener was not resumed in place: %v", serving)
			}
			value, _ := s.hostJobs.Load(serving[0])
			f.ready(value.(*hostJob))
		})
	}
}

func TestCleanHostListenerDrainRequiresZeroStatusWithoutError(t *testing.T) {
	zero, one, killed := 0, 1, -1
	for _, test := range []struct {
		name   string
		record hostJobRecord
		clean  bool
	}{
		{"clean exit", hostJobRecord{State: "exited", ExitCode: &zero}, true},
		{"nonzero status", hostJobRecord{State: "exited", ExitCode: &one, Error: "exit status 1"}, false},
		{"signal", hostJobRecord{State: "exited", ExitCode: &killed, Error: "signal: killed"}, false},
		{"output copy failed", hostJobRecord{State: "exited", ExitCode: &zero, Error: "write stdout: no space left on device"}, false},
		{"output truncated", hostJobRecord{State: "exited", ExitCode: &zero, Error: "; output exceeded 64 MiB limit"}, false},
		{"persistence failed", hostJobRecord{State: "exited", ExitCode: &zero, Error: "running job persistence failed: disk full"}, false},
		{"status missing", hostJobRecord{State: "exited"}, false},
		{"failed state", hostJobRecord{State: "failed", ExitCode: &zero}, false},
		{"still running", hostJobRecord{State: "running"}, false},
	} {
		if got := cleanHostListenerDrain(test.record); got != test.clean {
			t.Errorf("%s: clean = %v, want %v", test.name, got, test.clean)
		}
	}
}

func TestHostUpgradeListenerWithRecordedErrorBlocks(t *testing.T) {
	f := newListenerFixture(t)
	s := f.server()
	_, job := f.launch(s, "job-listener", "route-a", drainingListener)
	job.mu.Lock()
	job.record.Error = "running job persistence failed: disk full"
	job.mu.Unlock()
	if err := s.prepareHostUpgrade(); err == nil || !strings.Contains(err.Error(), "1 active or unresolved") {
		t.Fatalf("listener with a recorded error did not block: %v", err)
	}
	if hostJobState(job) != "running" {
		t.Fatal("blocking listener was signaled")
	}
}

func TestHostUpgradeLedgerListenerStillBlocks(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	dir := filepath.Join(s.stateDir, "host-jobs", "job-test")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(hostJobRecord{JobID: "job-test", Kind: hostJobKindPeerListener, State: "running", PID: os.Getpid()})
	if err := os.WriteFile(filepath.Join(dir, "record.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := s.prepareHostUpgrade(); err == nil {
		t.Fatal("uncontrolled listener reservation did not block")
	}
}

// Requests without a kind must keep their pre-existing job fingerprints, or a
// retried exec after upgrade would be refused as a different execution.
func TestHostJobFingerprintUnchangedWithoutKind(t *testing.T) {
	s := &Server{stateDir: t.TempDir()}
	record, err := s.startHostJob(hostRequest{JobID: "job-fingerprint", Argv: []string{"/bin/true"}})
	if err != nil {
		t.Fatal(err)
	}
	legacy := `{"request_id":"","operation":"","job_id":"job-fingerprint","argv":["/bin/true"]}`
	sum := sha256.Sum256([]byte(legacy))
	if got := record.(hostJobRecord).Fingerprint; got != hex.EncodeToString(sum[:]) {
		t.Fatalf("fingerprint changed: %s", got)
	}
}

// End to end with the shipped listener: launch, drain for upgrade, resume in a
// new supervisor on the same mailbox, and refuse a racing client respawn.
func TestPeerListenerScriptDrainsAndResumesOnSameMailbox(t *testing.T) {
	// Build the shipped Go listener entry point; no interpreter or source
	// resource is optional. A missing compiler is a failed release check.
	nativeBinary := filepath.Join(t.TempDir(), "relayd")
	build := exec.Command("go", "build", "-o", nativeBinary, "./cmd/relayd")
	build.Dir = filepath.Join("..", "..")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build native listener: %v\n%s", err, output)
	}
	// Unix socket paths are short on darwin: keep this home under /tmp.
	home, err := os.MkdirTemp("/tmp", "relay-e2e-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(home) })
	t.Setenv("HOME", home)
	sessions := filepath.Join(home, ".claude", "sessions")
	if err := os.MkdirAll(sessions, 0o700); err != nil {
		t.Fatal(err)
	}
	os.Chmod(filepath.Join(home, ".claude"), 0o700)
	target := filepath.Join(home, "target.sock")
	socketListener, err := net.Listen("unix", target)
	if err != nil {
		t.Fatal(err)
	}
	defer socketListener.Close()
	// The listener finds the owner's Claude account in the owner's launch-time
	// environment, which t.Setenv cannot change. An owner started without
	// CLAUDE_CONFIG_DIR keeps the registry under this test's HOME even when
	// the test itself runs inside a Claude pane with its own config directory.
	ownerEnv := []string{}
	for _, entry := range os.Environ() {
		if !strings.HasPrefix(entry, "CLAUDE_CONFIG_DIR=") {
			ownerEnv = append(ownerEnv, entry)
		}
	}
	// macOS reports no readable environment for system binaries such as
	// /bin/sleep, so the owner is this test binary, idling in a helper.
	owner := exec.Command(os.Args[0], "-test.run=^TestPeerListenerOwnerHelper$")
	owner.Env = append(ownerEnv, peerListenerOwnerHelperEnv+"=1")
	if err := owner.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { owner.Process.Kill(); owner.Wait() })
	f := &listenerFixture{t: t, stateDir: t.TempDir(), registry: sessions}
	f.owner.PID = owner.Process.Pid
	f.owner.Start, _ = processStartIdentity(f.owner.PID)
	f.owner.Session = "conversation-e2e"
	data, _ := json.Marshal(map[string]any{"pid": f.owner.PID, "sessionId": f.owner.Session, "procStart": f.owner.Start,
		"name": "target", "cwd": "/", "messagingSocketPath": target})
	if err := os.WriteFile(filepath.Join(sessions, strconv.Itoa(f.owner.PID)+".json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	route := "relay-e2e-" + strconv.FormatInt(time.Now().UnixNano(), 36)
	mailbox := peerListenerMailbox(route)
	t.Cleanup(func() { os.RemoveAll(mailbox) })
	spec := &peerListenerSpec{Executable: nativeBinary, Route: route,
		OwnerPID: f.owner.PID, OwnerStart: f.owner.Start, OwnerSession: f.owner.Session}
	waitReady := func(job *hostJob) {
		t.Helper()
		t.Cleanup(func() { killHostJob(job) })
		deadline := time.Now().Add(10 * time.Second)
		for {
			out, _ := os.ReadFile(filepath.Join(job.directory, "stdout"))
			for _, line := range bytes.Split(out, []byte{'\n'}) {
				var event struct {
					Type  string `json:"type"`
					Drain int    `json:"drain"`
					PID   int    `json:"pid"`
				}
				if json.Unmarshal(line, &event) == nil && event.Type == "ready" && event.Drain == 1 && event.PID == job.cmd.Process.Pid {
					return
				}
			}
			if time.Now().After(deadline) || hostJobState(job) != "running" {
				errOut, _ := os.ReadFile(filepath.Join(job.directory, "stderr"))
				t.Fatalf("listener not ready: %s %s", out, errOut)
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
	old := f.server()
	if _, err := old.startHostJob(hostRequest{JobID: "job-e2e", Kind: hostJobKindPeerListener, KeepStdin: true, Listener: spec}); err != nil {
		t.Fatal(err)
	}
	value, _ := old.hostJobs.Load("job-e2e")
	first := value.(*hostJob)
	waitReady(first)
	if err := old.prepareHostUpgrade(); err != nil {
		t.Fatalf("real listener blocked the upgrade: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(mailbox, "peer.sock")); !os.IsNotExist(err) {
		t.Fatal("drained listener left its mailbox address")
	}
	next := f.server()
	if next.resumePeerListeners() != 1 {
		t.Fatal("real listener was not resumed")
	}
	serving := f.servingListeners(next, route)
	value, _ = next.hostJobs.Load(serving[0])
	waitReady(value.(*hostJob))
	if info, err := os.Lstat(filepath.Join(mailbox, "peer.sock")); err != nil || info.Mode()&os.ModeSocket == 0 {
		t.Fatalf("resumed listener does not own the mailbox: %v", err)
	}
	record, err := next.startHostJob(hostRequest{JobID: "job-e2e-respawn", Kind: hostJobKindPeerListener, KeepStdin: true, Listener: spec})
	if err != nil || record.(hostJobRecord).State != "failed" || record.(hostJobRecord).Successor != serving[0] {
		t.Fatalf("racing respawn = %v, %v", record, err)
	}
	// The client disconnects still naming the drained job: the resumed real
	// listener withdraws its address and nothing is left to resume.
	if _, err := next.hostRPC(hostRequest{RequestID: "rpc-cancel", Operation: "cancel", JobID: "job-e2e"}); err != nil {
		t.Fatalf("disconnect before adoption: %v", err)
	}
	f.waitNoListener(next, route)
	if _, err := os.Lstat(filepath.Join(mailbox, "peer.sock")); !os.IsNotExist(err) {
		t.Fatal("disconnected inbox kept its mailbox address")
	}
	if f.server().resumePeerListeners() != 0 {
		t.Fatal("a later supervisor revived the disconnected inbox")
	}
}

func (s *Server) hostUpgradeUntilSnapshot() time.Time {
	s.hostJobsMu.Lock()
	defer s.hostJobsMu.Unlock()
	return s.hostUpgradeUntil
}

// peerListenerOwnerHelperEnv makes TestPeerListenerOwnerHelper stand in for
// the listener's owner process.
const peerListenerOwnerHelperEnv = "RELAY_PEER_LISTENER_OWNER_HELPER"

// TestPeerListenerOwnerHelper is the idle owner process of the shipped
// listener test. The test kills it.
func TestPeerListenerOwnerHelper(t *testing.T) {
	if os.Getenv(peerListenerOwnerHelperEnv) != "1" {
		t.Skip("runs only as the listener test's owner process")
	}
	time.Sleep(300 * time.Second)
	os.Exit(0)
}

// TestNativePeerListenerCLIContracts ports each subprocess/signal assertion
// from tests/test_peer_listener_drain.py against the shipped Go entry point.
func TestNativePeerListenerCLIContracts(t *testing.T) {
	binary := filepath.Join(t.TempDir(), "relayd")
	build := exec.Command("go", "build", "-o", binary, "./cmd/relayd")
	build.Dir = filepath.Join("..", "..")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build native listener: %v\n%s", err, out)
	}
	home, err := os.MkdirTemp("/tmp", "relay-cli-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(home) })
	t.Setenv("HOME", home)
	registry := filepath.Join(home, ".claude", "sessions")
	if err := os.MkdirAll(registry, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Dir(registry), 0700); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(home, "target.sock")
	targetListener, err := net.Listen("unix", target)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { targetListener.Close() })
	environment := []string{}
	for _, entry := range os.Environ() {
		if !strings.HasPrefix(entry, "CLAUDE_CONFIG_DIR=") {
			environment = append(environment, entry)
		}
	}
	owner := exec.Command(os.Args[0], "-test.run=^TestPeerListenerOwnerHelper$")
	owner.Env = append(environment, peerListenerOwnerHelperEnv+"=1")
	if err := owner.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { owner.Process.Kill(); owner.Wait() })
	start, err := processStartIdentity(owner.Process.Pid)
	if err != nil {
		t.Fatal(err)
	}
	session := "native-cli-contracts"
	data, err := json.Marshal(map[string]any{"pid": owner.Process.Pid, "sessionId": session, "procStart": start, "name": "target", "cwd": "/", "messagingSocketPath": target})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(registry, strconv.Itoa(owner.Process.Pid)+".json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"backlogged sender emitted before exit", "second listener exits cleanly", "idle drain exits within original bound", "continue without TERM keeps serving"} {
		t.Run(name, func(t *testing.T) {
			route := "relay-cli-" + strconv.FormatInt(time.Now().UnixNano(), 36)
			mailbox := peerListenerMailbox(route)
			address := filepath.Join(mailbox, "peer.sock")
			t.Cleanup(func() { os.RemoveAll(mailbox) })
			args := []string{"desktop-remote", "listen", strconv.Itoa(owner.Process.Pid), session, start, route}
			outPath, errPath := filepath.Join(t.TempDir(), "stdout"), filepath.Join(t.TempDir(), "stderr")
			out, err := os.Create(outPath)
			if err != nil {
				t.Fatal(err)
			}
			defer out.Close()
			errOut, err := os.Create(errPath)
			if err != nil {
				t.Fatal(err)
			}
			defer errOut.Close()
			cmd := exec.Command(binary, args...)
			cmd.Env = environment
			cmd.Stdout = out
			cmd.Stderr = errOut
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			done := make(chan error, 1)
			go func() { done <- cmd.Wait() }()
			t.Cleanup(func() { cmd.Process.Signal(syscall.SIGCONT); cmd.Process.Kill() })
			readEvents := func() []map[string]any {
				t.Helper()
				b, e := os.ReadFile(outPath)
				if e != nil {
					t.Fatal(e)
				}
				events := []map[string]any{}
				for _, line := range bytes.Split(b, []byte{'\n'}) {
					if len(bytes.TrimSpace(line)) == 0 {
						continue
					}
					var event map[string]any
					if e := json.Unmarshal(line, &event); e != nil {
						t.Fatalf("native event: %v %q", e, line)
					}
					events = append(events, event)
				}
				return events
			}
			deadline := time.Now().Add(10 * time.Second)
			for {
				ready := false
				for _, event := range readEvents() {
					if event["type"] == "ready" {
						if event["pid"] != float64(cmd.Process.Pid) || event["drain"] != float64(1) {
							t.Fatalf("ready contract: %+v", event)
						}
						ready = true
					}
				}
				if ready {
					break
				}
				select {
				case e := <-done:
					b, _ := os.ReadFile(errPath)
					t.Fatalf("listener exited before ready: %v %s", e, b)
				default:
				}
				if time.Now().After(deadline) {
					t.Fatal("listener ready deadline")
				}
				time.Sleep(20 * time.Millisecond)
			}
			waitExit := func() []map[string]any {
				t.Helper()
				select {
				case e := <-done:
					if e != nil {
						b, _ := os.ReadFile(errPath)
						t.Fatalf("native listener exit: %v %s", e, b)
					}
				case <-time.After(15 * time.Second):
					t.Fatalf("listener exit deadline; events=%+v", readEvents())
				}
				return readEvents()
			}
			if name == "second listener exits cleanly" {
				loser := exec.Command(binary, args...)
				loser.Env = environment
				var loserOut, loserErr bytes.Buffer
				loser.Stdout = &loserOut
				loser.Stderr = &loserErr
				if err := loser.Run(); err != nil {
					t.Fatalf("duplicate listener exit: %v %s", err, loserErr.String())
				}
				if loserOut.String() != "{\"type\":\"mailbox_busy\"}\n" || loserErr.Len() != 0 {
					t.Fatalf("duplicate listener contract: stdout=%q stderr=%q", loserOut.String(), loserErr.String())
				}
				if st, e := os.Lstat(address); e != nil || st.Mode()&os.ModeSocket == 0 {
					t.Fatalf("serving mailbox removed: %v", e)
				}
				if _, e := os.Stat(filepath.Join(registry, strconv.Itoa(cmd.Process.Pid)+".json")); e != nil {
					t.Fatalf("serving registration removed: %v", e)
				}
				if e := cmd.Process.Signal(syscall.Signal(0)); e != nil {
					t.Fatalf("serving listener exited: %v", e)
				}
				cmd.Process.Signal(syscall.SIGTERM)
				waitExit()
				return
			}
			began := time.Now()
			var client net.Conn
			if name == "backlogged sender emitted before exit" || name == "continue without TERM keeps serving" {
				keys, e := filepath.Glob(filepath.Join(registry, strconv.Itoa(cmd.Process.Pid)+".*.key"))
				if e != nil || len(keys) != 1 {
					t.Fatalf("native peer key count: %v %v", keys, e)
				}
				keyData, e := os.ReadFile(keys[0])
				if e != nil {
					t.Fatal(e)
				}
				var key struct {
					Token string `json:"peerToken"`
				}
				if e := json.Unmarshal(keyData, &key); e != nil || key.Token == "" {
					t.Fatalf("native peer token: %v", e)
				}
				if e := cmd.Process.Signal(syscall.SIGSTOP); e != nil {
					t.Fatal(e)
				}
				// Observe the kernel stop before putting the sender in its
				// accept backlog; signal submission alone does not prove it.
				var stopped syscall.WaitStatus
				if pid, e := syscall.Wait4(cmd.Process.Pid, &stopped, syscall.WUNTRACED, nil); e != nil || pid != cmd.Process.Pid || stopped&0x7f != 0x7f || syscall.Signal(stopped>>8) != syscall.SIGSTOP {
					t.Fatalf("listener was not kernel-stopped: pid=%d status=%v error=%v", pid, stopped, e)
				}
				client, e = net.Dial("unix", address)
				if e != nil {
					t.Fatal(e)
				}
				defer client.Close()
				enc := json.NewEncoder(client)
				if e := enc.Encode(map[string]string{"type": "auth", "token": key.Token}); e != nil {
					t.Fatal(e)
				}
				if e := enc.Encode(map[string]any{"type": "user", "msg_id": "queued-1", "from": "uds:" + target, "message": map[string]string{"role": "user", "content": "hello queued-1"}}); e != nil {
					t.Fatal(e)
				}
			}
			if name == "continue without TERM keeps serving" {
				if e := cmd.Process.Signal(syscall.SIGCONT); e != nil {
					t.Fatal(e)
				}
				received := false
				until := time.Now().Add(10 * time.Second)
				for !received && time.Now().Before(until) {
					for _, event := range readEvents() {
						if event["type"] == "message" && event["id"] == "queued-1" {
							received = true
						}
					}
					if !received {
						time.Sleep(20 * time.Millisecond)
					}
				}
				if !received {
					t.Fatal("CONT without TERM stopped message delivery")
				}
				if _, e := os.Lstat(address); e != nil {
					t.Fatalf("CONT withdrew mailbox without TERM: %v", e)
				}
				if _, e := os.Stat(filepath.Join(registry, strconv.Itoa(cmd.Process.Pid)+".json")); e != nil {
					t.Fatalf("CONT withdrew registration without TERM: %v", e)
				}
				if e := cmd.Process.Signal(syscall.Signal(0)); e != nil {
					t.Fatalf("CONT terminated serving listener: %v", e)
				}
			}
			if e := cmd.Process.Signal(syscall.SIGTERM); e != nil {
				t.Fatal(e)
			}
			if e := cmd.Process.Signal(syscall.SIGCONT); e != nil {
				t.Fatal(e)
			}
			events := waitExit()
			if name == "idle drain exits within original bound" && time.Since(began) >= 1500*time.Millisecond {
				t.Fatalf("idle drain exceeded original 1.5s bound: %s", time.Since(began))
			}
			found := false
			for _, event := range events {
				if event["type"] == "rejected" {
					t.Fatalf("backlog rejected: %+v", event)
				}
				if event["type"] == "message" {
					if name != "backlogged sender emitted before exit" && name != "continue without TERM keeps serving" {
						t.Fatalf("idle drain emitted a message: %+v", event)
					}
					if event["id"] == "queued-1" && event["sender"] == "target" && event["content"] == "hello queued-1" && len(event) == 4 {
						found = true
					}
				}
			}
			if (name == "backlogged sender emitted before exit" || name == "continue without TERM keeps serving") && !found {
				t.Fatalf("queued message missing from drained events: %+v", events)
			}
			if _, e := os.Lstat(address); !os.IsNotExist(e) {
				t.Fatalf("drained mailbox remains: %v", e)
			}
			if _, e := os.Lstat(filepath.Join(registry, strconv.Itoa(cmd.Process.Pid)+".json")); !os.IsNotExist(e) {
				t.Fatalf("drained registration remains: %v", e)
			}
			late, e := net.Dial("unix", address)
			if e == nil {
				late.Close()
				t.Fatal("late sender reached withdrawn mailbox")
			}
		})
	}
}
