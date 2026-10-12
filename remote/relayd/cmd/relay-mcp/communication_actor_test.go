package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func actorTestHelper(t *testing.T, pane string, clientPID int) (server, string) {
	t.Helper()
	dir := t.TempDir()
	helper := filepath.Join(dir, "helper.py")
	wire := filepath.Join(dir, "wire.json")
	script := fmt.Sprintf("#!/usr/bin/env python3\nimport sys,json\nif sys.argv[1]=='communication-actor':\n print(json.dumps({'version':1,'pane_id':%q,'client_pid':%d,'client_start':'current','source':'native_parked_job_kernel_owner'}))\nelse:\n p=json.load(sys.stdin)\n with open(%q,'w') as f:json.dump(p,f)\n print(json.dumps({'status':'fixture_only'}))\n", pane, clientPID, wire)
	if err := os.WriteFile(helper, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
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
