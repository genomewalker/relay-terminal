package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestEditorEditRoutes(t *testing.T) {
	args := map[string]json.RawMessage{}
	for k, v := range map[string]any{
		"pane_id":     "11111111-1111-4111-8111-111111111111",
		"instance":    "22222222-2222-4222-8222-222222222222",
		"request_id":  "33333333-3333-4333-8333-333333333333",
		"document_id": "document", "revision": "8", "text": "",
		"range": map[string]int{"startLineNumber": 1, "startColumn": 1, "endLineNumber": 1, "endColumn": 1},
	} {
		args[k], _ = json.Marshal(v)
	}
	path, _, handled, err := rAutomationRoute("relay_request_editor_edit", args)
	if err != nil || !handled || !strings.HasSuffix(path, "/editor-edit") {
		t.Fatalf("insertion/deletion rejected: %v", err)
	}
	args["revision"] = json.RawMessage(`"bad"`)
	if _, _, _, err := rAutomationRoute("relay_request_editor_edit", args); err == nil {
		t.Fatal("bad revision accepted")
	}
	args["revision"] = json.RawMessage(`"8"`)
	delete(args, "range")
	delete(args, "text")
	path, _, _, err = rAutomationRoute("relay_request_editor_save", args)
	if err != nil || !strings.HasSuffix(path, "/editor-save") {
		t.Fatalf("save rejected: %v", err)
	}
	args["extra"] = json.RawMessage(`true`)
	if _, _, _, err := rAutomationRoute("relay_request_editor_save", args); err == nil {
		t.Fatal("extra arguments accepted")
	}
}
