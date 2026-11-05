package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func actorTestHelper(t *testing.T, pane string, clientPID int) (server, string) {
	t.Helper()
	wire := filepath.Join(t.TempDir(), "wire.json")
	helper := nativeMCPFixture(t, nativeFixtureConfig{Pane: pane, ClientPID: clientPID, Source: "native_parked_job_kernel_owner", Wire: wire, Default: nativeFixtureReply{Out: `{"status":"fixture_only"}`, Record: true}})
	return server{daemonHelper: helper, callerToken: "fixture-caller"}, wire
}

func TestCommunicationUsesNativeParkedPaneInsteadOfBootstrapEnvironment(t *testing.T) {
	actual := "800c06ef-203f-4401-bf7a-c67b15985f33"
	t.Setenv("RELAY_SESSION", "5a30d83a-5222-48f3-93c7-42fa687d901b")
	s, wire := actorTestHelper(t, actual, os.Getpid())
	args := map[string]json.RawMessage{}
	for k, v := range map[string]string{"source_pane_id": actual, "pane_id": "1652a003-70e9-4614-addb-68564fa8383b", "message_id": "fixture-message", "text": "fixture only"} {
		args[k], _ = json.Marshal(v)
	}
	value, handled := s.daemonCommunication("relay_message_pane", args)
	if !handled {
		t.Fatal("not handled")
	}
	data, err := os.ReadFile(wire)
	if err != nil {
		t.Fatal(value, err)
	}
	var packet map[string]any
	_ = json.Unmarshal(data, &packet)
	if packet["actor_pane_id"] != actual || packet["source_pane_id"] != actual || packet["client_token"] != "fixture-caller" {
		t.Fatal("native pane or caller attribution lost", packet)
	}
}

func TestCommunicationStillRejectsAnotherSourceBeforeDelivery(t *testing.T) {
	t.Setenv("RELAY_SESSION", "5a30d83a-5222-48f3-93c7-42fa687d901b")
	s, wire := actorTestHelper(t, "800c06ef-203f-4401-bf7a-c67b15985f33", os.Getpid())
	arg, _ := json.Marshal("5a30d83a-5222-48f3-93c7-42fa687d901b")
	value, _ := s.daemonCommunication("relay_message_pane", map[string]json.RawMessage{"source_pane_id": arg})
	if _, err := os.Stat(wire); !os.IsNotExist(err) {
		t.Fatal("wrong source reached delivery")
	}
	data, _ := json.Marshal(value)
	if !strings.Contains(string(data), "Sender must be this MCP client's own pane") {
		t.Fatal(string(data))
	}
}

func TestCommunicationRejectsActorProofForAnotherClient(t *testing.T) {
	t.Setenv("RELAY_SESSION", "800c06ef-203f-4401-bf7a-c67b15985f33")
	s, wire := actorTestHelper(t, "800c06ef-203f-4401-bf7a-c67b15985f33", os.Getpid()+1)
	value, _ := s.daemonCommunication("relay_message_pane", map[string]json.RawMessage{})
	if _, err := os.Stat(wire); !os.IsNotExist(err) {
		t.Fatal("unrelated client proof reached delivery")
	}
	data, _ := json.Marshal(value)
	if !strings.Contains(string(data), "invalid native caller pane proof") {
		t.Fatal(string(data))
	}
}

func failingActorHelper(t *testing.T) (server, string) {
	t.Helper()
	wire := filepath.Join(t.TempDir(), "wire.json")
	helper := nativeMCPFixture(t, nativeFixtureConfig{ActorFails: true, Wire: wire, Default: nativeFixtureReply{Out: `{"status":"fixture_only"}`, Record: true}})
	return server{daemonHelper: helper, callerToken: "fixture-caller"}, wire
}

func sendArgs(source string) map[string]json.RawMessage {
	args := map[string]json.RawMessage{}
	for k, v := range map[string]string{"source_pane_id": source, "pane_id": "1652a003-70e9-4614-addb-68564fa8383b", "message_id": "fixture-message", "text": "fixture only"} {
		args[k], _ = json.Marshal(v)
	}
	return args
}

func TestCommunicationProvesPaneWithoutSessionEnvironment(t *testing.T) {
	actual := "800c06ef-203f-4401-bf7a-c67b15985f33"
	t.Setenv("RELAY_SESSION", "")
	s, wire := actorTestHelper(t, actual, os.Getpid())
	if _, handled := s.daemonCommunication("relay_message_pane", sendArgs(actual)); !handled {
		t.Fatal("not handled")
	}
	data, err := os.ReadFile(wire)
	if err != nil {
		t.Fatal(err)
	}
	var packet map[string]any
	_ = json.Unmarshal(data, &packet)
	if packet["actor_pane_id"] != actual || packet["source_pane_id"] != actual {
		t.Fatal("kernel-proven pane not carried without RELAY_SESSION", packet)
	}
}

func TestCommunicationWithoutSessionEnvironmentStillPinsSenderToProvenPane(t *testing.T) {
	t.Setenv("RELAY_SESSION", "")
	s, wire := actorTestHelper(t, "800c06ef-203f-4401-bf7a-c67b15985f33", os.Getpid())
	value, _ := s.daemonCommunication("relay_message_pane", sendArgs("5a30d83a-5222-48f3-93c7-42fa687d901b"))
	if _, err := os.Stat(wire); !os.IsNotExist(err) {
		t.Fatal("a claimed label overrode the proven pane")
	}
	data, _ := json.Marshal(value)
	if !strings.Contains(string(data), "Sender must be this MCP client's own pane") {
		t.Fatal(string(data))
	}
}

func TestCommunicationUnownedClientWithoutSessionEnvironmentGetsNoActor(t *testing.T) {
	t.Setenv("RELAY_SESSION", "")
	claimed := "5a30d83a-5222-48f3-93c7-42fa687d901b"
	s, wire := failingActorHelper(t)
	if _, handled := s.daemonCommunication("relay_message_pane", sendArgs(claimed)); !handled {
		t.Fatal("not handled")
	}
	data, err := os.ReadFile(wire)
	if err != nil {
		t.Fatal(err)
	}
	var packet map[string]any
	_ = json.Unmarshal(data, &packet)
	// The label travels only as a claim; relayd never verifies it without an actor.
	if _, ok := packet["actor_pane_id"]; ok || packet["source_pane_id"] != claimed {
		t.Fatal("an unowned client was attributed", packet)
	}
}

func TestCommunicationProofForAnotherClientWithoutSessionEnvironmentGetsNoActor(t *testing.T) {
	t.Setenv("RELAY_SESSION", "")
	s, wire := actorTestHelper(t, "800c06ef-203f-4401-bf7a-c67b15985f33", os.Getpid()+1)
	if _, handled := s.daemonCommunication("relay_message_pane", sendArgs("5a30d83a-5222-48f3-93c7-42fa687d901b")); !handled {
		t.Fatal("not handled")
	}
	data, err := os.ReadFile(wire)
	if err != nil {
		t.Fatal(err)
	}
	var packet map[string]any
	_ = json.Unmarshal(data, &packet)
	if _, ok := packet["actor_pane_id"]; ok {
		t.Fatal("another client's proof was accepted", packet)
	}
}
