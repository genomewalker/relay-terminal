package daemon

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/nativemsg"
)

func TestShepherdProviderEnvelopeAndNativeFormatting(t *testing.T) {
	source := map[string]any{"authentication": "relay_assistant_owner_submitted", "principal": "relay-assistant", "name": "Miko (Relay assistant)", "hostID": "fixture-host", "assistantRequestID": "req-1", "replyPaneID": "a5515700-0000-4000-8000-00000000b0c5", "reportKind": "shepherd"}
	text := communicationShepherdPrefix + "\nstate changed"
	got, err := nativemsg.ShepherdReportBody(source, text, "Owner provenance\n"+text)
	if err != nil || !strings.HasPrefix(got, communicationShepherdPrefix+"\n") || !strings.HasSuffix(got, "state changed") {
		t.Fatal("SH36/SH46 native production report envelope", got, err)
	}
}

func shepherdRequestFixture(t *testing.T) (string, CommunicationRequest, *[]map[string]any, communicationGroupNative) {
	t.Helper()
	root, here, target, sent, native := assistantFixture(t)
	saveAssistantLink(t, root, here, target)
	id, _, _ := communicationPair(here, target)
	var link communicationLink
	if err := communicationRead(root+"/link-"+id+".json", &link); err != nil {
		t.Fatal(err)
	}
	link.UpdatedAt = time.Unix(123, 0).UTC()
	if err := communicationAtomic(root+"/link-"+id+".json", link); err != nil {
		t.Fatal(err)
	}
	r := assistantRequest(here, target)
	r.ShepherdReport = true
	r.Text = communicationShepherdPrefix + "\nOwner/Miko-submitted shepherd.\nstate changed"
	r.ExpectedLinkRevision = link.UpdatedAt.Format(time.RFC3339Nano)
	return root, r, sent, native
}

func TestShepherdOwnerSenderAndPinnedLink(t *testing.T) {
	root, r, sent, native := shepherdRequestFixture(t)
	bad := r
	bad.ExpectedLinkRevision = "changed"
	if _, err := communicationAssistantSend(root, "node", bad, native); err == nil || len(*sent) != 0 {
		t.Fatal("SH37 stale link dispatched")
	}
	bad = r
	bad.Text = "report without collaborator prefix"
	if _, err := communicationAssistantSend(root, "node", bad, native); err == nil {
		t.Fatal("SH36 unlabelled report accepted")
	}
	for _, credential := range []string{"pane", "mcp"} {
		bad = r
		if credential == "pane" {
			bad.ActorPaneID = r.SourcePaneID
		} else {
			bad.ClientToken = "agent-token"
		}
		if _, err := communicationAssistantSend(root, "node", bad, native); err == nil {
			t.Fatal("SH31 agent credential submitted as owner")
		}
	}
	result, err := communicationAssistantSend(root, "node", r, native)
	if err != nil || len(*sent) != 1 {
		t.Fatalf("send: %v %d", err, len(*sent))
	}
	source := (*sent)[0]["source"].(map[string]any)
	if source["authentication"] != "relay_assistant_owner_submitted" || source["principal"] != "relay-assistant" || source["reportKind"] != "shepherd" {
		t.Fatal("SH36 sender overclaims or is not the Miko owner principal", source)
	}
	for _, key := range []string{"paneID", "sessionID", "approval", "keyFingerprint"} {
		if source[key] != nil {
			t.Fatal("SH36 attestation claim", key)
		}
	}
	if result["status"] != "written_to_socket" || result["replay_permitted"] != false {
		t.Fatal("receipt semantics", result)
	}
	if _, err := communicationAssistantSend(root, "node", r, native); err != nil || len(*sent) != 1 {
		t.Fatal("SH33 UUID replayed", err)
	}
}

func TestShepherdWireBoundaries(t *testing.T) {
	_, r, _, _ := shepherdRequestFixture(t)
	data, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeCommunicationRequest(bytes.NewReader(data))
	if err != nil || decoded.PaneID != r.PaneID || decoded.MessageID != r.MessageID || decoded.SourcePaneID != r.SourcePaneID {
		t.Fatal("SH38 exact ID roundtrip", err)
	}
	for i := 0; i < len(data); i++ {
		if _, err := DecodeCommunicationRequest(bytes.NewReader(data[:i])); err == nil {
			t.Fatalf("SH38 truncated prefix %d accepted", i)
		}
	}
	for _, bad := range [][]byte{append(append([]byte{}, data...), []byte(" {}")...), []byte(strings.Replace(string(data), "{", "{\"unexpected\":1,", 1)), []byte(strings.Replace(string(data), "\"expected_recipient\":{", "\"expected_recipient\":{\"unexpected\":1,", 1)), bytes.Repeat([]byte(" "), 65537)} {
		if _, err := DecodeCommunicationRequest(bytes.NewReader(bad)); err == nil {
			t.Fatal("SH38 extra/trailing/oversize accepted")
		}
	}
}

func FuzzShepherdCommunicationEnvelope(f *testing.F) {
	r := CommunicationRequest{Operation: "assistant_send", ShepherdReport: true, SourcePaneID: "11111111-1111-4111-8111-111111111111", PaneID: "22222222-2222-4222-8222-222222222222", MessageID: "33333333-3333-4333-8333-333333333333", Text: communicationShepherdPrefix + "\nchanged", ExpectedLinkRevision: "1970-01-01T00:02:03Z"}
	seed, _ := json.Marshal(r)
	f.Add(seed)
	upper := r
	upper.PaneID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
	upperSeed, _ := json.Marshal(upper)
	f.Add(upperSeed)
	f.Add([]byte("{"))
	f.Add([]byte(`{"shepherd_report":true,"unknown":1}`))
	f.Fuzz(func(t *testing.T, data []byte) {
		got, err := DecodeCommunicationRequest(bytes.NewReader(data))
		if err != nil {
			return
		}
		if len(data) > 65536 {
			t.Fatal("SH38 allocation/input bound")
		}
		var original map[string]any
		if json.Unmarshal(data, &original) == nil {
			for key, decoded := range map[string]string{"pane_id": got.PaneID, "source_pane_id": got.SourcePaneID, "message_id": got.MessageID} {
				if input, ok := original[key].(string); ok && input != decoded {
					t.Fatal("SH45 input ID changed", key)
				}
			}
		}
		encoded, err := json.Marshal(got)
		if err != nil {
			t.Fatal(err)
		}
		again, err := DecodeCommunicationRequest(bytes.NewReader(encoded))
		if err != nil || again.PaneID != got.PaneID || again.SourcePaneID != got.SourcePaneID || again.MessageID != got.MessageID {
			t.Fatal("SH38 ID round trip", err)
		}
		if got.ShepherdReport {
			var obj map[string]json.RawMessage
			_ = json.Unmarshal(encoded, &obj)
			obj["unexpected"] = json.RawMessage(`1`)
			bad, _ := json.Marshal(obj)
			if _, err := DecodeCommunicationRequest(bytes.NewReader(bad)); err == nil {
				t.Fatal("SH38 unknown field accepted")
			}
			if len(encoded) > 0 {
				if _, err := DecodeCommunicationRequest(bytes.NewReader(encoded[:len(encoded)-1])); err == nil {
					t.Fatal("SH38 truncation accepted")
				}
			}
		}
	})
}
