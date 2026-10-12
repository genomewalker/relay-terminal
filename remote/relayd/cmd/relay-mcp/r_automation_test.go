package main

import (
	"encoding/json"
	"testing"
)

func TestStructuredSelectionPreservesSessionAndRevision(t *testing.T) {
	var args map[string]json.RawMessage
	json.Unmarshal([]byte(`{"pane_id":"11111111-1111-4111-8111-111111111111","instance":"22222222-2222-4222-8222-222222222222","request_id":"33333333-3333-4333-8333-333333333333","document_id":"doc","revision":"18446744073709551615","expected_session":"R-123","range":{"startLineNumber":2,"startColumn":1,"endLineNumber":4,"endColumn":6}}`), &args)
	path, body, handled, err := rAutomationRoute("relay_run_editor_selection", args)
	if err != nil || !handled || path != "/api/panes/11111111-1111-4111-8111-111111111111/r-run-selection" {
		t.Fatalf("route: %s %v", path, err)
	}
	var payload map[string]any
	json.Unmarshal(body, &payload)
	if payload["expected_session"] != "R-123" || payload["revision"] != "18446744073709551615" || payload["text"] != nil {
		t.Fatal("structured request lost its guards or became generic terminal input")
	}
	args["text"] = json.RawMessage(`"shell command"`)
	if _, _, _, err := rAutomationRoute("relay_run_editor_selection", args); err == nil {
		t.Fatal("accepted unknown generic input")
	}
	delete(args, "text")
	args["range"] = json.RawMessage(`{"startLineNumber":4,"startColumn":1,"endLineNumber":2,"endColumn":6}`)
	if _, _, _, err := rAutomationRoute("relay_run_editor_selection", args); err == nil {
		t.Fatal("accepted inverted selection")
	}
}

func TestFullEditorFilePreservesDocumentGuards(t *testing.T) {
	var args map[string]json.RawMessage
	json.Unmarshal([]byte(`{"pane_id":"11111111-1111-4111-8111-111111111111","instance":"22222222-2222-4222-8222-222222222222","request_id":"33333333-3333-4333-8333-333333333333","document_id":"doc","revision":"1","expected_session":"R-123"}`), &args)
	path, body, handled, err := rAutomationRoute("relay_run_editor_file", args)
	if err != nil || !handled || path != "/api/panes/11111111-1111-4111-8111-111111111111/r-run-file" {
		t.Fatalf("route: %s %v", path, err)
	}
	var payload map[string]any
	json.Unmarshal(body, &payload)
	if payload["document_id"] != "doc" || payload["expected_session"] != "R-123" || payload["code"] != nil {
		t.Fatal("file execution must use exact editor content")
	}
	delete(args, "revision")
	if _, _, _, err := rAutomationRoute("relay_run_editor_file", args); err == nil {
		t.Fatal("accepted file execution without revision")
	}
}

func TestProjectRunRequiresExactHashAndConfinedPath(t *testing.T) {
	args := map[string]json.RawMessage{}
	for key, value := range map[string]string{"pane_id": "11111111-1111-4111-8111-111111111111", "instance": "22222222-2222-4222-8222-222222222222", "request_id": "33333333-3333-4333-8333-333333333333", "expected_session": "R-1", "path": "analysis/a.R", "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"} {
		args[key], _ = json.Marshal(value)
	}
	path, _, handled, err := rAutomationRoute("relay_run_project_file", args)
	if err != nil || !handled || path != "/api/panes/11111111-1111-4111-8111-111111111111/r-run-project-file" {
		t.Fatalf("valid route: %s %v", path, err)
	}
	for _, bad := range []string{"../a.R", "/a.R", "analysis//a.R"} {
		args["path"], _ = json.Marshal(bad)
		if _, _, _, err := rAutomationRoute("relay_run_project_file", args); err == nil {
			t.Fatalf("accepted %s", bad)
		}
	}
	args["path"], _ = json.Marshal("analysis/a.R")
	args["sha256"], _ = json.Marshal("not-a-hash")
	if _, _, _, err := rAutomationRoute("relay_run_project_file", args); err == nil {
		t.Fatal("accepted malformed hash")
	}
}
