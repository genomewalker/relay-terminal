package daemon

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNativeClaudeParkedPairGuards(t *testing.T) {
	front := nativeClaudeRegistration{PID: 123, Kind: "interactive", Entrypoint: "cli",
		SessionID: "009f406d-c23a-483c-b212-3f4e7461be26", ParkedJobID: "5577ee9d", PIDDomain: "native-domain"}
	bg := nativeClaudeRegistration{PID: 456, Kind: "bg", Entrypoint: "cli",
		SessionID: "5577ee9d-5e02-4ca8-b208-74360e3f65d1", JobID: "5577ee9d", PIDDomain: "native-domain"}
	if err := nativeClaudeParkedPair(front, bg); err != nil {
		t.Fatal(err)
	}
	for name, change := range map[string]func(*nativeClaudeRegistration, *nativeClaudeRegistration){
		"wrong job":       func(a, b *nativeClaudeRegistration) { b.JobID = "aaaaaaaa" },
		"unsafe job":      func(a, b *nativeClaudeRegistration) { a.ParkedJobID = "../bad"; b.JobID = a.ParkedJobID },
		"wrong domain":    func(a, b *nativeClaudeRegistration) { b.PIDDomain = "other" },
		"same process":    func(a, b *nativeClaudeRegistration) { b.PID = a.PID },
		"foreground kind": func(a, b *nativeClaudeRegistration) { a.Kind = "bg" },
		"background kind": func(a, b *nativeClaudeRegistration) { b.Kind = "interactive" },
		"proxy":           func(a, b *nativeClaudeRegistration) { b.RelayProxy = true },
		"sdk":             func(a, b *nativeClaudeRegistration) { b.Entrypoint = "sdk" },
		"invalid session": func(a, b *nativeClaudeRegistration) { b.SessionID = "../../session" },
	} {
		t.Run(name, func(t *testing.T) {
			a, b := front, bg
			change(&a, &b)
			if nativeClaudeParkedPair(a, b) == nil {
				t.Fatal("unsafe attachment accepted")
			}
		})
	}
}

func TestNativeClaudeBackgroundRegistrationGuards(t *testing.T) {
	dir := t.TempDir()
	_ = os.Chmod(dir, 0700)
	p := filepath.Join(dir, "123.json")
	row := nativeClaudeRegistration{PID: 123, ProcessStart: "expected", Kind: "bg", Entrypoint: "cli",
		SessionID: "5577ee9d-5e02-4ca8-b208-74360e3f65d1", JobID: "5577ee9d", PeerProtocol: 1,
		PIDDomain: nativeClaudePIDDomain(), Socket: filepath.Join(dir, "peer.sock")}
	data, _ := json.Marshal(row)
	_ = os.WriteFile(p, data, 0600)
	if _, _, _, err := readNativeClaudeRegistrationKind(p, 123, "expected", "bg"); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := readNativeClaudeRegistration(p, 123, "expected"); err == nil {
		t.Fatal("background accepted as interactive")
	}
	if _, _, _, err := readNativeClaudeRegistrationKind(p, 123, "different", "bg"); err == nil {
		t.Fatal("stale background accepted")
	}
}

