package daemon

import (
	"encoding/json"
	"testing"
)

// The desktop rejects a "captured" reply without text. Restoring a saved draft
// first snapshots the (now empty) prompt, so an omitted empty text held panes
// 111342dc and ddb6ab25 with "The prompt editor response could not be verified".
func TestPromptEditorCapturedReplyAlwaysCarriesText(t *testing.T) {
	for _, text := range [][]byte{nil, {}} {
		raw, err := json.Marshal(promptEditorResponse{State: "captured", ID: "a", Digest: "d", Text: text})
		if err != nil {
			t.Fatal(err)
		}
		var fields map[string]json.RawMessage
		if err := json.Unmarshal(raw, &fields); err != nil {
			t.Fatal(err)
		}
		if string(fields["text"]) != `""` || string(fields["state"]) != `"captured"` ||
			string(fields["id"]) != `"a"` || string(fields["digest"]) != `"d"` {
			t.Fatalf("empty capture lost its text or fields: %s", raw)
		}
	}
	raw, err := json.Marshal(promptEditorResponse{State: "captured", ID: "a", Text: []byte("draft")})
	if err != nil {
		t.Fatal(err)
	}
	var decoded promptEditorResponse
	if err := json.Unmarshal(raw, &decoded); err != nil || string(decoded.Text) != "draft" {
		t.Fatalf("captured text did not round-trip: %s", raw)
	}
}

// Every other reply keeps its existing wire form.
func TestPromptEditorOtherRepliesUnchanged(t *testing.T) {
	cases := map[string]promptEditorResponse{
		`{"state":"refused"}`:                                       {State: "refused"},
		`{"state":"armed","id":"a"}`:                                {State: "armed", ID: "a"},
		`{"state":"cancelled","id":"a"}`:                            {State: "cancelled", ID: "a", Text: []byte{}},
		`{"state":"committed","id":"a","text":"eA==","apply":true}`: {State: "committed", ID: "a", Apply: true, Text: []byte("x")},
	}
	for want, response := range cases {
		raw, err := json.Marshal(response)
		if err != nil || string(raw) != want {
			t.Fatalf("got %s, want %s (%v)", raw, want, err)
		}
	}
}
