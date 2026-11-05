package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
)

const privateSecretInboxID = "a5515700-0000-4000-8000-00000000b0c6"

func privateSecretTools() []any {
	uuid := map[string]string{"type": "string"}
	return []any{
		tool("relay_request_secret", "Request private native input for a Relay rotation API credential. The value goes only to the host credential store, never to the MCP response. Requires a kernel-proven calling pane and explicit native user approval. Retain request_id and query relay_secret_receipt; never retry an unknown request.", map[string]any{"instance": uuid, "request_id": uuid, "account_id": map[string]string{"type": "string"}, "credential_reference": map[string]string{"type": "string"}, "purpose": map[string]any{"type": "string", "maxLength": 160}}, []string{"instance", "request_id", "account_id", "credential_reference", "purpose"}),
		tool("relay_secret_receipt", "Read the result of the original private secret request, only from the same proven pane and session. No secret value is returned.", map[string]any{"instance": uuid, "request_id": uuid}, []string{"instance", "request_id"}),
	}
}
func privateSecretCanonical(name, args string) string {
	digest := sha256.Sum256([]byte(args))
	return "relay-private-secret/v1\n" + name + "\n" + hex.EncodeToString(digest[:])
}
func validPrivateSecretArgs(name string, args map[string]json.RawMessage) bool {
	if name != "relay_request_secret" && name != "relay_secret_receipt" {
		return false
	}
	want := 2
	if name == "relay_request_secret" {
		want = 5
	}
	if len(args) != want {
		return false
	}
	var instance, id string
	if json.Unmarshal(args["instance"], &instance) != nil || !paneID.MatchString(instance) || json.Unmarshal(args["request_id"], &id) != nil || !paneID.MatchString(id) {
		return false
	}
	if name == "relay_secret_receipt" {
		return true
	}
	var account, reference, purpose string
	if json.Unmarshal(args["account_id"], &account) != nil || !attestationID.MatchString(account) || json.Unmarshal(args["credential_reference"], &reference) != nil || !attestationID.MatchString(reference) || json.Unmarshal(args["purpose"], &purpose) != nil || len(purpose) == 0 || len(purpose) > 160 || strings.TrimSpace(purpose) != purpose {
		return false
	}
	for _, r := range purpose {
		if r < 32 || r >= 127 {
			return false
		}
	}
	return true
}
func (s *server) privateSecretCall(name string, args map[string]json.RawMessage) map[string]any {
	if !validPrivateSecretArgs(name, args) {
		return toolText("Invalid private secret request; nothing was sent.", true)
	}
	if s.daemonHelper == "" {
		return toolText("The calling pane cannot be proven; nothing was sent.", true)
	}
	encoded, err := json.Marshal(args)
	if err != nil || len(encoded) > 4096 {
		return toolText("Invalid private request; nothing was sent.", true)
	}
	actor, err := s.communicationActor()
	if err != nil {
		return toolText("Calling pane could not be proven; nothing was sent.", true)
	}
	var id string
	_ = json.Unmarshal(args["request_id"], &id)
	packet := map[string]any{"actor_pane_id": actor, "source_pane_id": actor, "pane_id": privateSecretInboxID, "message_id": id, "text": privateSecretCanonical(name, string(encoded))}
	if s.callerToken != "" {
		packet["client_token"] = s.callerToken
	}
	proof, why := s.sourceAttestation(packet)
	if proof == "" {
		return toolText("Calling pane proof unavailable: "+why+"; nothing was sent.", true)
	}
	body, err := json.Marshal(map[string]string{"tool": name, "request_id": id, "attestation_id": proof, "source_pane_id": actor, "arguments": string(encoded)})
	if err != nil {
		return toolText("Request encoding failed; nothing was sent.", true)
	}
	content, err := s.exchange("POST", "/api/private-secret/request", body)
	if err != nil {
		return toolText(fmt.Sprintf("Private request outcome unavailable (%s); use relay_secret_receipt with the same request_id; do not replay.", id), true)
	}
	return toolText(content, false)
}
