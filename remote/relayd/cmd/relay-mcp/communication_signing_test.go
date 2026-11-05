package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

const fixtureSignature = "eyJ2IjoxfQ-signed_envelope"

// signHelper proves fallbackPane, declines the send as cross-host, and
// answers attest and sign with the given replies, recording the sign packet.
func signHelper(t *testing.T, signReply string, signExit int) (server, string) {
	t.Helper()
	wire := filepath.Join(t.TempDir(), "sign.json")
	helper := nativeMCPFixture(t, nativeFixtureConfig{Pane: fallbackPane, Wire: wire,
		Default: nativeFixtureReply{Error: "relayd: save the communication pair on this daemon before sending", Exit: 1},
		Operations: map[string]nativeFixtureReply{
			"attest": {Out: `{"attestation_id":"0123456789abcdef0123456789abcdef","authority":"relayd"}`},
			"sign":   {Out: signReply, Exit: signExit, Record: true}}})
	return server{daemonHelper: helper, callerToken: "fixture-caller", token: "fixture-desktop"}, wire
}

func TestCommunicationCrossHostSendCarriesSourceSignature(t *testing.T) {
	t.Setenv("RELAY_SESSION", fallbackPane)
	s, wire := signHelper(t, `{"source_signature":"`+fixtureSignature+`","authority":"relayd"}`, 0)
	args := messageArgs()
	if _, handled := s.daemonCommunication("relay_message_pane", args); handled {
		t.Fatal("cross-host send did not fall back")
	}
	var got string
	if json.Unmarshal(args["source_signature"], &got) != nil || got != fixtureSignature {
		t.Fatalf("signature = %s", args["source_signature"])
	}
	if _, ok := args["source_attestation"]; !ok {
		t.Fatal("the attestation for older receivers was dropped")
	}
	data, err := os.ReadFile(wire)
	if err != nil {
		t.Fatal(err)
	}
	var packet map[string]any
	_ = json.Unmarshal(data, &packet)
	if packet["actor_pane_id"] != fallbackPane || packet["source_pane_id"] != fallbackPane || packet["client_token"] != "fixture-caller" ||
		packet["pane_id"] != "129286a2-6e69-4d1a-9c83-91a0a2dec1e9" || packet["text"] != "fixture only" ||
		packet["message_id"] != "0c9d4e6b-7a21-4f83-b5e9-2d8f1a6c3e57" {
		t.Fatalf("sign packet = %v", packet)
	}
}

func TestCommunicationInvalidSignatureIsNeverCarried(t *testing.T) {
	t.Setenv("RELAY_SESSION", fallbackPane)
	for _, c := range []struct {
		reply string
		exit  int
	}{
		{`{"source_signature":"has spaces","authority":"relayd"}`, 0},
		{`{"source_signature":"a/b+c=","authority":"relayd"}`, 0},
		{`{"source_signature":"` + fixtureSignature + `","authority":"desktop"}`, 0},
		{`{"source_signature":"` + fixtureSignature + `"}`, 0},
		{`{"source_signature":""}`, 0},
		{`not json`, 0},
		{`{"source_signature":"` + fixtureSignature + `","authority":"relayd"}`, 1},
	} {
		s, _ := signHelper(t, c.reply, c.exit)
		args := messageArgs()
		if _, handled := s.daemonCommunication("relay_message_pane", args); handled {
			t.Fatal("send did not fall back")
		}
		if _, ok := args["source_signature"]; ok {
			t.Fatalf("invalid signature %q (exit %d) was carried", c.reply, c.exit)
		}
	}
}

func TestCommunicationClientSuppliedSignatureIsRejected(t *testing.T) {
	t.Setenv("RELAY_SESSION", fallbackPane)
	s, wire := signHelper(t, `{"source_signature":"`+fixtureSignature+`","authority":"relayd"}`, 0)
	args := messageArgs()
	args["source_signature"], _ = json.Marshal(fixtureSignature)
	result, handled := s.daemonCommunication("relay_message_pane", args)
	if !handled || !result.(map[string]any)["isError"].(bool) {
		t.Fatal("a client-supplied signature was accepted")
	}
	if _, err := os.Stat(wire); !os.IsNotExist(err) {
		t.Fatal("a rejected request still asked relayd to sign")
	}
}

func TestCommunicationUnprovenCallerIsNeverSigned(t *testing.T) {
	t.Setenv("RELAY_SESSION", "")
	s, wire := signHelper(t, `{"source_signature":"`+fixtureSignature+`","authority":"relayd"}`, 0)
	s.daemonHelper = nativeFixtureWithoutActor(t, s.daemonHelper)
	args := messageArgs()
	if _, handled := s.daemonCommunication("relay_message_pane", args); handled {
		t.Fatal("send did not fall back")
	}
	if _, ok := args["source_signature"]; ok {
		t.Fatal("an unproven caller was signed")
	}
	if _, err := os.Stat(wire); !os.IsNotExist(err) {
		t.Fatal("relayd was asked to sign for an unproven caller")
	}
}

func TestMessageToolForwardsMintedSignatureToDesktop(t *testing.T) {
	t.Setenv("RELAY_SESSION", fallbackPane)
	var body map[string]string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(data, &body)
		w.Write([]byte(`{"status":"accepted_by_provider"}`))
	}))
	defer ts.Close()
	s, _ := signHelper(t, `{"source_signature":"`+fixtureSignature+`","authority":"relayd"}`, 0)
	s.endpoint, s.client = ts.URL, ts.Client()
	params, _ := json.Marshal(map[string]any{"name": "relay_message_pane", "arguments": map[string]string{
		"source_pane_id": fallbackPane, "pane_id": "129286a2-6e69-4d1a-9c83-91a0a2dec1e9",
		"message_id": "0c9d4e6b-7a21-4f83-b5e9-2d8f1a6c3e57", "text": "fixture only"}})
	if _, code, msg := s.handle(request{Method: "tools/call", Params: params}); code != 0 {
		t.Fatal(code, msg)
	}
	if body["sourceSignature"] != fixtureSignature || body["sourceAttestation"] != "0123456789abcdef0123456789abcdef" ||
		body["sourcePaneID"] != fallbackPane {
		t.Fatalf("desktop body = %v", body)
	}

	// Without a daemon backend a signature argument can only be a client's.
	plain := server{token: "fixture-desktop", endpoint: ts.URL, client: ts.Client()}
	params, _ = json.Marshal(map[string]any{"name": "relay_message_pane", "arguments": map[string]string{
		"source_pane_id": fallbackPane, "pane_id": "129286a2-6e69-4d1a-9c83-91a0a2dec1e9",
		"message_id": "0c9d4e6b-7a21-4f83-b5e9-2d8f1a6c3e57", "text": "fixture only", "source_signature": fixtureSignature}})
	if _, code, _ := plain.handle(request{Method: "tools/call", Params: params}); code != -32602 {
		t.Fatalf("a client-supplied signature reached the desktop: code %d", code)
	}
}
