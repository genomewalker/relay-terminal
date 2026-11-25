package daemon

import (
	"os"
	"strings"
	"testing"
	"time"
)

const macCommunication = `if [ -x "$HOME/.local/share/relay/bin/relayd-communication" ]; then "$HOME/.local/share/relay/bin/relayd-communication" communication; else "$HOME/.local/bin/relayd" 'communication'; fi`

func TestRelayChannelOriginMatchesOnlyExactLaunchShapes(t *testing.T) {
	work := `if [ -x "$HOME/.local/share/relay/bin/relayd-work-communication" ]; then "$HOME/.local/share/relay/bin/relayd-work-communication" communication; else echo 'relayd: the Work host-channel helper is not installed on this host' >&2; exit 1; fi`
	channel := map[string]hostRequest{
		"communication":      {Command: macCommunication},
		"work communication": {Command: work},
		"shepherd":           {Command: strings.Replace(macCommunication, "communication; else", "communication-shepherd; else", 1)},
		"agent maintenance":  {Argv: []string{"/home/u/.local/share/relay/bin/relayd-linux-amd64", "agent-maintenance", "--pane", "p"}},
		"agent conversation": {Argv: []string{".local/bin/relayd", "agent-conversation"}},
		"claude helper":      {Argv: []string{"/usr/bin/claude", "-p", "--output-format", "stream-json"}},
	}
	for name, r := range channel {
		if relayChannelOrigin(r) != hostJobOriginRelayChannel {
			t.Errorf("%s: not classified as a Relay channel job", name)
		}
	}
	plain := map[string]hostRequest{
		"user job mentioning the helper": {Command: "relayd-communication communication; ./train.sh"},
		"helper names differ":            {Command: strings.Replace(macCommunication, `then "$HOME/.local/share/relay/bin/relayd-communication"`, `then "$HOME/.local/share/relay/bin/relayd-work-communication"`, 1)},
		"appended command":               {Command: macCommunication + "; ./train.sh"},
		"multi-line else":                {Command: strings.Replace(macCommunication, "else ", "else ./a\n", 1)},
		"relative relayd":                {Argv: []string{"relayd", "agent-maintenance"}},
		"other relayd verb":              {Argv: []string{"/x/relayd", "service", "start"}},
		"other binary":                   {Argv: []string{"/x/python", "agent-maintenance"}},
		"claude interactive":             {Argv: []string{"/usr/bin/claude", "--output-format", "stream-json"}},
		"claude text output":             {Argv: []string{"/usr/bin/claude", "-p", "--output-format", "text"}},
		"listener kind":                  {Kind: hostJobKindPeerListener, Argv: []string{"/x/relayd", "communication"}},
	}
	for name, r := range plain {
		if got := relayChannelOrigin(r); got != "" {
			t.Errorf("%s: classified as %q", name, got)
		}
	}
}

func shortChannelDrain(t *testing.T, d time.Duration) {
	drain, poll := hostUpgradeChannelDrain, hostUpgradeChannelPoll
	hostUpgradeChannelDrain, hostUpgradeChannelPoll = d, 10*time.Millisecond
	t.Cleanup(func() { hostUpgradeChannelDrain, hostUpgradeChannelPoll = drain, poll })
}

func TestHostUpgradeWaitsForChannelJobInsteadOfDeferring(t *testing.T) {
	shortChannelDrain(t, 3*time.Second)
	s := &Server{stateDir: t.TempDir()}
	job := &hostJob{record: hostJobRecord{JobID: "job-chan", State: "running", Origin: hostJobOriginRelayChannel}}
	s.hostJobs.Store("job-chan", job)
	refused := make(chan error, 1)
	go func() {
		time.Sleep(150 * time.Millisecond)
		// While the upgrade waits, nothing new may start.
		_, err := s.startHostJob(hostRequest{JobID: "job-new", Argv: []string{"/must-not-execute"}})
		refused <- err
		time.Sleep(150 * time.Millisecond)
		job.mu.Lock()
		job.record.State = "exited"
		job.mu.Unlock()
	}()
	if err := s.prepareHostUpgrade(); err != nil {
		t.Fatalf("a finishing channel job deferred the upgrade: %v", err)
	}
	if err := <-refused; err == nil || !strings.Contains(err.Error(), "handoff in progress") {
		t.Fatalf("a job started during the wait: %v", err)
	}
	if !time.Now().Before(s.hostUpgradeUntil) {
		t.Fatal("prepared upgrade has no barrier")
	}
}

