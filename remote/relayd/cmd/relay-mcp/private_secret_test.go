package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
)

func TestPrivateSecretRequestProvesExactArgumentsAndPane(t *testing.T) {
	pane := "cbf0ccc8-ce1e-4708-ba5c-809b60a289e6"
	helper, wire := mikoHelper(t, pane)
	var received map[string]string
	desktop := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if r.Method != "POST" || r.URL.Path != "/api/private-secret/request" || json.Unmarshal(body, &received) != nil {
			w.WriteHeader(400)
			return
		}
		_, _ = w.Write([]byte(`{"status":"awaiting_approval"}`))
	}))
	defer desktop.Close()
	s := &server{daemonHelper: helper, token: "fixture-token", endpoint: desktop.URL, client: desktop.Client()}
	args := map[string]any{"instance": askInstance, "request_id": askRequest, "account_id": "0123456789abcdef0123456789abcdef", "credential_reference": "1123456789abcdef0123456789abcdef", "purpose": "Save API key"}
	params, _ := json.Marshal(map[string]any{"name": "relay_request_secret", "arguments": args})
	result, code, _ := s.handle(request{Method: "tools/call", Params: params})
	if code != 0 || result.(map[string]any)["isError"] != false {
		t.Fatal(code, result)
	}
	data, err := os.ReadFile(wire)
	if err != nil {
		t.Fatal(err)
	}
	var packet map[string]any
	if err = json.Unmarshal(data, &packet); err != nil {
		t.Fatal(err)
	}
	if packet["source_pane_id"] != pane || packet["pane_id"] != privateSecretInboxID || packet["message_id"] != askRequest || packet["text"] != privateSecretCanonical("relay_request_secret", received["arguments"]) {
		t.Fatal("proof did not bind source and request")
	}
	args["purpose"] = "spoof\nrequest"
	params, _ = json.Marshal(map[string]any{"name": "relay_request_secret", "arguments": args})
	_, code, _ = s.handle(request{Method: "tools/call", Params: params})
	if code != -32602 {
		t.Fatal("invalid purpose accepted")
	}
}

func TestPrivateSecretCanonicalCrossLanguageVector(t *testing.T) {
	want := "relay-private-secret/v1\nrelay_request_secret\n44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
	if got := privateSecretCanonical("relay_request_secret", "{}"); got != want {
		t.Fatalf("canonical mismatch: %s", got)
	}
}

func TestPrivateSecretReceiptIsProvenAndCarriesNoSecret(t *testing.T) {
	pane := "cbf0ccc8-ce1e-4708-ba5c-809b60a289e6"
	helper, wire := mikoHelper(t, pane)
	var body map[string]string
	serverHTTP := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&body)
		_, _ = w.Write([]byte(`{"status":"completed"}`))
	}))
	defer serverHTTP.Close()
	s := &server{daemonHelper: helper, token: "fixture-token", endpoint: serverHTTP.URL, client: serverHTTP.Client()}
	params, _ := json.Marshal(map[string]any{"name": "relay_secret_receipt", "arguments": map[string]any{"instance": askInstance, "request_id": askRequest}})
	result, code, _ := s.handle(request{Method: "tools/call", Params: params})
	if code != 0 || result.(map[string]any)["isError"] != false {
		t.Fatal(code, result)
	}
	raw, err := os.ReadFile(wire)
	if err != nil {
		t.Fatal(err)
	}
	var proof map[string]any
	_ = json.Unmarshal(raw, &proof)
	if proof["text"] != privateSecretCanonical("relay_secret_receipt", body["arguments"]) || body["source_pane_id"] != pane {
		t.Fatal("receipt proof not bound")
	}
	if _, found := body["secret"]; found {
		t.Fatal("unexpected secret field")
	}
}
