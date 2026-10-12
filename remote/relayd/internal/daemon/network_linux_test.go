//go:build linux

package daemon

import (
	"os"
	"strconv"
	"testing"
)

func TestNetworkAncestorsRejectsReusedIdentity(t *testing.T) {
	pid := os.Getpid()
	stamp, err := processStartTime(pid)
	if err != nil {
		t.Fatal(err)
	}
	chain, err := networkAncestors(pid, strconv.FormatUint(stamp, 10))
	if err != nil || len(chain) == 0 || chain[0] != pid {
		t.Fatalf("invalid chain %v %v", chain, err)
	}
	if _, err := networkAncestors(pid, strconv.FormatUint(stamp+1, 10)); err == nil {
		t.Fatal("accepted wrong start stamp")
	}
}
