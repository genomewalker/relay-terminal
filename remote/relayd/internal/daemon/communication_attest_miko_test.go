package daemon

import "testing"

// The Miko supervisor channel reuses the source attestation unchanged: target
// Miko's reserved inbox, message id = the call's request id, text = the call's
// canonical text. One proof answers exactly one call, once.
func TestCommunicationAttestBindsAMikoSupervisorCall(t *testing.T) {
	withSenderPermissionClass(t, "bypass")
	f := newAttestFixture(t)
	canonical := "relay-miko-supervisor-v1\nrelay_miko_state\n44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
	request := attestRequest()
	request.PaneID, request.Text = communicationAssistantInboxID, canonical
	minted, err := communicationAttest(f.root, "node-a", request, f.deps)
	if err != nil {
		t.Fatal(err)
	}
	id := minted["attestation_id"].(string)
	consume := consumeRequest(id)
	consume.PaneID = communicationAssistantInboxID
	// Another tool or other arguments are not this proof.
	consume.Text = "relay-miko-supervisor-v1\nrelay_miko_set_instructions\n" + communicationTextDigest("{}")
	if _, err := communicationAttestConsume(f.root, consume, f.deps); err == nil {
		t.Fatal("a proof for one call answered another")
	}
	consume.Text = canonical
	result, err := communicationAttestConsume(f.root, consume, f.deps)
	if err != nil {
		t.Fatal(err)
	}
	if source := result["source"].(map[string]any); source["paneID"] != sourceFixturePane ||
		source["authentication"] != "source_host_attested" {
		t.Fatal(result)
	}
	if _, err := communicationAttestConsume(f.root, consume, f.deps); err == nil {
		t.Fatal("a supervisor proof was spent twice")
	}
}
