package agentaccounts

import (
	"fmt"
	"strings"
	"syscall"
	"testing"
)

func TestLockRefusalNamesOnlyAHeldLockAsAChangeInProgress(t *testing.T) {
	if got := lockRefusal(errAccountsBusy); got != "an accounts change is in progress" {
		t.Fatalf("busy: %q", got)
	}
	nfs := fmt.Errorf("the accounts lock could not be taken: %w", syscall.ENOLCK)
	if got := lockRefusal(nfs); strings.Contains(got, "in progress") || !strings.Contains(got, "no locks available") {
		t.Fatalf("ENOLCK reported as %q", got)
	}
}
