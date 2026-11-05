package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// proofHelper proves fallbackPane (unless actorFails), declines the send as
// cross-host, and refuses both attest and sign with the given stderr.
func proofHelper(t *testing.T, actorFails bool, refusal string) server {
	t.Helper()
	helper := nativeMCPFixture(t, nativeFixtureConfig{Pane: fallbackPane, ActorFails: actorFails,
		Default:    nativeFixtureReply{Error: "relayd: save the communication pair on this daemon before sending", Exit: 1},
		Operations: map[string]nativeFixtureReply{"attest": {Error: refusal, Exit: 1}, "sign": {Error: refusal, Exit: 1}}})
	return server{daemonHelper: helper, callerToken: "fixture-caller", token: "fixture-desktop"}
}

func proofError(t *testing.T, args map[string]json.RawMessage) string {
	t.Helper()
	var text string
	if raw, ok := args["source_proof_error"]; !ok || json.Unmarshal(raw, &text) != nil {
		t.Fatalf("no source_proof_error in %v", args)
	}
	return text
}

func TestCommunicationFailedProofIsReportedNotHidden(t *testing.T) {
	t.Setenv("RELAY_SESSION", fallbackPane)
	s := proofHelper(t, false, "relayd: unknown daemon communication operation\n")
	args := messageArgs()
	if _, handled := s.daemonCommunication("relay_message_pane", args); handled {
		t.Fatal("cross-host send did not fall back")
	}
	if _, ok := args["source_attestation"]; ok {
		t.Fatal("a refused attestation was carried")
	}
	got := proofError(t, args)
	if !strings.Contains(got, "attest: relayd: unknown daemon communication operation") || !strings.Contains(got, "sign: relayd:") ||
		strings.ContainsAny(got, "\n\r") {
		t.Fatalf("source_proof_error = %q", got)
	}
}

func TestCommunicationUnprovenActorIsReported(t *testing.T) {
	for _, session := range []string{fallbackPane, ""} {
		t.Setenv("RELAY_SESSION", session)
		s := proofHelper(t, true, "unused")
		args := messageArgs()
		if _, handled := s.daemonCommunication("relay_message_pane", args); handled {
			t.Fatal("send did not fall back")
		}
		if got := proofError(t, args); !strings.HasPrefix(got, "communication-actor: ") {
			t.Fatalf("RELAY_SESSION=%q source_proof_error = %q", session, got)
		}
	}
}

func TestCommunicationSuccessfulProofCarriesNoError(t *testing.T) {
	t.Setenv("RELAY_SESSION", fallbackPane)
	s, _ := signHelper(t, `{"source_signature":"`+fixtureSignature+`","authority":"relayd"}`, 0)
	args := messageArgs()
	if _, handled := s.daemonCommunication("relay_message_pane", args); handled {
		t.Fatal("cross-host send did not fall back")
	}
	if _, ok := args["source_proof_error"]; ok {
		t.Fatal("a minted proof was reported as failed")
	}
}

func TestCommunicationClientSuppliedProofErrorIsRejected(t *testing.T) {
	t.Setenv("RELAY_SESSION", fallbackPane)
	s := proofHelper(t, false, "x")
	args := messageArgs()
	args["source_proof_error"], _ = json.Marshal("attest: fine")
	result, handled := s.daemonCommunication("relay_message_pane", args)
	if !handled || !result.(map[string]any)["isError"].(bool) {
		t.Fatal("a client-supplied proof diagnostic was accepted")
	}
}

func TestMessageToolForwardsProofErrorOnlyFromDaemonBackend(t *testing.T) {
	t.Setenv("RELAY_SESSION", fallbackPane)
	var body map[string]string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(data, &body)
		w.Write([]byte(`{"status":"rejected_unverified_source"}`))
	}))
	defer ts.Close()
	s := proofHelper(t, false, "relayd: source attestation requires the kernel-verified caller pane")
	s.endpoint, s.client = ts.URL, ts.Client()
	params, _ := json.Marshal(map[string]any{"name": "relay_message_pane", "arguments": map[string]string{
		"source_pane_id": fallbackPane, "pane_id": "129286a2-6e69-4d1a-9c83-91a0a2dec1e9",
		"message_id": "0c9d4e6b-7a21-4f83-b5e9-2d8f1a6c3e57", "text": "fixture only"}})
	if _, code, msg := s.handle(request{Method: "tools/call", Params: params}); code != 0 {
		t.Fatal(code, msg)
	}
	if !strings.Contains(body["sourceProofError"], "kernel-verified caller pane") || body["sourceAttestation"] != "" ||
		body["sourcePaneID"] != fallbackPane {
		t.Fatalf("desktop body = %v", body)
	}

	plain := server{token: "fixture-desktop", endpoint: ts.URL, client: ts.Client()}
	params, _ = json.Marshal(map[string]any{"name": "relay_message_pane", "arguments": map[string]string{
		"source_pane_id": fallbackPane, "pane_id": "129286a2-6e69-4d1a-9c83-91a0a2dec1e9",
		"message_id": "0c9d4e6b-7a21-4f83-b5e9-2d8f1a6c3e57", "text": "fixture only", "source_proof_error": "attest: fine"}})
	if _, code, _ := plain.handle(request{Method: "tools/call", Params: params}); code != -32602 {
		t.Fatalf("a client-supplied proof diagnostic reached the desktop: code %d", code)
	}
}

func TestProofDiagnosticIsBoundedSingleLine(t *testing.T) {
	got := proofDiagnostic("attest", strings.Repeat("é\n", 400))
	if len(got) > 240 || strings.ContainsAny(got, "\n\r") || !strings.HasPrefix(got, "attest: ") {
		t.Fatalf("diagnostic = %q", got)
	}
	if got := proofDiagnostic("sign", ""); got != "sign: failed" {
		t.Fatalf("empty diagnostic = %q", got)
	}
}
