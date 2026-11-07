package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const desktopSession = "5a30d83a-5222-48f3-93c7-42fa687d901b"
const otherSession = "800c06ef-203f-4401-bf7a-c67b15985f33"
const targetPane = "1652a003-70e9-4614-addb-68564fa8383b"

func desktopHelper(t *testing.T, pane string, source string) (server, string) {
	t.Helper()
	wire := filepath.Join(t.TempDir(), "wire.json")
	helper := nativeMCPFixture(t, nativeFixtureConfig{Pane: pane, ClientPID: os.Getpid(), Source: source, Wire: wire,
		Default: nativeFixtureReply{Out: `{"status":"accepted"}`, Record: true}})
	return server{daemonHelper: helper, callerToken: "fixture-caller"}, wire
}

func rawArgs(values map[string]string) map[string]json.RawMessage {
	args := map[string]json.RawMessage{}
	for k, v := range values {
		args[k], _ = json.Marshal(v)
	}
	return args
}

func wirePacket(t *testing.T, wire string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(wire)
	if err != nil {
		t.Fatal("no packet reached the daemon", err)
	}
	var packet map[string]any
	if json.Unmarshal(data, &packet) != nil {
		t.Fatal("invalid packet")
	}
	return packet
}

// A verified desktop session's send becomes the daemon's remote_send, with the
// proven session as sender and no link ID for the daemon to resolve.
func TestDesktopSessionSendDispatchesRemoteSend(t *testing.T) {
	s, wire := desktopHelper(t, desktopSession, desktopSessionSource)
	value, handled := s.daemonCommunication("relay_message_pane", rawArgs(map[string]string{"pane_id": targetPane, "message_id": "fixture-message", "text": "hello"}))
	if !handled {
		t.Fatal("not handled")
	}
	packet := wirePacket(t, wire)
	if packet["operation"] != "remote_send" || packet["actor_pane_id"] != desktopSession || packet["source_pane_id"] != desktopSession ||
		packet["client_token"] != "fixture-caller" || packet["link_id"] != "" || packet["pane_id"] != targetPane {
		t.Fatal("desktop session send not dispatched as remote_send", packet)
	}
	data, _ := json.Marshal(value)
	if !strings.Contains(string(data), "delivered back to this Claude desktop session") {
		t.Fatal("reply limitation not stated", string(data))
	}
}

// A sender named in the arguments is never the proven identity: another
// session or pane is refused before any packet is sent.
func TestDesktopSessionSendRefusesClaimedIdentity(t *testing.T) {
	s, wire := desktopHelper(t, desktopSession, desktopSessionSource)
	value, _ := s.daemonCommunication("relay_message_pane", rawArgs(map[string]string{"source_pane_id": otherSession, "pane_id": targetPane, "text": "x"}))
	if _, err := os.Stat(wire); !os.IsNotExist(err) {
		t.Fatal("a claimed sender reached the daemon")
	}
	data, _ := json.Marshal(value)
	if !strings.Contains(string(data), "Sender must be this Claude desktop session") {
		t.Fatal(string(data))
	}
	for _, args := range []map[string]string{
		{"pane_id": targetPane, "link_id": "0000000000000000000000000000000000000000000000000000000000000000"},
		{"pane_id": targetPane, "target_session_id": otherSession, "text": "x"},
	} {
		s, wire := desktopHelper(t, desktopSession, desktopSessionSource)
		if _, handled := s.daemonCommunication("relay_message_pane", rawArgs(args)); !handled {
			t.Fatal("not refused", args)
		}
		if _, err := os.Stat(wire); !os.IsNotExist(err) {
			t.Fatal("a refused argument reached the daemon", args)
		}
	}
}

// Pane callers keep the pane-to-pane send.
func TestPaneCallerSendUnchanged(t *testing.T) {
	pane := "800c06ef-203f-4401-bf7a-c67b15985f33"
	s, wire := desktopHelper(t, pane, "native_parked_job_kernel_owner")
	s.daemonCommunication("relay_message_pane", rawArgs(map[string]string{"source_pane_id": pane, "pane_id": targetPane, "message_id": "fixture-message", "text": "x"}))
	packet := wirePacket(t, wire)
	if packet["operation"] != "send" || packet["actor_pane_id"] != pane {
		t.Fatal("pane send changed", packet)
	}
}

// A desktop session's link request reaches the daemon as a pending request and
// names only the proven session; it never carries a link or a sender argument.
func TestDesktopSessionLinkRequestIsOnlyARequest(t *testing.T) {
	s, wire := desktopHelper(t, desktopSession, desktopSessionSource)
	value, handled := s.daemonCommunication("relay_link_panes", rawArgs(map[string]string{"pane_id": targetPane, "peer_node_id": "e36bb8094237dae4"}))
	if !handled {
		t.Fatal("not handled")
	}
	packet := wirePacket(t, wire)
	if packet["operation"] != "desktop_link_request" || packet["actor_pane_id"] != desktopSession || packet["pane_id"] != targetPane {
		t.Fatal("link request not dispatched as a pending request", packet)
	}
	data, _ := json.Marshal(value)
	if !strings.Contains(string(data), "must approve this link in Relay") {
		t.Fatal(string(data))
	}
	s2, wire2 := desktopHelper(t, desktopSession, desktopSessionSource)
	s2.daemonCommunication("relay_link_panes", rawArgs(map[string]string{"source_pane_id": otherSession, "pane_id": targetPane, "peer_node_id": "e36bb8094237dae4"}))
	if _, err := os.Stat(wire2); !os.IsNotExist(err) {
		t.Fatal("a claimed source made a request")
	}
}

