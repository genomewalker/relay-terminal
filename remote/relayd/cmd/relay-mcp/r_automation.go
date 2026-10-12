package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

func rAutomationTools() []any {
	common := map[string]any{"pane_id": map[string]string{"type": "string"}, "instance": map[string]string{"type": "string"}, "request_id": map[string]string{"type": "string"}}
	makeTool := func(name, description string, extras map[string]any) any {
		properties := map[string]any{}
		required := []string{"pane_id", "instance", "request_id"}
		for k, v := range common {
			properties[k] = v
		}
		for k, v := range extras {
			properties[k] = v
			required = append(required, k)
		}
		return tool(name, description, properties, required)
	}
	session := map[string]any{"type": "string", "maxLength": 256}
	selection := map[string]any{"document_id": map[string]string{"type": "string"}, "revision": map[string]string{"type": "string"}, "range": map[string]any{"type": "object", "additionalProperties": false, "properties": map[string]any{"startLineNumber": map[string]string{"type": "integer"}, "startColumn": map[string]string{"type": "integer"}, "endLineNumber": map[string]string{"type": "integer"}, "endColumn": map[string]string{"type": "integer"}}, "required": []string{"startLineNumber", "startColumn", "endLineNumber", "endColumn"}}}
	runSelection := map[string]any{"expected_session": session}
	for k, v := range selection {
		runSelection[k] = v
	}
	runFile := map[string]any{"expected_session": session, "document_id": selection["document_id"], "revision": selection["revision"]}
	edit := map[string]any{}
	for k, v := range selection {
		edit[k] = v
	}
	edit["text"] = map[string]any{"type": "string", "maxLength": 65536}
	return []any{
		tool("relay_r_session_status", "Read native R admission status without execution, handshake refresh, authorization or pause changes. Reports paused, active request, bound/current session identity and observed idle prompt. An idle prompt does not lift human pause and is not a liveness proof. Only explicit user direction may resume agents; never reauthorize to bypass takeover.", map[string]any{"pane_id": map[string]string{"type": "string"}}, []string{"pane_id"}),
		makeTool("relay_request_editor_edit", "Request native approval to replace an exact range in the open editor, including insertion or deletion. Requires current document_id and revision. Undoable; does not save or run code. Read relay_editor_operation_receipt before another edit; never retry an ambiguous operation.", edit),
		makeTool("relay_request_editor_save", "Request native approval to save the exact current editor document. Rejects stale document/revision and external disk changes. Does not execute code. Read the editor receipt; pending is not saved.", map[string]any{"document_id": selection["document_id"], "revision": selection["revision"]}),
		makeTool("relay_editor_operation_receipt", "Read an editor edit/save approval and completion receipt by original request_id and editor pane_id. Missing is unknown; never retry automatically.", nil),
		makeTool("relay_authorize_r_session", "Activate execution for a user-authorized linked R session without another dialog. Authorization survives Relay restarts for the exact host, project and R session. Does not execute code. Pause revokes automatic execution until explicitly resumed. Unresolved operations must be reconciled before reauthorization. Generic terminal input remains separately approved.", map[string]any{"expected_session": session}),
		makeTool("relay_select_editor_code", "Select a bounded exact editor range using the document_id and revision from relay_read_editor. Returns the selected code without executing it. Changed documents and diff views are rejected.", selection),
		makeTool("relay_run_editor_selection", "Select an exact current editor range and execute it directly in its linked R console using base R, without Relay R evaluation functions. Native terminal markers track completion under the active session authorization. No repeated native prompt. Use only for user-authorized execution, never plan mode. Check the R receipt before another chunk; never resend uncertain executions.", runSelection),
		makeTool("relay_run_editor_file", "Select and execute the complete current R editor document (up to 64 KiB), including unsaved edits, directly using base R without Relay R evaluation functions. Native terminal markers track completion. Requires exact document_id/revision and active authorization. Read the execution receipt; never retry uncertain execution.", runFile),
		makeTool("relay_run_project_file", "Execute a captured UTF-8 R file inside the bound project without opening the document. Requires expected SHA-256 of exact bytes and active R authorization; conflicting human drafts block execution. Preserves console evaluation semantics. Read receipt before another run; never resend uncertain work. R authorization is trusted execution with the process OS permissions, not a sandbox.", map[string]any{"expected_session": session, "path": map[string]string{"type": "string"}, "sha256": map[string]string{"type": "string"}}),
		makeTool("relay_run_r_code", "Run a bounded R chunk in the existing session under one native session authorization. No repeated prompt. Not generic terminal input. Use only for user-authorized execution, never plan mode. Submitted is not completion. Read its receipt before the next chunk.", map[string]any{"expected_session": session, "code": map[string]any{"type": "string", "maxLength": 65536}}),
		makeTool("relay_r_operation_receipt", "Read authorization status or the exact R execution result. Use the R console pane_id, including for editor executions. Missing or mismatched results remain unresolved and block further runs; never resend.", nil),
		makeTool("relay_pause_r_session", "Pause this R session's automatic MCP execution immediately. Does not interrupt or cancel a currently running R chunk.", nil),
	}
}

