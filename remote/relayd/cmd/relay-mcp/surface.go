package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
)

func surfaceTools(context ...string) []any {
	uuid := map[string]any{"type": "string", "pattern": paneID.String()}
	pane := map[string]any{"type": "string", "pattern": paneID.String()}
	if len(context) > 0 && context[0] != "" {
		pane["const"] = context[0]
		pane["description"] = "Exact conversation pane: " + context[0]
	}
	integer := map[string]any{"type": "integer", "minimum": 0}
	return []any{
		tool("relay_publish_surface", "Create/update/close a durable native surface on an exact existing pane. Requires a registered caller credential and layout grant. Retain surface_id/generation; revision must equal expected_revision+1. Exact retry acknowledges the commit; after timeout/conflict read status before retrying. Closed IDs cannot reopen. Does not send terminal input.", map[string]any{"pane_id": pane, "surface_id": uuid, "generation": uuid, "revision": integer, "expected_revision": integer, "operation": map[string]any{"type": "string", "enum": []string{"snapshot", "close"}}, "content": map[string]any{"type": "object", "description": "Declarative surface content: kind (text/status/table/diff/image/equation/diagram/markdown), title/text/status strings, columns string array, rows array of string arrays; optional imageBase64/imageSHA256. Missing common fields receive empty defaults; no executable actions."}}, []string{"pane_id", "surface_id", "generation", "revision", "expected_revision", "operation"}),
		tool("relay_read_surfaces", "Recover your own surfaces on an exact pane, including close tombstones and revisions. Registered caller credential required; paused clients can read. include_content defaults false. Use after reconnect, revision conflict, or uncertain publication. Never retries a publication.", map[string]any{"pane_id": pane, "include_content": map[string]any{"type": "boolean"}}, []string{"pane_id"}),
	}
}

func surfaceRoute(name string, args map[string]json.RawMessage, credential string, context ...string) (string, []byte, error) {
	if credential == "" {
		return "", nil, fmt.Errorf("Registered caller credential required for surfaces")
	}
	if len(args) > 7 {
		return "", nil, fmt.Errorf("Unexpected surface arguments")
	}
	var pane string
	if json.Unmarshal(args["pane_id"], &pane) != nil || !paneID.MatchString(pane) {
		return "", nil, fmt.Errorf("Exact pane UUID required")
	}
	if len(context) > 0 && context[0] != "" && !strings.EqualFold(pane, context[0]) {
		return "", nil, fmt.Errorf("Surface target differs from this conversation pane")
	}
	if name == "relay_read_surfaces" {
		for key := range args {
			if key != "pane_id" && key != "include_content" {
				return "", nil, fmt.Errorf("Unexpected surface read argument")
			}
		}
		include := false
		if raw, ok := args["include_content"]; ok {
			if json.Unmarshal(raw, &include) != nil || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
				return "", nil, fmt.Errorf("include_content must be boolean")
			}
		}
		path := "/api/surfaces/status"
		if include {
			path = "/api/surfaces/content"
		}
		body, _ := json.Marshal(map[string]string{"paneID": pane})
		return path, body, nil
	}
	for key := range args {
		switch key {
		case "pane_id", "surface_id", "generation", "revision", "expected_revision", "operation", "content":
		default:
			return "", nil, fmt.Errorf("Unexpected publication argument")
		}
	}
	var surface, generation, operation string
	var revision, expected uint64
	if json.Unmarshal(args["surface_id"], &surface) != nil || !paneID.MatchString(surface) || json.Unmarshal(args["generation"], &generation) != nil || !paneID.MatchString(generation) || json.Unmarshal(args["operation"], &operation) != nil || (operation != "snapshot" && operation != "close") || json.Unmarshal(args["revision"], &revision) != nil || bytes.Equal(bytes.TrimSpace(args["revision"]), []byte("null")) || json.Unmarshal(args["expected_revision"], &expected) != nil || bytes.Equal(bytes.TrimSpace(args["expected_revision"]), []byte("null")) || expected == ^uint64(0) || revision != expected+1 {
		return "", nil, fmt.Errorf("Exact surface/generation and consecutive integer revisions required")
	}
	var content map[string]json.RawMessage
	raw, hasContent := args["content"]
	if operation == "snapshot" {
		if !hasContent || json.Unmarshal(raw, &content) != nil || content == nil {
			return "", nil, fmt.Errorf("Snapshot content object required")
		}
		for key := range content {
			switch key {
			case "kind", "title", "text", "status", "columns", "rows", "imageBase64", "imageSHA256":
			default:
				return "", nil, fmt.Errorf("Unknown surface content field")
			}
		}
		var kind string
		if json.Unmarshal(content["kind"], &kind) != nil {
			return "", nil, fmt.Errorf("Surface content kind required")
		}
		switch kind {
		case "text", "status", "table", "diff", "image", "equation", "diagram", "markdown":
		default:
			return "", nil, fmt.Errorf("Unsupported surface content kind")
		}
		for _, key := range []string{"title", "text", "status"} {
			if _, ok := content[key]; !ok {
				content[key] = json.RawMessage(`""`)
			}
		}
		for _, key := range []string{"columns", "rows"} {
			if _, ok := content[key]; !ok {
				content[key] = json.RawMessage(`[]`)
			}
		}
	} else if hasContent && !bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return "", nil, fmt.Errorf("Close cannot include content")
	}
	body, err := json.Marshal(map[string]any{"paneID": pane, "surfaceID": surface, "generation": generation, "revision": revision, "expectedRevision": expected, "operation": operation, "content": content})
	if err != nil || len(body) > 1<<20 {
		return "", nil, fmt.Errorf("Surface publication exceeds 1 MiB")
	}
	return "/api/surfaces/publish", body, nil
}
