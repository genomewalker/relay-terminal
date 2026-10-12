package daemon

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/relay-terminal/relayd/internal/peernet"
)

func TestPaneBoundTeamsDoNotBecomeLiveEdges(t *testing.T) {
	peers := []NetworkPeer{
		{DiscoveredPeer: peernet.DiscoveredPeer{Session: "lead"}},
		{DiscoveredPeer: peernet.DiscoveredPeer{Session: "duplicate"}},
		{DiscoveredPeer: peernet.DiscoveredPeer{Session: "duplicate"}},
	}
	teams := []peernet.ClaudeTeam{
		{Name: "shown", LeadSession: "lead"},
		{Name: "unmapped", LeadSession: "other"},
		{Name: "ambiguous", LeadSession: "duplicate"},
	}
	got := paneBoundTeams(peers, teams)
	if len(got) != 1 || got[0].Name != "shown" {
		t.Fatalf("unexpected pane-bound teams: %+v", got)
	}
}

func TestNativeGroupStatusesRequireExactLiveMembers(t *testing.T) {
	home := t.TempDir()
	root := filepath.Join(home, ".local", "state", "relay", "native-groups")
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	id := "cbed3fa0-1d8f-4ee8-b586-ba9ab6da5c6a"
	data := `{"group":"CBED3FA0-1D8F-4EE8-B586-BA9AB6DA5C6A","state":"introductions_attempted","topology":"everyone","participants":[{"host":"dandy-07","session":"a","name":"agent-a","pid":10,"processStart":"100"},{"host":"dandy-07","session":"b","name":"agent-b","pid":11,"processStart":"101"}],"introductions":[{"receipt":"written_to_socket"},{"receipt":"written_to_socket"}]}`
	if err := os.WriteFile(filepath.Join(root, id+".json"), []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
	peers := []NetworkPeer{
		{DiscoveredPeer: peernet.DiscoveredPeer{Name: "agent-a", Session: "a", PID: 10, Start: "100"}},
		{DiscoveredPeer: peernet.DiscoveredPeer{Name: "agent-b", Session: "b", PID: 11, Start: "101"}},
	}
	groups := readNativeGroupStatuses(home, peers)
	if len(groups) != 1 || !groups[0].Current {
		t.Fatalf("current group: %+v", groups)
	}
	peers[1].Start = "replacement"
	groups = readNativeGroupStatuses(home, peers)
	if len(groups) != 1 || groups[0].Current {
		t.Fatalf("stale group: %+v", groups)
	}
	if err := os.Chmod(filepath.Join(root, id+".json"), 0666); err != nil {
		t.Fatal(err)
	}
	if got := readNativeGroupStatuses(home, peers); len(got) != 0 {
		t.Fatalf("unsafe group: %+v", got)
	}
}
