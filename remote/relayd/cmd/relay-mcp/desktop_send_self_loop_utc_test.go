package main

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
)

// Routes record a Mac owner's start as ps prints it in UTC. The guard read the
// ancestry in the caller's local time, so on a Mac outside UTC it never matched
// and the route owner's own send still looped back. Reads the real ancestry.
func TestDesktopSendSelfLoopMatchesRecordedUTCStart(t *testing.T) {
	t.Setenv("TZ", "Europe/Copenhagen")
	command := exec.Command("ps", "-o", "lstart=", "-p", strconv.Itoa(os.Getppid()))
	command.Env = append(os.Environ(), "TZ=UTC", "LC_ALL=C")
	out, err := command.Output()
	if err != nil {
		t.Skip("ps unavailable:", err)
	}
	recorded := strings.TrimSpace(string(out))
	if !desktopSendFromOwner("laptop", os.Getppid(), recorded) {
		t.Fatalf("owner with recorded UTC start %q not recognised", recorded)
	}
	if desktopSendFromOwner("laptop", os.Getppid(), "Thu Jan  1 00:00:00 1970") {
		t.Fatal("different incarnation recognised as the owner")
	}
}
