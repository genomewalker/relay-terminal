package daemon

import (
	"errors"
	"testing"
)

func TestForceAccountSelectedGuard(t *testing.T) {
	target := forceAccountTarget{Pane: "pane", Session: "session", Provider: "codex", ProviderPID: 10, ProviderStart: "a", BlockerPID: 20, BlockerStart: "b", CommandDigest: "hash"}
	valid := forceAccountObservation{Target: target, Complete: true, Present: true, Descendant: true, CommandMatches: true}
	cases := []struct {
		name         string
		observations []forceAccountObservation
		signalErr    error
		want         forceAccountResult
		calls        int
	}{
		{"exits", []forceAccountObservation{valid, valid, {Target: target, Complete: true}}, nil, forceAccountExited, 1},
		{"still running", []forceAccountObservation{valid, valid, valid}, nil, forceAccountBlocked, 1},
		{"incomplete", []forceAccountObservation{{Target: target}}, nil, forceAccountUnknown, 0},
		{"command mismatch", []forceAccountObservation{{Target: target, Complete: true, Present: true, Descendant: true}}, nil, forceAccountUnknown, 0},
		{"changed ancestry", []forceAccountObservation{valid, {Target: target, Complete: true, Present: true, CommandMatches: true}}, nil, forceAccountUnknown, 0},
		{"signal failure", []forceAccountObservation{valid, valid}, errors.New("denied"), forceAccountUnknown, 1},
		{"uncertain afterward", []forceAccountObservation{valid, valid, {}}, nil, forceAccountUnknown, 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			attempt := &forceAccountAttempt{}
			i, calls := 0, 0
			observe := func() (forceAccountObservation, error) {
				if i >= len(tc.observations) {
					return forceAccountObservation{}, errors.New("unexpected observation")
				}
				o := tc.observations[i]
				i++
				return o, nil
			}
			signal := func(pid int) error {
				calls++
				if pid != target.BlockerPID {
					t.Fatalf("wrong PID: %d", pid)
				}
				return tc.signalErr
			}
			got, _ := attempt.signalSelected(target, observe, signal)
			if got != tc.want || calls != tc.calls {
				t.Fatalf("got %s signals %d", got, calls)
			}
			got, _ = attempt.signalSelected(target, observe, signal)
			if got != forceAccountUnknown || calls != tc.calls {
				t.Fatal("attempt replayed")
			}
		})
	}
}

func TestForceAccountInventoryMemberRefusesNonMember(t *testing.T) {
	target := forceAccountTarget{Pane: "p", BlockerPID: 42}
	identity := func(int) (string, error) { return "old", nil }
	for _, p := range []hostProcess{
		{PID: 43, PaneID: "p", CanSignal: true, Start: "old"},
		{PID: 42, PaneID: "other", CanSignal: true, Start: "old"},
		{PID: 42, PaneID: "p", CanSignal: false, Start: "old"},
		{PID: 42, PaneID: "p", CanSignal: true, Start: "new"},
	} {
		if forceAccountInventoryMember([]hostProcess{p}, target, identity) {
			t.Fatalf("accepted %+v", p)
		}
	}
	if !forceAccountInventoryMember([]hostProcess{{PID: 42, PaneID: "p", CanSignal: true, Start: "old"}}, target, identity) {
		t.Fatal("valid inventory member refused")
	}
}

func TestForceAccountReviewedArgvMustMatchDigest(t *testing.T) {
	argv := []string{"sh", "-c", "echo hello"}
	target := forceAccountTarget{CommandDigest: forceAccountCommandDigest(argv)}
	if err := forceAccountValidateReviewedArgv(target, argv); err != nil {
		t.Fatal(err)
	}
	if err := forceAccountValidateReviewedArgv(target, []string{"sh", "-c", "echo goodbye"}); err == nil {
		t.Fatal("forged argv accepted")
	}
	if err := forceAccountValidateReviewedArgv(target, []string{"sh\x00bad"}); err == nil {
		t.Fatal("NUL accepted")
	}
	if err := forceAccountValidateReviewedArgv(target, nil); err == nil {
		t.Fatal("empty argv accepted")
	}
}

func TestForceAccountRejectsCustomStateRoot(t *testing.T) {
	if forceAccountDefaultStateRoot(nil) || forceAccountDefaultStateRoot(&Server{stateDir: t.TempDir()}) {
		t.Fatal("custom root accepted")
	}
	if !forceAccountDefaultStateRoot(NewServer()) {
		t.Fatal("default root rejected")
	}
}