func TestHostUpgradeDefersAndLiftsBarrierWhenChannelJobOutlivesWait(t *testing.T) {
	shortChannelDrain(t, 200*time.Millisecond)
	s := &Server{stateDir: t.TempDir()}
	job := &hostJob{record: hostJobRecord{JobID: "job-chan", State: "running", Origin: hostJobOriginRelayChannel}}
	s.hostJobs.Store("job-chan", job)
	err := s.prepareHostUpgrade()
	if err == nil || !strings.Contains(err.Error(), "none were signalled") {
		t.Fatalf("got %v", err)
	}
	if !s.hostUpgradeUntil.IsZero() {
		t.Fatal("deferred upgrade left the barrier up")
	}
	if job.record.State != "running" {
		t.Fatal("channel job was disturbed")
	}
}

func TestHostUpgradeLookAlikeJobStillDefersWithoutWaiting(t *testing.T) {
	shortChannelDrain(t, 5*time.Second)
	s := &Server{stateDir: t.TempDir()}
	s.hostJobs.Store("job-chan", &hostJob{record: hostJobRecord{JobID: "job-chan", State: "running", Origin: hostJobOriginRelayChannel}})
	// Same command text, but started without the mark: an ordinary job.
	s.hostJobs.Store("job-user", &hostJob{record: hostJobRecord{JobID: "job-user", State: "running"}})
	// A listener kind can never be waited for as a channel.
	s.hostJobs.Store("job-kind", &hostJob{record: hostJobRecord{JobID: "job-kind", Kind: hostJobKindPeerListener, State: "running", Origin: hostJobOriginRelayChannel}})
	start := time.Now()
	err := s.prepareHostUpgrade()
	if err == nil || !strings.Contains(err.Error(), "2 active or unresolved") {
		t.Fatalf("got %v", err)
	}
	if time.Since(start) > time.Second || !s.hostUpgradeUntil.IsZero() {
		t.Fatal("a blocked upgrade waited or raised the barrier")
	}
}

func TestHostUpgradeLedgerChannelNeedsProvenIdentity(t *testing.T) {
	shortChannelDrain(t, 200*time.Millisecond)
	start, err := processStartIdentity(os.Getpid())
	if err != nil || start == "" {
		t.Skip("process start identity unavailable")
	}
	// Alive with its exact incarnation: waited for, then deferred because it
	// is still running.
	s := &Server{stateDir: t.TempDir()}
	writeUpgradeLedgerRecord(t, s.stateDir, hostJobRecord{JobID: "job-chan", State: "running", PID: os.Getpid(), ProcessStart: start, Origin: hostJobOriginRelayChannel})
	if err := s.prepareHostUpgrade(); err == nil || !strings.Contains(err.Error(), "channel jobs still running") {
		t.Fatalf("alive ledger channel: %v", err)
	}
	// Unknown identity still blocks outright.
	s = &Server{stateDir: t.TempDir()}
	writeUpgradeLedgerRecord(t, s.stateDir, hostJobRecord{JobID: "job-chan", State: "running", PID: os.Getpid(), Origin: hostJobOriginRelayChannel})
	if err := s.prepareHostUpgrade(); err == nil || !strings.Contains(err.Error(), "active or unresolved") {
		t.Fatalf("unknown ledger channel: %v", err)
	}
	// Gone: nothing to wait for.
	s = &Server{stateDir: t.TempDir()}
	writeUpgradeLedgerRecord(t, s.stateDir, hostJobRecord{JobID: "job-chan", State: "running", PID: 1 << 22, ProcessStart: start, Origin: hostJobOriginRelayChannel})
	if err := s.prepareHostUpgrade(); err != nil {
		t.Fatalf("gone ledger channel: %v", err)
	}
}
