package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestStableFrontendUsesFreshHandlerAndPreservesMetadata(t *testing.T) {
	input := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}` + "\n" + `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"relay_work_link_status","_meta":{"threadId":"exact-native-thread"}}}` + "\n"
	calls := 0
	var output bytes.Buffer
	err := serve(strings.NewReader(input), &output, func(raw []byte) ([]byte, error) {
		calls++
		var r map[string]any
		if err := json.Unmarshal(raw, &r); err != nil {
			t.Fatal(err)
		}
		if calls == 2 {
			meta := r["params"].(map[string]any)["_meta"].(map[string]any)
			if meta["threadId"] != "exact-native-thread" {
				t.Fatal("metadata changed")
			}
		}
		return json.Marshal(map[string]any{"jsonrpc": "2.0", "id": r["id"], "result": map[string]any{"generation": calls}})
	})
	if err != nil || calls != 2 {
		t.Fatalf("%v calls=%d", err, calls)
	}
	if !strings.Contains(output.String(), `"generation":2`) {
		t.Fatal("old handler reused")
	}
}
func TestFrontendRejectsMalformedAndOversizedFramesBeforeExecution(t *testing.T) {
	for _, input := range []string{"not-json\n", strings.Repeat("x", maxFrame+1) + "\n"} {
		called := false
		err := serve(strings.NewReader(input), &bytes.Buffer{}, func([]byte) ([]byte, error) { called = true; return nil, nil })
		if err == nil || called {
			t.Fatal("accepted invalid frame")
		}
	}
}
