package remotemcpbridge

import (
	"encoding/json"
	"testing"
)

// Property: an accepted Miko request has an argument string with no duplicate
// keys, so the bridge and the Mac read the same logical request id, and the
// accepted id is the canonical lowercase form of the one in the arguments.
func FuzzParseMiko(f *testing.F) {
	f.Add("relay_ask_miko", paneA, `{"instance":"`+inst+`","request_id":"`+lid(1)+`","text":"x"}`)
	f.Add("relay_miko_receipt", paneA, `{"instance":"`+inst+`","request_id":"`+lid(1)+`"}`)
	f.Add("relay_ask_miko", paneA, `{"instance":"`+inst+`","request_id":"`+lid(1)+`","request_id":"`+lid(2)+`","text":"x"}`)
	f.Fuzz(func(t *testing.T, tool, pane, args string) {
		obj := map[string]any{"tool": tool, "request_id": lid(900), "attestation_id": attA, "supervisor_pane_id": pane, "arguments": args}
		c, status, _ := parseMiko(obj, map[string]bool{paneA: true})
		if status != 0 {
			return
		}
		if hasDuplicateKeys([]byte(args)) || c.pane != paneA {
			t.Fatalf("accepted unsafe request %q", args)
		}
		var parsed map[string]json.RawMessage
		if json.Unmarshal([]byte(args), &parsed) != nil {
			t.Fatal("accepted undecodable arguments")
		}
		var id string
		_ = json.Unmarshal(parsed["request_id"], &id)
		if lower(id) != c.logical || !strictUUID.MatchString(c.logical) {
			t.Fatalf("logical id mismatch %q %q", id, c.logical)
		}
	})
}
