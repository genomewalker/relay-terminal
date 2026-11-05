//go:build darwin || linux

package daemon

import (
	"os"
	"strconv"
	"testing"
)

// Opt-in, read-only integration check for an explicitly supplied native pane
// and child. It never invokes the commit path or signals a process.
func TestForceAccountLivePreview(t *testing.T) {
	pane := os.Getenv("RELAY_FORCE_TEST_PANE")
	if pane == "" {
		t.Skip("no explicit live preview target")
	}
	providerPID, e1 := strconv.Atoi(os.Getenv("RELAY_FORCE_TEST_PROVIDER_PID"))
	blockerPID, e2 := strconv.Atoi(os.Getenv("RELAY_FORCE_TEST_CHILD_PID"))
	if e1 != nil || e2 != nil {
		t.Fatal("explicit numeric PIDs required")
	}
	target := forceAccountTarget{Pane: pane, Provider: "claude", Session: os.Getenv("RELAY_FORCE_TEST_SESSION"),
		ProviderPID: providerPID, ProviderStart: os.Getenv("RELAY_FORCE_TEST_PROVIDER_START"), BlockerPID: blockerPID}
	result, err := NewServer().accountForceRPC("account_force_preview", &forceAccountRPCRequest{Target: target})
	if err != nil {
		t.Fatal(err)
	}
	response, ok := result.(map[string]any)
	if !ok || response["status"] != "ready" {
		t.Fatal("invalid preview envelope")
	}
	resolved, ok := response["target"].(forceAccountTarget)
	if !ok {
		t.Fatal("invalid target")
	}
	argv, ok := response["argv"].([]string)
	if !ok {
		t.Fatal("invalid argv")
	}
	if resolved.BlockerStart == "" || len(argv) == 0 || forceAccountValidateReviewedArgv(resolved, argv) != nil {
		t.Fatal("preview did not bind the exact process incarnation and argv")
	}
}
