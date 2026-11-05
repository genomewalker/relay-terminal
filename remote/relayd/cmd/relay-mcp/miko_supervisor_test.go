package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A fake relayd: the actor is the given pane; "communication" records the
// attest packet and returns a fixed attestation id.
func mikoHelper(t *testing.T, pane string) (string, string) {
	t.Helper()
	wire := filepath.Join(t.TempDir(), "attest.json")
	return nativeMCPFixture(t, nativeFixtureConfig{Pane: pane, Wire: wire, Default: nativeFixtureReply{Out: `{"attestation_id":"0123456789abcdef0123456789abcdef"}`, Record: true}}), wire
}

func TestMikoSupervisorToolsAreListedWithReadOnlyHints(t *testing.T) {
	want := map[string]bool{"relay_miko_transcript": false, "relay_miko_state": false, "relay_miko_configuration": false,
		"relay_miko_audit": false, "relay_miko_turn": true, "relay_miko_card": true, "relay_miko_set_instructions": true,
		"relay_miko_set_memory": true, "relay_miko_set_capabilities": true, "relay_miko_revert": true}
	for _, raw := range mikoSupervisorTools() {
		definition := raw.(map[string]any)
		name := definition["name"].(string)
		mutation, ok := want[name]
		if !ok {
			t.Fatalf("unexpected tool %s", name)
		}
		if readOnly := definition["annotations"].(map[string]any)["readOnlyHint"].(bool); readOnly == mutation {
			t.Fatalf("%s readOnlyHint=%v", name, readOnly)
		}
		delete(want, name)
	}
	if len(want) != 0 {
		t.Fatalf("missing %v", want)
	}
}

func TestMikoSupervisorCallNeedsTheVerifiedPaneClient(t *testing.T) {
	result := (&server{}).mikoSupervisorCall("relay_miko_state", nil)
	if result["isError"] != true || !strings.Contains(fmt.Sprint(result), "daemon backend") {
		t.Fatal(result)
	}
}

// The call is proven for exactly this pane and these argument bytes, and the
// desktop receives the same bytes the proof hashes.
func TestMikoSupervisorCallBindsItsProofToThePaneAndArguments(t *testing.T) {
	pane := "cbf0ccc8-ce1e-4708-ba5c-809b60a289e6"
	helper, wire := mikoHelper(t, pane)
	var received map[string]string
	desktop := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if r.URL.Path != "/api/miko/supervisor" || r.Method != "POST" || json.Unmarshal(body, &received) != nil {
			w.WriteHeader(400)
			return
		}
		w.Write([]byte(`{"status":"ok"}`))
	}))
	defer desktop.Close()
	s := &server{daemonHelper: helper, callerToken: "fixture-caller", token: "fixture-token", endpoint: desktop.URL, client: desktop.Client()}
	text, _ := json.Marshal("Which panes are held?")
	result := s.mikoSupervisorCall("relay_miko_turn", map[string]json.RawMessage{"text": text})
	if result["isError"] != false {
		t.Fatal(result)
	}
	data, err := os.ReadFile(wire)
	if err != nil {
		t.Fatal(err)
	}
	var attest map[string]any
	_ = json.Unmarshal(data, &attest)
	if attest["operation"] != "attest" || attest["source_pane_id"] != pane || attest["actor_pane_id"] != pane ||
		attest["pane_id"] != mikoInboxID || attest["client_token"] != "fixture-caller" {
		t.Fatal("attestation packet", attest)
	}
	if received["supervisor_pane_id"] != pane || received["attestation_id"] != "0123456789abcdef0123456789abcdef" ||
		received["request_id"] != attest["message_id"] || received["tool"] != "relay_miko_turn" {
		t.Fatal("desktop request", received)
	}
	if attest["text"] != mikoCanonicalText("relay_miko_turn", received["arguments"]) ||
		received["arguments"] != `{"text":"Which panes are held?"}` {
		t.Fatal("proof is not bound to the forwarded arguments", attest["text"], received["arguments"])
	}
}

func TestMikoSupervisorCanonicalTextMatchesTheDesktop(t *testing.T) {
	// Pinned by RelayMikoSupervisorTests.canonicalTextMatchesRelayMCP.
	got := mikoCanonicalText("relay_miko_state", "{}")
	if got != "relay-miko-supervisor-v1\nrelay_miko_state\n44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a" {
		t.Fatal(got)
	}
}
