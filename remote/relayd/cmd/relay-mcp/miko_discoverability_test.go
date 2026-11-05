package main

import (
	"strings"
	"testing"
)

// QA-F02: tools/list says where a Miko ask's instance comes from, what to do
// on a stale instance, and that supervisor tools are refused over the bridge.
func TestMikoToolsDescribeInstanceAndBridge(t *testing.T) {
	raw, code, _ := (&server{}).handle(request{Method: "tools/list"})
	if code != 0 {
		t.Fatalf("tools/list failed: %d", code)
	}
	byName := map[string]map[string]any{}
	for _, x := range raw.(map[string]any)["tools"].([]any) {
		entry := x.(map[string]any)
		byName[entry["name"].(string)] = entry
	}
	for _, name := range []string{"relay_ask_miko", "relay_miko_receipt"} {
		entry := byName[name]
		if entry == nil {
			t.Fatalf("%s not listed", name)
		}
		description := entry["description"].(string)
		for _, want := range []string{"current Relay instance UUID from relay_control_info", "changes on every Relay launch", "409 stale-instance"} {
			if !strings.Contains(description, want) {
				t.Fatalf("%s description lacks %q", name, want)
			}
		}
		// Call-specific stale-instance meaning: an ask was not submitted; a
		// receipt lookup says nothing about the original request.
		ask := []string{"rejected before this submission; nothing was asked"}
		receipt := []string{"rejects only this receipt lookup", "outcome remains unknown",
			"reconcile the ORIGINAL request_id", "never resubmit an ambiguous request under a new ID"}
		want, forbidden := ask, receipt
		if name == "relay_miko_receipt" {
			want, forbidden = receipt, ask
		}
		for _, phrase := range want {
			if !strings.Contains(description, phrase) {
				t.Fatalf("%s description lacks %q", name, phrase)
			}
		}
		for _, phrase := range append(forbidden, "nothing was asked") {
			if name == "relay_miko_receipt" && strings.Contains(description, phrase) {
				t.Fatalf("%s wrongly says %q", name, phrase)
			}
			if name == "relay_ask_miko" && phrase != "nothing was asked" && strings.Contains(description, phrase) {
				t.Fatalf("%s wrongly says %q", name, phrase)
			}
		}
		if strings.Contains(description, "not available over the remote bridge") {
			t.Fatalf("%s is allowed over the bridge and must not say otherwise", name)
		}
		properties := entry["inputSchema"].(map[string]any)["properties"].(map[string]any)
		instance := properties["instance"].(map[string]string)
		if !strings.Contains(instance["description"], "relay_control_info") {
			t.Fatalf("%s instance property is undocumented: %v", name, instance)
		}
	}
	supervisor := 0
	for name, entry := range byName {
		if !strings.HasPrefix(name, "relay_miko_") || name == "relay_miko_receipt" {
			continue
		}
		supervisor++
		if !strings.Contains(entry["description"].(string), "not available over the remote bridge") {
			t.Fatalf("%s does not say it is refused over the remote bridge", name)
		}
	}
	for _, name := range []string{"relay_miko_set_instructions", "relay_miko_set_memory", "relay_miko_set_capabilities", "relay_miko_revert"} {
		if !strings.Contains(byName[name]["description"].(string), "a correction grant does NOT bypass the remote MCP bridge's 403") {
			t.Fatalf("%s leaves the correction grant and the bridge 403 ambiguous", name)
		}
	}
	if supervisor == 0 {
		t.Fatal("no supervisor tools listed")
	}
}
