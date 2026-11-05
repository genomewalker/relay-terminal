package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const fallbackPane = "cbf0ccc8-ce1e-4708-ba5c-809b60a289e6"

// fallbackHelper proves fallbackPane for this process and answers the
// communication operation with the given exit code, stdout and stderr.
func fallbackHelper(t *testing.T, exit int, stdout, stderr string) (server, string) {
	t.Helper()
	wire := filepath.Join(t.TempDir(), "wire.json")
	helper := nativeMCPFixture(t, nativeFixtureConfig{Pane: fallbackPane, Wire: wire, Default: nativeFixtureReply{Out: stdout, Error: stderr, Exit: exit, Record: true}})
	return server{daemonHelper: helper, callerToken: "fixture-caller", token: "fixture-desktop"}, wire
}

func messageArgs() map[string]json.RawMessage {
	args := map[string]json.RawMessage{}
	for k, v := range map[string]string{"source_pane_id": fallbackPane, "pane_id": "129286a2-6e69-4d1a-9c83-91a0a2dec1e9",
		"message_id": "0c9d4e6b-7a21-4f83-b5e9-2d8f1a6c3e57", "text": "fixture only"} {
		args[k], _ = json.Marshal(v)
	}
	return args
}

func TestCommunicationLocalPairUsesVerifiedDaemonPath(t *testing.T) {
	t.Setenv("RELAY_SESSION", fallbackPane)
	s, wire := fallbackHelper(t, 0, `{"status":"written_to_socket","source_authentication":"kernel_verified"}`, "")
	if _, handled := s.daemonCommunication("relay_message_pane", messageArgs()); !handled {
		t.Fatal("a pair owned by this node left the verified path")
	}
	data, err := os.ReadFile(wire)
	if err != nil {
		t.Fatal(err)
	}
	var packet map[string]any
	_ = json.Unmarshal(data, &packet)
	if packet["actor_pane_id"] != fallbackPane || packet["client_token"] != "fixture-caller" {
		t.Fatal("actor proof or caller credential missing", packet)
	}
}

func TestCommunicationCrossHostPairFallsBackBeforeAnyWrite(t *testing.T) {
	t.Setenv("RELAY_SESSION", fallbackPane)
	s, _ := fallbackHelper(t, 1, "", "relayd: save the communication pair on this daemon before sending")
	if _, handled := s.daemonCommunication("relay_message_pane", messageArgs()); handled {
		t.Fatal("cross-host send did not fall back to the desktop path")
	}
	// This is the Mac-side (non-remote) mode; the remote mode proposes instead (link_proposal_test.go).
	defer func(f func() bool) { linkProposalRemote = f }(linkProposalRemote)
	linkProposalRemote = func() bool { return false }
	s, _ = fallbackHelper(t, 1, "", "relayd: both panes must belong to this daemon; remote peers require a server route")
	link := map[string]json.RawMessage{}
	link["pane_id"], _ = json.Marshal("129286a2-6e69-4d1a-9c83-91a0a2dec1e9")
	if _, handled := s.daemonCommunication("relay_link_panes", link); handled {
		t.Fatal("cross-host link did not fall back to the desktop path")
	}
}

func TestCommunicationOtherDaemonFailuresNeverFallBack(t *testing.T) {
	t.Setenv("RELAY_SESSION", fallbackPane)
	for _, stderr := range []string{
		"relayd: a pane has no verified native communication endpoint",
		"relayd: message identity conflicts with a previous request",
		"relayd: registered caller credential required",
	} {
		s, _ := fallbackHelper(t, 1, "", stderr)
		if _, handled := s.daemonCommunication("relay_message_pane", messageArgs()); !handled {
			t.Fatal("a failure after possible delivery fell back and could duplicate", stderr)
		}
	}
}

