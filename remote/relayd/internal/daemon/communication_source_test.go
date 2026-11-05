package daemon

import (
	"encoding/json"
	"os"
	"testing"
)

const (
	sourceFixturePane = "129286a2-6e69-4d1a-9c83-91a0a2dec1e9"
	targetFixturePane = "cbf0ccc8-ce1e-4708-ba5c-809b60a289e6"
)

func withSenderPermissionClass(t *testing.T, mode string) *[]int {
	t.Helper()
	calls := []int{}
	previous := senderPermissionClass
	senderPermissionClass = func(pid int, session string) string {
		calls = append(calls, pid)
		return mode
	}
	t.Cleanup(func() { senderPermissionClass = previous })
	return &calls
}

func sourceFixture(transport string) communicationMember {
	return communicationMember{PaneID: sourceFixturePane, PID: 4242, Start: "fixture", Provider: "codex",
		SessionID: "sender-thread", Endpoint: map[string]any{"transport": transport, "socketPath": "/tmp/sender.sock"}}
}

func verifiedSendFixture() CommunicationRequest {
	return CommunicationRequest{Operation: "send", SourcePaneID: sourceFixturePane, ActorPaneID: sourceFixturePane,
		PaneID: targetFixturePane, actorVerified: true}
}

func TestCommunicationVerifiedSourceCarriesProviderAndMode(t *testing.T) {
	calls := withSenderPermissionClass(t, "bypass")
	packet := communicationSourcePacket(verifiedSendFixture(), "node-1", sourceFixture("codex_app_server_message"))
	if packet["authentication"] != "kernel_verified" || packet["provider"] != "codex" ||
		packet["permissionClass"] != "bypass" || packet["sessionID"] != "sender-thread" ||
		packet["hostID"] != "node-1" || packet["paneID"] != sourceFixturePane {
		t.Fatal("verified sender lost identity", packet)
	}
	if _, ok := packet["socketPath"]; ok {
		t.Fatal("a Codex sender has no native inbox reply address", packet)
	}
	if len(*calls) != 1 || (*calls)[0] != 4242 {
		t.Fatal("permission class must be read for the observed harness PID", *calls)
	}
}

func TestCommunicationVerifiedClaudeSourceOffersItsInbox(t *testing.T) {
	withSenderPermissionClass(t, "prompting")
	source := sourceFixture("native_peer_socket")
	source.Provider = "claude"
	packet := communicationSourcePacket(verifiedSendFixture(), "node-1", source)
	if packet["socketPath"] != "/tmp/sender.sock" || packet["permissionClass"] != "prompting" {
		t.Fatal("verified Claude sender lost its native reply address", packet)
	}
	source.Endpoint["socketPath"] = "relative.sock"
	if _, ok := communicationSourcePacket(verifiedSendFixture(), "node-1", source)["socketPath"]; ok {
		t.Fatal("non-absolute inbox path accepted")
	}
}

func TestCommunicationUnknownModeIsUnasserted(t *testing.T) {
	for _, mode := range []string{"", "default", "bypass\" from-mode=\"x"} {
		withSenderPermissionClass(t, mode)
		packet := communicationSourcePacket(verifiedSendFixture(), "node-1", sourceFixture("codex_app_server_message"))
		if _, ok := packet["permissionClass"]; ok || packet["authentication"] != "kernel_verified" {
			t.Fatal("unknown permission class asserted", mode, packet)
		}
	}
}

func TestCommunicationClaimedSourceStaysUnverified(t *testing.T) {
	calls := withSenderPermissionClass(t, "bypass")
	unverified := verifiedSendFixture()
	unverified.actorVerified = false
	otherSender := verifiedSendFixture()
	otherSender.SourcePaneID = targetFixturePane
	noActor := verifiedSendFixture()
	noActor.ActorPaneID = ""
	for _, r := range []CommunicationRequest{unverified, otherSender, noActor} {
		packet := communicationSourcePacket(r, "node-1", sourceFixture("native_peer_socket"))
		if packet["authentication"] != "claimed_pane_label" || len(packet) != 4 {
			t.Fatal("claimed sender gained verified attributes", r, packet)
		}
	}
	if len(*calls) != 0 {
		t.Fatal("permission class read for an unverified sender")
	}
}

// Host RPC and owner requests reach ExecuteCommunication without a kernel
// actor check. Neither JSON nor an actor label may mark them verified.
func TestCommunicationVerificationCannotComeFromJSON(t *testing.T) {
	for _, raw := range []string{
		`{"operation":"send","source_pane_id":"` + sourceFixturePane + `","actor_pane_id":"` + sourceFixturePane + `","actorVerified":true}`,
		`{"operation":"send","source_pane_id":"` + sourceFixturePane + `","actor_pane_id":"` + sourceFixturePane + `","actor_verified":true}`,
	} {
		var r CommunicationRequest
		if err := json.Unmarshal([]byte(raw), &r); err != nil {
			t.Fatal(err)
		}
		if communicationSourceVerified(r) {
			t.Fatal("JSON marked a sender verified", raw)
		}
		var wrapped hostRequest
		if err := json.Unmarshal([]byte(`{"operation":"communication","communication":`+raw+`}`), &wrapped); err != nil {
			t.Fatal(err)
		}
		if wrapped.Communication == nil || communicationSourceVerified(*wrapped.Communication) {
			t.Fatal("host RPC request marked a sender verified", raw)
		}
	}
	encoded, _ := json.Marshal(verifiedSendFixture())
	var decoded map[string]any
	if json.Unmarshal(encoded, &decoded) != nil {
		t.Fatal("request did not encode")
	}
	for key := range decoded {
		if key == "actorVerified" || key == "actor_verified" {
			t.Fatal("verification leaked into the wire format")
		}
	}
}

func TestCommunicationActorOutsideAPaneIsNotVerified(t *testing.T) {
	// Isolate the catalog: go test may itself be launched from a real Relay pane.
	// Personal worker publications must not turn this negative fixture into a
	// legitimately authenticated sender.
	t.Setenv("HOME", t.TempDir())
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	r := CommunicationRequest{Operation: "send", SourcePaneID: sourceFixturePane, ActorPaneID: sourceFixturePane, actorVerified: true}
	got, err := ReconcileCommunicationActor(r, os.Getpid())
	if err == nil || communicationSourceVerified(got) {
		t.Fatal("process outside a pane was verified", got, err)
	}
	empty, err := ReconcileCommunicationActor(CommunicationRequest{Operation: "list", actorVerified: true}, os.Getpid())
	if err != nil || communicationSourceVerified(empty) {
		t.Fatal("request without an actor kept a verified mark", err)
	}
}
