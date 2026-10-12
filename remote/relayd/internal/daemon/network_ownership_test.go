package daemon

import "testing"

func TestNetworkPeerOwnershipIncludesExecReplacedShell(t *testing.T) {
	pane := CatalogPane{ShellPID: 100, WorkerPID: 90}
	for _, chain := range [][]int{{100, 90, 80}, {110, 100, 90, 80}, {120, 110, 100, 90, 80}} {
		index, ok := networkPeerPaneOwnership(chain, pane)
		if !ok || index < 0 || chain[index] != pane.ShellPID {
			t.Fatalf("rejected valid ownership %v", chain)
		}
	}
}
func TestNetworkPeerOwnershipRejectsForeignOrInvertedAncestors(t *testing.T) {
	pane := CatalogPane{ShellPID: 100, WorkerPID: 90}
	for _, chain := range [][]int{nil, {100}, {110, 100, 80}, {110, 90, 100}, {110, 90, 80}} {
		if _, ok := networkPeerPaneOwnership(chain, pane); ok {
			t.Fatalf("accepted foreign ancestry %v", chain)
		}
	}
	for _, invalid := range []CatalogPane{{}, {ShellPID: 100, WorkerPID: 100}, {ShellPID: 1, WorkerPID: 90}} {
		if _, ok := networkPeerPaneOwnership([]int{110, 100, 90}, invalid); ok {
			t.Fatal("accepted invalid pane ownership")
		}
	}
}
