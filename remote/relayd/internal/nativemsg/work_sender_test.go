package nativemsg

import (
	"strings"
	"testing"
)

func TestWorkSenderHasDistinctProvenanceAndCannotAssertPaneOrBypass(t *testing.T) {
	source := map[string]any{"authentication": "source_work_host_attested", "workThread": "44444444-4444-4444-8444-444444444444", "hostID": "node-a", "linkID": strings.Repeat("a", 64), "nodeCertificateSHA256": strings.Repeat("b", 64)}
	got, e := verifiedSender(source)
	if e != nil || got == nil || !got.work || got.pane != "" || got.mode != "prompting" {
		t.Fatal(got, e)
	}
	for _, key := range []string{"paneID", "sessionID", "permissionClass", "socketPath", "provider"} {
		source[key] = "forged"
		got, e = verifiedSender(source)
		if e != nil || got != nil {
			t.Fatal("Work claimed pane/bypass", key, got, e)
		}
		delete(source, key)
	}
	source["workThread"] = "forged"
	if got, e = verifiedSender(source); e != nil || got != nil {
		t.Fatal("invalid thread", got, e)
	}
}
