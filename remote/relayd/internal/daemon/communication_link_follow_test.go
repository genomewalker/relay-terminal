package daemon

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/relay-terminal/relayd/internal/nativemsg"
)

func followMember(session string, pid int, start string) communicationMember {
	return communicationMember{PaneID: targetFixturePane, Provider: "claude", SessionID: session, PID: pid, Start: start,
		Endpoint: map[string]any{"provider": "claude", "sessionID": session, "pid": float64(pid), "start": start, "transport": "native_peer_socket"}}
}

// A pane's /clear keeps the process and changes only the session: the link
// follows. A different process, provider or an unverified endpoint does not.
func TestLinkFollowsAConversationChangeOnlyInTheSameProcess(t *testing.T) {
	saved := followMember("old-session", 4242, "linux:100")
	saved.Name, saved.HostID = "Pane", "host"
	for _, c := range []struct {
		name    string
		live    communicationMember
		moved   bool
		refused string
	}{
		{"unchanged", followMember("old-session", 4242, "linux:100"), false, ""},
		{"cleared_same_process", followMember("new-session", 4242, "linux:100"), true, ""},
		{"resumed_in_new_process", followMember("old-session", 5151, "linux:200"), true, ""},
		{"new_process_new_session", followMember("new-session", 5151, "linux:200"), false, "relink needed"},
		{"pid_reused_by_another_process", followMember("new-session", 4242, "linux:999"), false, "relink needed"},
		{"other_provider", func() communicationMember {
			m := followMember("new-session", 4242, "linux:100")
			m.Provider = "codex"
			return m
		}(), false, "conversation changed"},
		{"no_endpoint", func() communicationMember {
			m := followMember("new-session", 4242, "linux:100")
			m.Endpoint = nil
			return m
		}(), false, "conversation changed"},
		{"unavailable", func() communicationMember {
			m := followMember("new-session", 4242, "linux:100")
			m.Unavailable = "no verified endpoint"
			return m
		}(), false, "conversation changed"},
	} {
		t.Run(c.name, func(t *testing.T) {
			got, moved, err := communicationLinkFollow(saved, c.live)
			if c.refused != "" {
				if err == nil || !strings.Contains(err.Error(), c.refused) || moved {
					t.Fatalf("want refusal %q, got moved=%v err=%v", c.refused, moved, err)
				}
				return
			}
			if err != nil || moved != c.moved {
				t.Fatalf("moved=%v err=%v", moved, err)
			}
			if got.SessionID != c.live.SessionID || got.PID != c.live.PID || got.Start != c.live.Start ||
				got.PaneID != saved.PaneID || got.Name != "Pane" || got.HostID != "host" {
				t.Fatalf("stored member %+v", got)
			}
		})
	}
	// A pin that never recorded a process cannot prove one.
	unpinned := saved
	unpinned.PID, unpinned.Start = 0, ""
	if _, _, err := communicationLinkFollow(unpinned, followMember("new-session", 4242, "linux:100")); err == nil {
		t.Fatal("a pin without a process followed a new session")
	}
}

// End to end on one host: the recipient pane runs /clear (same pid and start,
// new session). The next send is delivered, the saved pair names the new
// session, its review revision is unchanged, and the change is recorded.
// A later process change is refused with the relink text and sends nothing.
func TestLocalPairFollowsAClearedPaneAndRefusesANewProcess(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	root := communicationRoot()
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	// An empty policy: the owner's unattributed sends, as the daemon's own app uses.
	if err := communicationAtomic(communicationPolicyPath(root), communicationPolicy{}); err != nil {
		t.Fatal(err)
	}
	live := map[string]communicationMember{
		sourceFixturePane: {PaneID: sourceFixturePane, Provider: "claude", SessionID: "sender", PID: 1111, Start: "linux:1"},
		targetFixturePane: followMember("old-session", 4242, "linux:100"),
	}
	sends := 0
	useNativeRun(t, func(_ context.Context, _ nativemsg.Host, pane string, data []byte) map[string]any {
		var request map[string]any
		_ = json.Unmarshal(data, &request)
		if request["operation"] == "send" {
			sends++
			return map[string]any{"status": "written_to_socket", "acknowledgement": "not_implied"}
		}
		m := live[pane]
		return map[string]any{"endpoint": map[string]any{"provider": m.Provider, "sessionID": m.SessionID, "pid": m.PID,
			"start": m.Start, "transport": "native_peer_socket"}}
	})
	id, _, err := communicationPair(sourceFixturePane, targetFixturePane)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "link-"+id+".json")
	saved := communicationLink{Version: 1, ID: id, NodeID: currentCommunicationNodeID(), Transport: "relay_native_socket",
		Members: []communicationMember{live[sourceFixturePane], live[targetFixturePane]}}
	if err := communicationAtomic(path, saved); err != nil {
		t.Fatal(err)
	}
	if err := communicationRead(path, &saved); err != nil {
		t.Fatal(err)
	}
	send := func(message string) error {
		_, err := ExecuteCommunication(CommunicationRequest{Operation: "send", SourcePaneID: sourceFixturePane, PaneID: targetFixturePane,
			MessageID: message, Text: "after clear"})
		return err
	}
	live[targetFixturePane] = followMember("new-session", 4242, "linux:100")
	if err := send("a1a1a1a1-a1a1-4a1a-8a1a-a1a1a1a1a1a1"); err != nil || sends != 1 {
		t.Fatalf("send after /clear: err=%v sends=%d", err, sends)
	}
	var stored communicationLink
	if err := communicationRead(path, &stored); err != nil {
		t.Fatal(err)
	}
	if stored.Members[1].SessionID != "new-session" || stored.Members[1].PID != 4242 || !stored.UpdatedAt.Equal(saved.UpdatedAt) {
		t.Fatalf("stored pair %+v (updated_at %v, was %v)", stored.Members[1], stored.UpdatedAt, saved.UpdatedAt)
	}
	audit, err := os.ReadFile(filepath.Join(root, "link-"+id+".repins.jsonl"))
	if err != nil || !strings.Contains(string(audit), `"old_session":"old-session"`) || !strings.Contains(string(audit), `"new_session":"new-session"`) ||
		!strings.Contains(string(audit), `"kind":"conversation_followed"`) {
		t.Fatalf("repin audit %q err=%v", audit, err)
	}
	live[targetFixturePane] = followMember("third-session", 5151, "linux:200")
	if err := send("b2b2b2b2-b2b2-4b2b-8b2b-b2b2b2b2b2b2"); err == nil || !strings.Contains(err.Error(), "relink needed") || sends != 1 {
		t.Fatalf("a new process was followed: err=%v sends=%d", err, sends)
	}
}

