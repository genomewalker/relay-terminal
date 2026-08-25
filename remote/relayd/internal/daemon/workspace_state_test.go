package daemon

import (
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/relay-terminal/relayd/internal/protocol"
)

func TestWorkspaceStatePersistsAndRejectsCompetingLease(t *testing.T) {
	server := NewServer()
	server.stateDir = filepath.Join(t.TempDir(), "workers")
	put := func(client, value string) workspaceStateResponse {
		request, _ := json.Marshal(workspaceStateRequest{
			Operation: "put", ClientID: client, State: json.RawMessage(value),
		})
		frame := server.handleWorkspaceState("workspace-1", request)
		if frame.Type != protocol.WorkspaceState {
			t.Fatalf("unexpected frame: %#v", frame)
		}
		var response workspaceStateResponse
		if json.Unmarshal(frame.Payload, &response) != nil {
			t.Fatal("invalid response")
		}
		return response
	}
	first := put("client-a", `{"tabs":["a"]}`)
	if !first.OK || first.Revision != 1 {
		t.Fatalf("first put failed: %#v", first)
	}
	unchanged := put("client-a", `{ "tabs": ["a"] }`)
	if !unchanged.OK || unchanged.Revision != 1 {
		t.Fatalf("equivalent state caused a write: %#v", unchanged)
	}
	blocked := put("client-b", `{"tabs":["b"]}`)
	if blocked.OK {
		t.Fatalf("competing lease was accepted: %#v", blocked)
	}
	second := put("client-a", `{"tabs":["a","b"]}`)
	if !second.OK || second.Revision != 2 {
		t.Fatalf("owner update failed: %#v", second)
	}
	restored, err := server.loadWorkspaceState("workspace-1")
	if err != nil || string(restored.State) != `{"tabs":["a","b"]}` {
		t.Fatalf("state was not restored: %#v err=%v", restored, err)
	}
}