func rAutomationRoute(name string, args map[string]json.RawMessage) (string, []byte, bool, error) {
	routes := map[string]string{"relay_request_editor_edit": "editor-edit", "relay_request_editor_save": "editor-save", "relay_editor_operation_receipt": "editor-receipt", "relay_authorize_r_session": "r-authorize", "relay_select_editor_code": "editor-selection", "relay_run_editor_selection": "r-run-selection", "relay_run_editor_file": "r-run-file", "relay_run_project_file": "r-run-project-file", "relay_run_r_code": "r-run", "relay_r_operation_receipt": "r-result", "relay_pause_r_session": "r-pause"}
	operation, ok := routes[name]
	if !ok {
		return "", nil, false, nil
	}
	fail := func() (string, []byte, bool, error) {
		return "", nil, true, fmt.Errorf("Invalid structured R/editor arguments")
	}
	fields := []string{"pane_id", "instance", "request_id"}
	if operation == "r-run-project-file" || operation == "r-authorize" || operation == "r-run" || operation == "r-run-selection" || operation == "r-run-file" {
		fields = append(fields, "expected_session")
	}
	if operation == "r-run-project-file" {
		fields = append(fields, "path", "sha256")
	}
	if operation == "r-run" {
		fields = append(fields, "code")
	}
	if operation == "editor-selection" || operation == "r-run-selection" || operation == "editor-edit" {
		fields = append(fields, "document_id", "revision", "range")
	}
	if operation == "editor-edit" {
		fields = append(fields, "text")
	}
	if operation == "r-run-file" || operation == "editor-save" {
		fields = append(fields, "document_id", "revision")
	}
	if len(args) != len(fields) {
		return fail()
	}
	payload := map[string]any{}
	for _, field := range fields {
		if field == "range" {
			var r map[string]int
			if json.Unmarshal(args[field], &r) != nil || len(r) != 4 {
				return fail()
			}
			for _, k := range []string{"startLineNumber", "startColumn", "endLineNumber", "endColumn"} {
				if r[k] < 1 {
					return fail()
				}
			}
			if r["endLineNumber"] < r["startLineNumber"] || (r["endLineNumber"] == r["startLineNumber"] && (r["endColumn"] < r["startColumn"] || (operation != "editor-edit" && r["endColumn"] == r["startColumn"]))) {
				return fail()
			}
			payload[field] = r
			continue
		}
		var value string
		if json.Unmarshal(args[field], &value) != nil || (value == "" && field != "text") {
			return fail()
		}
		if field == "pane_id" || field == "instance" || field == "request_id" {
			if !paneID.MatchString(value) {
				return fail()
			}
		}
		if field == "code" || field == "text" {
			if len(value) > 65536 {
				return fail()
			}
		} else if field == "path" {
			if len(value) > 4096 || strings.HasPrefix(value, "/") || strings.Contains(value, "\x00") {
				return fail()
			}
			for _, part := range strings.Split(value, "/") {
				if part == "" || part == "." || part == ".." {
					return fail()
				}
			}
		} else if len(value) > 256 {
			return fail()
		}
		if field == "sha256" {
			decoded, err := hex.DecodeString(value)
			if err != nil || len(decoded) != 32 || value != strings.ToLower(value) {
				return fail()
			}
		}
		if field == "revision" {
			if _, err := strconv.ParseUint(value, 10, 64); err != nil {
				return fail()
			}
		}
		payload[field] = value
	}
	id := payload["pane_id"].(string)
	delete(payload, "pane_id")
	body, err := json.Marshal(payload)
	return "/api/panes/" + id + "/" + operation, body, true, err
}
