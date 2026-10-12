package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

const fallbackPane = "cbf0ccc8-ce1e-4708-ba5c-809b60a289e6"

// fallbackHelper proves fallbackPane for this process and answers the
// communication operation with the given exit code, stdout and stderr.
func fallbackHelper(t *testing.T, exit int, stdout, stderr string) (server, string) {
	t.Helper()
	dir := t.TempDir()
	helper := filepath.Join(dir, "helper.py")
	wire := filepath.Join(dir, "wire.json")
	script := fmt.Sprintf("#!/usr/bin/env python3\nimport sys,json\n"+
		"if sys.argv[1]=='communication-actor':\n print(json.dumps({'version':1,'pane_id':%q,'client_pid':%d,'client_start':'current','source':'foreground_worker_kernel_ancestry'}))\n"+
		"else:\n p=json.load(sys.stdin)\n open(%q,'w').write(json.dumps(p))\n sys.stdout.write(%q)\n sys.stderr.write(%q)\n sys.exit(%d)\n",
		fallbackPane, os.Getpid(), wire, stdout, stderr, exit)
	if err := os.WriteFile(helper, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
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