// A pane's reply to a desktop session is the pane's own send: the daemon finds
// the pinned pair and routes it. The pane is the verified sender, and no link
// ID or sender identity is taken from the arguments.
func TestPaneReplyToDesktopSessionIsAPaneSend(t *testing.T) {
	pane := "800c06ef-203f-4401-bf7a-c67b15985f33"
	s, wire := desktopHelper(t, pane, "native_parked_job_kernel_owner")
	value, handled := s.daemonCommunication("relay_message_pane", rawArgs(map[string]string{"pane_id": desktopSession,
		"message_id": "c3c3c3c3-c3c3-4c3c-8c3c-c3c3c3c3c3c3", "text": "reply to the desktop"}))
	if !handled {
		t.Fatal("not handled")
	}
	packet := wirePacket(t, wire)
	if packet["operation"] != "send" || packet["actor_pane_id"] != pane || packet["pane_id"] != desktopSession || packet["client_token"] != "fixture-caller" {
		t.Fatal("pane reply not sent as the pane's own send", packet)
	}
	if _, has := packet["link_id"]; has {
		t.Fatal("a link ID was supplied by the caller", packet)
	}
	data, _ := json.Marshal(value)
	if strings.Contains(string(data), "\"isError\":true") {
		t.Fatal("the pane reply was refused", string(data))
	}
}

// The desktop inbox is read by the verified desktop session only.
func TestDesktopInboxReadIsForTheVerifiedSessionOnly(t *testing.T) {
	s, wire := desktopHelper(t, desktopSession, desktopSessionSource)
	s.daemonCommunication("relay_read_desktop_inbox", map[string]json.RawMessage{})
	packet := wirePacket(t, wire)
	if packet["operation"] != "desktop_inbox_read" || packet["actor_pane_id"] != desktopSession || packet["source_pane_id"] != desktopSession {
		t.Fatal("inbox read not for the verified session", packet)
	}
	if _, has := packet["client_token"]; has {
		t.Fatal("a caller token was attached to an inbox read", packet)
	}
	pane := "800c06ef-203f-4401-bf7a-c67b15985f33"
	p, paneWire := desktopHelper(t, pane, "native_parked_job_kernel_owner")
	value, _ := p.daemonCommunication("relay_read_desktop_inbox", map[string]json.RawMessage{})
	if _, err := os.Stat(paneWire); !os.IsNotExist(err) {
		t.Fatal("a pane read the desktop inbox", value)
	}
	if data, _ := json.Marshal(value); !strings.Contains(string(data), "Only a verified Claude desktop session") {
		t.Fatal(string(data))
	}
}

// A link request names the host of its pane; without it nothing is requested.
func TestDesktopSessionLinkRequestNeedsThePeerHost(t *testing.T) {
	s, wire := desktopHelper(t, desktopSession, desktopSessionSource)
	value, _ := s.daemonCommunication("relay_link_panes", rawArgs(map[string]string{"pane_id": targetPane}))
	if _, err := os.Stat(wire); !os.IsNotExist(err) {
		t.Fatal("a request without its host reached the daemon", value)
	}
	s2, wire2 := desktopHelper(t, desktopSession, desktopSessionSource)
	s2.daemonCommunication("relay_link_panes", rawArgs(map[string]string{"pane_id": targetPane, "peer_node_id": "not-a-node"}))
	if _, err := os.Stat(wire2); !os.IsNotExist(err) {
		t.Fatal("a malformed host reached the daemon")
	}
}

// A relay-mcp without the daemon backend (the Claude desktop config's own
// connector) must say why it cannot read a desktop inbox, not "Unknown tool".
// Such a server can shadow a Code session's daemon-backed "relay" server.
func TestDesktopInboxWithoutDaemonNamesTheShadowingConnector(t *testing.T) {
	s := &server{}
	for _, call := range []map[string]any{
		{"name": "relay_read_desktop_inbox", "arguments": map[string]any{}},
		{"name": "relay_call_tool", "arguments": map[string]any{"tool_name": "relay_read_desktop_inbox", "arguments": map[string]any{}}},
	} {
		params, _ := json.Marshal(call)
		value, code, detail := s.handle(request{JSONRPC: "2.0", ID: json.RawMessage("1"), Method: "tools/call", Params: params})
		if code != 0 || detail != "" {
			t.Fatalf("%v: protocol error %d %q", call["name"], code, detail)
		}
		data, _ := json.Marshal(value)
		text := string(data)
		if !strings.Contains(text, `"isError":true`) || !strings.Contains(text, "claude_desktop_config.json") || !strings.Contains(text, "Nothing was read") {
			t.Fatalf("%v: %s", call["name"], text)
		}
	}
}
