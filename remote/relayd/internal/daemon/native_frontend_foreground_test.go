package daemon

import (
	"errors"
	"reflect"
	"testing"
)

func TestForegroundFrontendRootsPrefersTheTerminalForegroundJob(t *testing.T) {
	// A resumed Claude (98663, foreground) beside its suspended predecessor (43912).
	groups := map[int]int{43912: 43912, 98663: 98663}
	group := func(pid int) (int, error) { return groups[pid], nil }
	foreground := func(int) (int, error) { return 98663, nil }
	if got := foregroundFrontendRoots([]int{43912, 98663}, group, foreground); !reflect.DeepEqual(got, []int{98663}) {
		t.Fatalf("roots = %v, want [98663]", got)
	}
	// Two agents in one foreground pipeline stay ambiguous.
	shared := func(int) (int, error) { return 7, nil }
	if got := foregroundFrontendRoots([]int{1, 2}, shared, shared); len(got) != 2 {
		t.Fatalf("roots = %v, want both", got)
	}
	// With no agent in the foreground (shell prompt in front), nothing is selected.
	if got := foregroundFrontendRoots([]int{43912, 98663}, group, func(int) (int, error) { return 51340, nil }); len(got) != 0 {
		t.Fatalf("roots = %v, want none", got)
	}
	// Any failed lookup refuses rather than guessing.
	failing := func(pid int) (int, error) {
		if pid == 43912 {
			return 0, errors.New("gone")
		}
		return 98663, nil
	}
	if got := foregroundFrontendRoots([]int{43912, 98663}, failing, foreground); got != nil {
		t.Fatalf("roots = %v, want nil", got)
	}
}
