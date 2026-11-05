package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"
)

func terminalEditBody(name string, args map[string]json.RawMessage) (*mikoPlan, error) {
	fail := func() (*mikoPlan, error) {
		return nil, fmt.Errorf("Exact UUIDs, fresh token and one valid terminal editing action required")
	}
	fields := map[string]any{}
	for _, key := range []string{"pane_id", "instance", "request_id"} {
		var value string
		if json.Unmarshal(args[key], &value) != nil || !paneID.MatchString(value) {
			return fail()
		}
		fields[key] = value
	}
	pane := fields["pane_id"].(string)
	body := map[string]any{"instance": fields["instance"], "requestID": fields["request_id"]}
	path := "/api/terminal-edits/receipts/" + fields["instance"].(string) + "/" + pane + "/" + fields["request_id"].(string)
	method := "POST"
	if name == "relay_terminal_edit_receipt" {
		if len(args) != 3 {
			return fail()
		}
		method = "GET"
		body = map[string]any{}
	} else {
		if len(args) < 5 || len(args) > 8 {
			return fail()
		}
		for key := range args {
			if !strings.Contains("|pane_id|instance|request_id|proof_id|action|key|text|modifiers|", "|"+key+"|") {
				return fail()
			}
		}
		var token, action, text, key string
		if json.Unmarshal(args["proof_id"], &token) != nil || !paneID.MatchString(token) || json.Unmarshal(args["action"], &action) != nil {
			return fail()
		}
		body["proofID"], body["action"] = token, action
		var flags []string
		if raw, ok := args["modifiers"]; ok {
			if string(raw) == "null" || json.Unmarshal(raw, &flags) != nil || len(flags) > 3 {
				return fail()
			}
			seen := map[string]bool{}
			for _, flag := range flags {
				if seen[flag] || (flag != "shift" && flag != "control" && flag != "option") {
					return fail()
				}
				seen[flag] = true
			}
			body["modifiers"] = flags
		}
		switch action {
		case "insert_text":
			if _, ok := args["key"]; ok {
				return fail()
			}
			if json.Unmarshal(args["text"], &text) != nil || len(text) == 0 || len(text) > 8192 || !utf8.ValidString(text) || len(flags) > 0 {
				return fail()
			}
			for _, c := range text {
				if (c < 32 && c != '\n' && c != '\t') || (c >= 127 && c <= 159) {
					return fail()
				}
			}
			body["text"] = text
		case "key":
			if _, ok := args["text"]; ok {
				return fail()
			}
			if json.Unmarshal(args["key"], &key) != nil || !validTerminalEditKey(key) {
				return fail()
			}
			body["key"] = key
		default:
			return fail()
		}
		path = "/api/panes/" + pane + "/terminal-edit"
	}
	wire, _ := json.Marshal(body)
	return &mikoPlan{Method: method, Path: path, Body: wire}, nil
}

func validTerminalEditKey(key string) bool {
	if len(key) == 1 && ((key[0] >= 'a' && key[0] <= 'z') || (key[0] >= '0' && key[0] <= '9')) {
		return true
	}
	switch key {
	case "escape", "enter", "tab", "backspace", "delete", "left", "right", "up", "down", "home", "end", "page_up", "page_down", "space":
		return true
	}
	return false
}
