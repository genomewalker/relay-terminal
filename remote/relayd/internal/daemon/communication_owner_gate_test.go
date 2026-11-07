package daemon

import (
	"bytes"
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// withAgentAncestors names the test process as an agent for the owner gate. Every
// other process is treated as not an agent.
func withAgentAncestors(t *testing.T, kind string, agents func(int) bool) {
	t.Helper()
	previous := communicationAgentAncestor
	communicationAgentAncestor = func(pid int) (string, error) {
		if agents(pid) {
			return kind, nil
		}
		return "", nil
	}
	t.Cleanup(func() { communicationAgentAncestor = previous })
}

var ownerOperations = []string{"route_desktop_link_approve", "route_desktop_link_establish", "route_desktop_link_list",
	"route_desktop_link_reject", "route_trust_scope_pin", "route_link_set", "node_trust_set"}

// An owner operation from a process whose ancestor is a pane agent is refused,
// for every owner operation, route_link_set included.
func TestOwnerOperationRefusedFromPaneAgentDescendant(t *testing.T) {
	child, _ := spawnAccountOwner(t, nil)
	withAgentAncestors(t, "codex", func(pid int) bool { return pid == os.Getpid() })
	for _, operation := range ownerOperations {
		err := communicationOwnerGate(CommunicationRequest{Operation: operation}, child)
		if err == nil || !strings.Contains(err.Error(), "not available to agent processes") {
			t.Fatal("owner operation from a pane agent's descendant was not refused", operation, err)
		}
	}
}

// A Claude desktop session is an agent too, so its descendants cannot approve.
func TestOwnerOperationRefusedFromDesktopSessionDescendant(t *testing.T) {
	child, _ := spawnAccountOwner(t, nil)
	withAgentAncestors(t, "claude", func(pid int) bool { return pid == os.Getpid() })
	if err := communicationOwnerGate(CommunicationRequest{Operation: "route_desktop_link_approve", RequestID: strings.Repeat("a", 64)}, child); err == nil {
		t.Fatal("a desktop session's descendant approved a link")
	}
}

// When the caller's ancestry cannot be read, the operation is refused.
func TestOwnerOperationRefusedWhenAncestryUnreadable(t *testing.T) {
	withAgentAncestors(t, "", func(int) bool { return false })
	gone := spawnGonePID(t)
	if err := communicationOwnerGate(CommunicationRequest{Operation: "route_desktop_link_approve"}, gone); err == nil {
		t.Fatal("a caller whose identity is gone was allowed")
	}
	if err := communicationOwnerGate(CommunicationRequest{Operation: "route_desktop_link_approve"}, 0); err == nil {
		t.Fatal("an unidentifiable caller was allowed")
	}
	child, _ := spawnAccountOwner(t, nil)
	previous := communicationAgentAncestor
	communicationAgentAncestor = func(pid int) (string, error) {
		if pid == os.Getpid() {
			return "", errors.New("process unreadable")
		}
		return "", nil
	}
	t.Cleanup(func() { communicationAgentAncestor = previous })
	if err := communicationOwnerGate(CommunicationRequest{Operation: "route_desktop_link_approve"}, child); err == nil ||
		!strings.Contains(err.Error(), "unreadable") {
		t.Fatal("an unreadable ancestor was not refused", err)
	}
}

// The owner's own application is not an agent: its owner operations pass.
func TestOwnerOperationAllowedForTheOwnerApplication(t *testing.T) {
	child, _ := spawnAccountOwner(t, nil)
	withAgentAncestors(t, "claude", func(int) bool { return false })
	for _, operation := range ownerOperations {
		if err := communicationOwnerGate(CommunicationRequest{Operation: operation}, child); err != nil {
			t.Fatal("the owner's request was refused", operation, err)
		}
	}
	// Non-owner operations are never gated here.
	withAgentAncestors(t, "claude", func(pid int) bool { return pid == os.Getpid() })
	if err := communicationOwnerGate(CommunicationRequest{Operation: "desktop_link_request"}, child); err != nil {
		t.Fatal("a non-owner operation was gated", err)
	}
	// A request that carries a client credential is refused as before.
	if err := communicationOwnerGate(CommunicationRequest{Operation: "route_link_set", ClientToken: "provider"}, child); err == nil {
		t.Fatal("an owner operation with a client credential was allowed")
	}
}

// The host socket path refuses owner communication from an agent before it runs.
func TestHostSocketOwnerOperationRefusedFromAgent(t *testing.T) {
	child, _ := spawnAccountOwner(t, nil)
	withAgentAncestors(t, "claude", func(pid int) bool { return pid == os.Getpid() })
	var wire bytes.Buffer
	frame, err := protocol.JSONFrame(protocol.HostRequest, hostRequest{RequestID: "rpc-owner-1", Operation: "communication",
		Communication: &CommunicationRequest{Operation: "route_desktop_link_approve", RequestID: strings.Repeat("a", 64)}})
	if err != nil {
		t.Fatal(err)
	}
	server := &Server{stateDir: t.TempDir()}
	server.serveHostRPCFrom(protocol.NewWriter(&wire), frame, hostCaller{pid: child})
	answer, err := protocol.ReadFrame(bytes.NewReader(wire.Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	var response map[string]any
	if protocol.DecodeJSON(answer, &response) != nil || !strings.Contains(response["error"].(string), "not available to agent processes") {
		t.Fatal("the socket path ran an owner operation for an agent", response)
	}
}

var carrierOperations = []string{"work_native_pending", "work_native_claim", "work_native_settle", "deliver_signed_work", "deliver_signed_desktop_establish"}

// The host-channel carrier operations return queued message text or act as the
// peer host, so an agent's descendant is refused each of them, and the owner's
// application passes.
func TestCarrierOperationsAreOwnerOperations(t *testing.T) {
	child, _ := spawnAccountOwner(t, nil)
	withAgentAncestors(t, "claude", func(pid int) bool { return pid == os.Getpid() })
	for _, operation := range carrierOperations {
		err := communicationOwnerGate(CommunicationRequest{Operation: operation}, child)
		if err == nil || !strings.Contains(err.Error(), "not available to agent processes") {
			t.Fatal("a carrier operation from an agent's descendant was not refused", operation, err)
		}
	}
	withAgentAncestors(t, "claude", func(int) bool { return false })
	for _, operation := range carrierOperations {
		if err := communicationOwnerGate(CommunicationRequest{Operation: operation}, child); err != nil {
			t.Fatal("the owner's carrier operation was refused", operation, err)
		}
		if err := communicationOwnerGate(CommunicationRequest{Operation: operation, ClientToken: "x"}, child); err == nil {
			t.Fatal("a carrier operation with a caller token was allowed", operation)
		}
	}
}

// Every process on the real carrier paths, as traced on 2026-11-07, is not an
// agent: on the Mac Relay -> relayd node -> /bin/sh -lc -> relayd communication;
// on dandy sshd -D -> sshd [priv] -> sshd notty -> relayd node -> /bin/sh -lc ->
// relayd-work-communication. A change that flags any of them would refuse the
// carrier itself.
func TestCarrierAncestryIsNotAnAgent(t *testing.T) {
	for _, hop := range [][2]string{
		{"Relay", "/Applications/Relay.app/Contents/MacOS/Relay"},
		{"relayd", "/Applications/Relay.app/Contents/MacOS/relayd\x00node\x00"},
		{"sh", "/bin/sh\x00-lc\x00'/Applications/Relay.app/Contents/MacOS/relayd' 'communication'\x00"},
		{"sshd", "/usr/sbin/sshd\x00-D\x00"},
		{"sshd", "sshd: kbd606 [priv]"},
		{"sshd", "sshd: kbd606@notty"},
		{"relayd-linux-am", "/home/kbd606/.local/share/relay/bin/relayd-linux-amd64\x00node\x00"},
		{"sh", "/bin/sh\x00-lc\x00if [ -x \"$HOME/.local/share/relay/bin/relayd-work-communication\" ]; then \"$HOME/.local/share/relay/bin/relayd-work-communication\" communication; fi\x00"},
		{"relayd-work-com", "/home/kbd606/.local/share/relay/bin/relayd-work-communication\x00communication\x00"},
	} {
		if kind := classifyAgentProcess(hop[0], hop[1]); kind != "" {
			t.Fatal("a carrier hop is classified as an agent", hop[0], kind)
		}
	}
}