func TestNativeClaudeContinuationGuards(t *testing.T) {
	dir := t.TempDir()
	_ = os.Chmod(dir, 0700)
	p := filepath.Join(dir, "conversation.jsonl")
	old := "009f406d-c23a-483c-b212-3f4e7461be26"
	next := "5577ee9d-5e02-4ca8-b208-74360e3f65d1"
	row := func(kind, session, target string) string {
		data, _ := json.Marshal(map[string]string{"type": kind, "sessionId": session, "continuedInSessionId": target})
		return string(data) + "\n"
	}
	_ = os.WriteFile(p, []byte(row("assistant", old, "invented")+row("continued-in", old, next)), 0600)
	if got, err := nativeClaudeNextSession(p, old); err != nil || got != next {
		t.Fatal(got, err)
	}
	_ = os.WriteFile(p, []byte(row("continued-in", old, next)+row("continued-in", old, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")), 0600)
	if _, err := nativeClaudeNextSession(p, old); err == nil {
		t.Fatal("ambiguous continuation accepted")
	}
	_ = os.WriteFile(p, []byte(row("continued-in", old, old)), 0600)
	if _, err := nativeClaudeNextSession(p, old); err == nil {
		t.Fatal("cyclic continuation accepted")
	}
	_ = os.Chmod(p, 0664)
	if _, err := nativeClaudeNextSession(p, old); err == nil {
		t.Fatal("writable continuation accepted")
	}
}

func writeNativeClaudeJobState(t *testing.T, config, job, body string, mode os.FileMode) {
	t.Helper()
	dir := filepath.Join(config, "jobs", job)
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "state.json"), []byte(body), mode); err != nil {
		t.Fatal(err)
	}
	_ = os.Chmod(filepath.Join(dir, "state.json"), mode)
}

func TestNativeClaudeJobStateReadsOnlyTheMarker(t *testing.T) {
	config := t.TempDir()
	_ = os.Chmod(config, 0700)
	writeNativeClaudeJobState(t, config, "5577ee9d",
		`{"state":"working","detail":"T36 gate","env":{"CLAUDE_CODE_SESSION_ATTENDED":"0"},"oauthToken":"never-read"}`, 0600)
	if state, err := readNativeClaudeJobState(config, "5577ee9d"); err != nil || state != "working" {
		t.Fatal(state, err)
	}
	writeNativeClaudeJobState(t, config, "2aea736a", `{"state":"done"}`, 0666)
	if _, err := readNativeClaudeJobState(config, "2aea736a"); err == nil {
		t.Fatal("writable job state accepted")
	}
	if _, err := readNativeClaudeJobState(config, "../jobs"); err == nil {
		t.Fatal("unsafe job identifier accepted")
	}
	if err := os.MkdirAll(filepath.Join(config, "jobs", "aaaaaaaa"), 0700); err != nil {
		t.Fatal(err)
	}
	_ = os.Symlink(filepath.Join(config, "jobs", "5577ee9d", "state.json"), filepath.Join(config, "jobs", "aaaaaaaa", "state.json"))
	if _, err := readNativeClaudeJobState(config, "aaaaaaaa"); err == nil {
		t.Fatal("symlinked job state accepted")
	}
	if _, err := readNativeClaudeJobState(config, "bbbbbbbb"); err == nil {
		t.Fatal("missing job state read as a state")
	}
}

func paneJob(id, state string) nativeClaudePaneJob {
	return nativeClaudePaneJob{JobID: id, SessionID: id + "-0000-4000-8000-000000000000", State: state}
}

// The Seula pane: the frontend still names finished job 2aea736a while the
// pane's job 5577ee9d is working. The pane binding must refuse, not guess.
func TestNativeClaudeParkedChoiceNeverKeepsAFinishedJobOverALiveOne(t *testing.T) {
	for name, tc := range map[string]struct {
		parkedState string
		jobs        []nativeClaudePaneJob
		refuse      bool
	}{
		"parked working alone":              {"working", []nativeClaudePaneJob{paneJob("2aea736a", "working")}, false},
		"parked working, other working":     {"working", []nativeClaudePaneJob{paneJob("2aea736a", "working"), paneJob("5577ee9d", "working")}, false},
		"parked done alone":                 {"done", []nativeClaudePaneJob{paneJob("2aea736a", "done")}, false},
		"parked done, other done":           {"done", []nativeClaudePaneJob{paneJob("2aea736a", "done"), paneJob("5577ee9d", "failed")}, false},
		"parked done, other working":        {"done", []nativeClaudePaneJob{paneJob("2aea736a", "done"), paneJob("5577ee9d", "working")}, true},
		"parked done, other blocked":        {"done", []nativeClaudePaneJob{paneJob("5577ee9d", "blocked")}, true},
		"parked done, other state unknown":  {"done", []nativeClaudePaneJob{paneJob("5577ee9d", "")}, true},
		"parked state unknown, other alive": {"", []nativeClaudePaneJob{paneJob("5577ee9d", "working")}, false},
	} {
		t.Run(name, func(t *testing.T) {
			err := nativeClaudeParkedChoice("2aea736a", tc.parkedState, tc.jobs)
			if (err != nil) != tc.refuse {
				t.Fatalf("refused=%v, want %v: %v", err != nil, tc.refuse, err)
			}
			if tc.refuse && (!strings.Contains(err.Error(), "5577ee9d") || !strings.Contains(err.Error(), "target session")) {
				t.Fatalf("refusal does not name the live job or the remedy: %v", err)
			}
		})
	}
}

func TestNativeClaudeTargetChoiceSelectsOnlyOneLiveNamedJob(t *testing.T) {
	live, done := paneJob("5577ee9d", "working"), paneJob("2aea736a", "done")
	if job, err := nativeClaudeTargetChoice(live.SessionID, []nativeClaudePaneJob{done, live}); err != nil || job.JobID != "5577ee9d" {
		t.Fatal(job, err)
	}
	if _, err := nativeClaudeTargetChoice(done.SessionID, []nativeClaudePaneJob{done, live}); err == nil || !strings.Contains(err.Error(), "done") {
		t.Fatal("finished target accepted", err)
	}
	if _, err := nativeClaudeTargetChoice("aaaaaaaa-0000-4000-8000-000000000000", []nativeClaudePaneJob{done, live}); err == nil {
		t.Fatal("unknown target accepted")
	}
	if _, err := nativeClaudeTargetChoice(live.SessionID, []nativeClaudePaneJob{live, live}); err == nil {
		t.Fatal("duplicate target accepted")
	}
}

// Pane attribution: a job started from another pane is never this pane's.
func TestNativeClaudePaneJobsAttributeByRelaySession(t *testing.T) {
	config := t.TempDir()
	_ = os.Chmod(config, 0700)
	sessions := filepath.Join(config, "sessions")
	_ = os.MkdirAll(sessions, 0700)
	pid := os.Getpid()
	start, err := processStartIdentity(pid)
	if err != nil {
		t.Skip("process start identity unavailable:", err)
	}
	row := nativeClaudeRegistration{PID: pid, ProcessStart: start, Kind: "bg", Entrypoint: "cli",
		SessionID: "5577ee9d-5e02-4ca8-b208-74360e3f65d1", JobID: "5577ee9d", PeerProtocol: 1,
		PIDDomain: nativeClaudePIDDomain(), Socket: filepath.Join(config, "peer.sock")}
	data, _ := json.Marshal(row)
	_ = os.WriteFile(filepath.Join(sessions, fmt.Sprintf("%d.json", pid)), data, 0600)
	writeNativeClaudeJobState(t, config, "5577ee9d", `{"state":"working"}`, 0600)
	original := nativeClaudeJobPane
	defer func() { nativeClaudeJobPane = original }()
	for pane, want := range map[string]int{"5a30d83a-5222-48f3-93c7-42fa687d901b": 1, "0e426bf7-0000-4000-8000-000000000000": 0} {
		nativeClaudeJobPane = func(int) string { return "5a30d83a-5222-48f3-93c7-42fa687d901b" }
		jobs, err := nativeClaudePaneJobs(config, pane)
		if err != nil || len(jobs) != want {
			t.Fatalf("pane %s: %d jobs, want %d (%v)", pane, len(jobs), want, err)
		}
		if want == 1 && (jobs[0].State != "working" || jobs[0].SessionID != row.SessionID) {
			t.Fatal(jobs[0])
		}
	}
}