func TestCommunicationListAndForeignRecordsUseDesktopPath(t *testing.T) {
	t.Setenv("RELAY_SESSION", fallbackPane)
	s, wire := fallbackHelper(t, 0, `{"links":[]}`, "")
	if _, handled := s.daemonCommunication("relay_list_pane_links", map[string]json.RawMessage{}); handled {
		t.Fatal("link list hid desktop links")
	}
	if _, err := os.Stat(wire); !os.IsNotExist(err) {
		t.Fatal("list reached the node daemon")
	}
	receipt := map[string]json.RawMessage{}
	receipt["message_id"], _ = json.Marshal("0c9d4e6b-7a21-4f83-b5e9-2d8f1a6c3e57")
	s, _ = fallbackHelper(t, 0, `{"status":"unknown","replay_permitted":false}`, "")
	if _, handled := s.daemonCommunication("relay_pane_message_receipt", receipt); handled {
		t.Fatal("unknown node receipt hid a desktop receipt")
	}
	s, _ = fallbackHelper(t, 0, `{"status":"written_to_socket"}`, "")
	if _, handled := s.daemonCommunication("relay_pane_message_receipt", receipt); !handled {
		t.Fatal("node receipt not returned")
	}
	unlink := map[string]json.RawMessage{}
	unlink["link_id"], _ = json.Marshal("ab")
	s, _ = fallbackHelper(t, 0, `{"status":"not_found","prior_removal":"unknown"}`, "")
	if _, handled := s.daemonCommunication("relay_unlink_panes", unlink); handled {
		t.Fatal("desktop link could not be retired")
	}
}

func TestCommunicationFailedActorProofUsesDesktopPathOnlyWithDesktop(t *testing.T) {
	t.Setenv("RELAY_SESSION", fallbackPane)
	s, wire := fallbackHelper(t, 0, `{}`, "")
	s.daemonHelper = filepath.Join(t.TempDir(), "missing-helper")
	if _, handled := s.daemonCommunication("relay_message_pane", messageArgs()); handled {
		t.Fatal("unproven caller did not fall back to the unverified desktop path")
	}
	s.token = ""
	if _, handled := s.daemonCommunication("relay_message_pane", messageArgs()); !handled {
		t.Fatal("node-only client lost its explicit proof error")
	}
	if _, err := os.Stat(wire); !os.IsNotExist(err) {
		t.Fatal("unproven caller reached delivery")
	}
}

func TestCommunicationCrossHostLinkFallbackCarriesProvenSender(t *testing.T) {
	t.Setenv("RELAY_SESSION", fallbackPane)
	s, _ := fallbackHelper(t, 1, "", "both panes must belong to this daemon; remote peers require a server route")
	link := map[string]json.RawMessage{}
	link["pane_id"], _ = json.Marshal("129286a2-6e69-4d1a-9c83-91a0a2dec1e9")
	if _, handled := s.daemonCommunication("relay_link_panes", link); handled {
		t.Fatal("cross-host link did not reach the desktop broker")
	}
	var source string
	if json.Unmarshal(link["source_pane_id"], &source) != nil || source != fallbackPane {
		t.Fatal("desktop link lost the kernel-verified sender", string(link["source_pane_id"]))
	}
	// A refusal after the daemon may have written never falls back or rewrites.
	s, _ = fallbackHelper(t, 1, "", "native communication adapter failed")
	send := messageArgs()
	if _, handled := s.daemonCommunication("relay_message_pane", send); !handled {
		t.Fatal("ambiguous daemon send fell back to a second delivery path")
	}
	// Without a proven actor the desktop path keeps the caller's own label.
	t.Setenv("RELAY_SESSION", "")
	s, _ = fallbackHelper(t, 1, "", "both panes must belong to this daemon; remote peers require a server route")
	s.daemonHelper = nativeFixtureWithoutActor(t, s.daemonHelper)
	link = map[string]json.RawMessage{}
	link["pane_id"], _ = json.Marshal("129286a2-6e69-4d1a-9c83-91a0a2dec1e9")
	if _, handled := s.daemonCommunication("relay_link_panes", link); handled {
		t.Fatal("unproven cross-host link did not reach the desktop broker")
	}
	if _, ok := link["source_pane_id"]; ok {
		t.Fatal("desktop link invented a sender without kernel proof")
	}
}

