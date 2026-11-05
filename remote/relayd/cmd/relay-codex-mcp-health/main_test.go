package main

import (
	"os"
	"os/exec"
	"testing"
)

func TestHelpExitsSuccessfully(t *testing.T) {
	if os.Getenv("RELAY_HEALTH_HELP_TEST_CHILD") == "1" {
		os.Args = []string{"health", "--help"}
		main()
		return
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestHelpExitsSuccessfully$")
	cmd.Env = append(os.Environ(), "RELAY_HEALTH_HELP_TEST_CHILD=1")
	if out, e := cmd.CombinedOutput(); e != nil {
		t.Fatalf("help must exit successfully: %v %s", e, out)
	}
}