// Miko's own messages follow a recipient that ran /clear in the same process.
func TestAssistantSendFollowsARecipientClearedInTheSameProcess(t *testing.T) {
	root, here, target, sent, native := assistantFixture(t)
	id, _, err := communicationPair(here, target)
	if err != nil {
		t.Fatal(err)
	}
	pinned := communicationMember{PaneID: target, Provider: "claude", SessionID: "s-0", PID: 42, Start: "k:1"}
	if err := communicationAtomic(filepath.Join(root, "link-"+id+".json"), communicationLink{Version: 1, ID: id,
		Members: []communicationMember{{PaneID: here}, pinned}}); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationAssistantSend(root, "node", assistantRequest(here, target), native); err != nil || len(*sent) != 1 {
		t.Fatalf("Miko's message after /clear: err=%v sent=%d", err, len(*sent))
	}
	var stored communicationLink
	if err := communicationRead(filepath.Join(root, "link-"+id+".json"), &stored); err != nil || stored.Members[1].SessionID != "s-1" {
		t.Fatalf("stored %+v err=%v", stored.Members, err)
	}
}

// An agent restarted in the same pane (a new process, a new conversation) is
// the same partner when the kernel shows the same pane root and provider. A
// changed root (pane recovery, another terminal) or provider is not.
func TestLinkFollowsAnAgentRestartedUnderTheSamePaneRoot(t *testing.T) {
	withRoot := func(m communicationMember, root int, start string) communicationMember {
		endpoint := map[string]any{}
		for k, v := range m.Endpoint {
			endpoint[k] = v
		}
		endpoint["rootPID"], endpoint["rootStart"] = float64(root), start
		m.Endpoint = endpoint
		return m
	}
	saved := withRoot(followMember("old-session", 4575, "darwin:5"), 39777, "darwin:1")
	restarted := withRoot(followMember("new-session", 65179, "darwin:8"), 39777, "darwin:1")
	got, moved, err := communicationLinkFollow(saved, restarted)
	if err != nil || !moved || got.SessionID != "new-session" || got.PID != 65179 {
		t.Fatalf("restart under the same root: %+v moved=%v err=%v", got, moved, err)
	}
	if root, start := communicationEndpointRoot(got.Endpoint); root != 39777 || start != "darwin:1" {
		t.Fatal("the followed member lost its pane root", root, start)
	}
	for name, live := range map[string]communicationMember{
		"other_root_pid":   withRoot(followMember("new-session", 65179, "darwin:8"), 40000, "darwin:1"),
		"other_root_start": withRoot(followMember("new-session", 65179, "darwin:8"), 39777, "darwin:2"),
		"no_root":          followMember("new-session", 65179, "darwin:8"),
	} {
		if _, _, err := communicationLinkFollow(saved, live); err == nil || !strings.Contains(err.Error(), "relink needed") {
			t.Fatal(name, "was followed", err)
		}
	}
	codex := restarted
	codex.Provider = "codex"
	if _, _, err := communicationLinkFollow(saved, codex); err == nil {
		t.Fatal("a restart under another provider was followed")
	}
	// A pin without a recorded root gains one on the next unchanged use.
	plain := followMember("same", 1, "s")
	rooted := withRoot(followMember("same", 1, "s"), 9, "r")
	if got, moved, err := communicationLinkFollow(plain, rooted); err != nil || !moved {
		t.Fatal("the pane root was not recorded", got, moved, err)
	} else if root, _ := communicationEndpointRoot(got.Endpoint); root != 9 {
		t.Fatal("root not stored", got.Endpoint)
	}
}