// attestHelper declines the send as cross-host and answers attest with reply.
func attestHelper(t *testing.T, reply string) (server, string) {
	t.Helper()
	wire := filepath.Join(t.TempDir(), "attest.json")
	helper := nativeMCPFixture(t, nativeFixtureConfig{Pane: fallbackPane, Wire: wire,
		Default:    nativeFixtureReply{Error: "relayd: save the communication pair on this daemon before sending", Exit: 1},
		Operations: map[string]nativeFixtureReply{"attest": {Out: reply, Record: true}}})
	return server{daemonHelper: helper, callerToken: "fixture-caller", token: "fixture-desktop"}, wire
}

func TestCommunicationCrossHostSendCarriesSourceAttestation(t *testing.T) {
	t.Setenv("RELAY_SESSION", fallbackPane)
	id := "0123456789abcdef0123456789abcdef"
	s, wire := attestHelper(t, `{"attestation_id":"`+id+`","authority":"relayd"}`)
	args := messageArgs()
	if _, handled := s.daemonCommunication("relay_message_pane", args); handled {
		t.Fatal("cross-host send did not fall back")
	}
	var got string
	if json.Unmarshal(args["source_attestation"], &got) != nil || got != id {
		t.Fatalf("attestation = %s", args["source_attestation"])
	}
	data, err := os.ReadFile(wire)
	if err != nil {
		t.Fatal(err)
	}
	var packet map[string]any
	_ = json.Unmarshal(data, &packet)
	if packet["actor_pane_id"] != fallbackPane || packet["source_pane_id"] != fallbackPane || packet["client_token"] != "fixture-caller" ||
		packet["text"] != "fixture only" || packet["message_id"] != "0c9d4e6b-7a21-4f83-b5e9-2d8f1a6c3e57" {
		t.Fatalf("attest packet = %v", packet)
	}

	// A refused or malformed mint still sends, honestly unverified.
	for _, reply := range []string{`{"attestation_id":"../link"}`, `not json`} {
		s, _ = attestHelper(t, reply)
		args = messageArgs()
		if _, handled := s.daemonCommunication("relay_message_pane", args); handled {
			t.Fatal("send did not fall back")
		}
		if _, ok := args["source_attestation"]; ok {
			t.Fatalf("invalid mint %q was carried", reply)
		}
	}

	// A client never supplies its own proof.
	args = messageArgs()
	args["source_attestation"], _ = json.Marshal(id)
	if result, handled := s.daemonCommunication("relay_message_pane", args); !handled || !result.(map[string]any)["isError"].(bool) {
		t.Fatal("a client-supplied attestation was accepted")
	}
}

func TestCommunicationTargetSessionGoesToTheDaemonAndNeverFallsBack(t *testing.T) {
	t.Setenv("RELAY_SESSION", fallbackPane)
	target := "5577ee9d-5e02-4ca8-b208-74360e3f65d1"
	args := messageArgs()
	args["target_session_id"], _ = json.Marshal(target)
	s, wire := fallbackHelper(t, 0, `{"status":"written_to_socket","target_session_id":"`+target+`"}`, "")
	if _, handled := s.daemonCommunication("relay_message_pane", args); !handled {
		t.Fatal("targeted send left the daemon path")
	}
	data, _ := os.ReadFile(wire)
	var packet map[string]any
	_ = json.Unmarshal(data, &packet)
	if packet["target_session_id"] != target || packet["operation"] != "send" {
		t.Fatal("target session not forwarded to relayd", packet)
	}
	// A cross-host pair cannot carry a target over the desktop route.
	s, _ = fallbackHelper(t, 1, "", "relayd: save the communication pair on this daemon before sending")
	result, handled := s.daemonCommunication("relay_message_pane", args)
	if !handled || !result.(map[string]any)["isError"].(bool) ||
		!strings.Contains(fmt.Sprint(result), "desktop route cannot address a session") {
		t.Fatal("targeted send fell back to the desktop route", result)
	}
	link := map[string]json.RawMessage{"pane_id": args["pane_id"], "target_session_id": args["target_session_id"]}
	if result, handled := s.daemonCommunication("relay_link_panes", link); !handled || !result.(map[string]any)["isError"].(bool) {
		t.Fatal("target session accepted outside relay_message_pane", result)
	}
}
