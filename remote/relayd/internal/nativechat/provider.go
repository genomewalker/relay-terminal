package nativechat

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

type ProviderOptions struct {
	AccountRoot string
	Provider    string
	CWD         string
	Model       string
	Resume      string
	Session     string // preallocated UUID for a new Claude conversation
}
type Driver struct {
	State           *State
	Options         ProviderOptions
	lastTurn        string
	messageID       string
	blockKinds      map[int]string
	interruptedTurn string
	callActions     map[string]string
	restoring       bool
}

func NewDriver(s *State, o ProviderOptions) (*Driver, error) {
	if s == nil || o.Provider != s.View.Identity.Provider || o.CWD != s.View.CWD {
		return nil, errors.New("provider options do not match owned state")
	}
	if o.Resume != "" && !validID(o.Resume) {
		return nil, errors.New("invalid resume session")
	}
	if o.Provider == "claude" && !validID(o.Session) {
		return nil, errors.New("Claude session UUID required")
	}
	return &Driver{State: s, Options: o, blockKinds: map[int]string{}, callActions: map[string]string{}}, nil
}
func wire(v any) json.RawMessage { b, _ := json.Marshal(v); return b }
func obj(b json.RawMessage) map[string]json.RawMessage {
	var m map[string]json.RawMessage
	_ = json.Unmarshal(b, &m)
	return m
}
func str(b json.RawMessage) string { var s string; _ = json.Unmarshal(b, &s); return s }
func flag(b json.RawMessage) bool  { var v bool; _ = json.Unmarshal(b, &v); return v }
func array(b json.RawMessage) []json.RawMessage {
	var a []json.RawMessage
	_ = json.Unmarshal(b, &a)
	return a
}
func stableID(prefix, value string) string {
	h := sha256.Sum256([]byte(value))
	return prefix + "-" + hex.EncodeToString(h[:16])
}
func pretty(b json.RawMessage) string {
	var v any
	if json.Unmarshal(b, &v) != nil {
		return string(b)
	}
	out, _ := json.MarshalIndent(v, "", "  ")
	return string(out)
}
func (d *Driver) Initial() json.RawMessage {
	if d.Options.Provider == "codex" {
		return wire(map[string]any{"id": "relay-initialize", "method": "initialize", "params": map[string]any{"clientInfo": map[string]string{"name": "relay_native", "title": "Relay", "version": "1"}, "capabilities": map[string]any{"experimentalApi": true}}})
	}
	return wire(map[string]any{"type": "control_request", "request_id": "relay-initialize", "request": map[string]any{"subtype": "initialize", "hooks": nil}})
}
func (d *Driver) Consume(data []byte) ([]json.RawMessage, error) {
	m, e := DecodeObject(data, MaxFrameBytes)
	if e != nil {
		return nil, e
	}
	if d.Options.Provider == "codex" {
		return d.codex(m)
	}
	return d.claude(m)
}
func (d *Driver) Command(a Action) (json.RawMessage, error) {
	if d.Options.Provider == "codex" {
		return d.codexCommand(a)
	}
	return d.claudeCommand(a)
}
func (d *Driver) request(a Action) (Request, error) {
	for _, r := range d.State.View.Requests {
		if r.ID == a.RequestID && r.TurnID == a.TurnID && r.Responding {
			return r, nil
		}
	}
	return Request{}, errors.New("claimed request is no longer pending")
}
func (d *Driver) codexCommand(a Action) (json.RawMessage, error) {
	id := "relay-" + a.ID
	d.callActions[id] = a.ID
	switch a.Kind {
	case "send":
		inputs := []any{}
		if a.Text != "" {
			inputs = append(inputs, map[string]string{"type": "text", "text": a.Text})
		}
		for _, path := range a.Images {
			inputs = append(inputs, map[string]string{"type": "localImage", "path": path})
		}
		return wire(map[string]any{"id": id, "method": "turn/start", "params": map[string]any{"threadId": d.State.View.SessionID, "input": inputs}}), nil
	case "steer":
		return wire(map[string]any{"id": id, "method": "turn/steer", "params": map[string]any{"threadId": d.State.View.SessionID, "expectedTurnId": a.TurnID, "input": []any{map[string]string{"type": "text", "text": a.Text}}}}), nil
	case "interrupt":
		d.interruptedTurn = a.TurnID
		return wire(map[string]any{"id": id, "method": "turn/interrupt", "params": map[string]string{"threadId": d.State.View.SessionID, "turnId": a.TurnID}}), nil
	case "respond":
		delete(d.callActions, id)
		r, e := d.request(a)
		if e != nil {
			return nil, e
		}
		if r.Kind == "approval" {
			decision := "decline"
			if a.Decision == "allow" {
				decision = "accept"
			}
			return wire(map[string]any{"id": r.NativeID, "result": map[string]string{"decision": decision}}), nil
		}
		answers := map[string]any{}
		for key, values := range a.Answers {
			answers[key] = map[string]any{"answers": values}
		}
		return wire(map[string]any{"id": r.NativeID, "result": map[string]any{"answers": answers}}), nil
	}
	return nil, errors.New("unsupported Codex operation")
}
func (d *Driver) codex(m map[string]json.RawMessage) ([]json.RawMessage, error) {
	method := str(m["method"])
	params := obj(m["params"])
	id := str(m["id"])
	if method == "" {
		if errRaw, ok := m["error"]; ok {
			message := str(obj(errRaw)["message"])
			if message == "" {
				message = "Codex rejected the request"
			}
			if a, exists := d.callActions[id]; exists {
				delete(d.callActions, id)
				r := d.State.Receipts[a]
				r.State = "rejected"
				r.Detail = boundedDetail(message)
				d.State.Receipts[a] = r
				if d.State.View.Phase == "starting" && d.State.View.SessionID != "" {
					d.State.View.Phase = "idle"
				}
				d.State.View.Failure = boundedDetail(message)
				d.State.touch()
				return nil, nil
			}
			return nil, errors.New(message)
		}
		result := obj(m["result"])
		switch id {
		case "relay-initialize":
			p := map[string]any{"cwd": d.Options.CWD}
			if d.Options.Model != "" {
				p["model"] = d.Options.Model
			}
			next := "thread/start"
			if d.Options.Resume != "" {
				next = "thread/resume"
				p["threadId"] = d.Options.Resume
			}
			return []json.RawMessage{wire(map[string]any{"method": "initialized", "params": map[string]any{}}), wire(map[string]any{"id": "relay-thread", "method": next, "params": p})}, nil
		case "relay-thread":
			thread := obj(result["thread"])
			session := str(thread["id"])
			if d.Options.Resume != "" && session != d.Options.Resume {
				return nil, errors.New("Codex resumed a different thread")
			}
			if e := d.State.Ready(session); e != nil {
				return nil, e
			}
			d.restoring = true
			defer func() { d.restoring = false }()
			for _, turnRaw := range array(thread["turns"]) {
				turn := obj(turnRaw)
				for _, item := range array(turn["items"]) {
					if e := d.codexItem(obj(item), false); e != nil {
						return nil, e
					}
				}
			}
			return nil, nil
		}
		if _, ok := d.callActions[id]; ok {
			delete(d.callActions, id)
			turn := obj(result["turn"])
			if turnID := str(turn["id"]); turnID != "" {
				d.lastTurn = turnID
				return nil, d.State.Running(turnID)
			}
		}
		return nil, nil
	}
	session := str(params["threadId"])
	if session != "" && d.State.View.SessionID != "" && session != d.State.View.SessionID {
		return nil, nil
	}
	switch method {
	case "turn/started":
		turn := obj(params["turn"])
		d.lastTurn = str(turn["id"])
		return nil, d.State.Running(d.lastTurn)
	case "turn/completed":
		turn := obj(params["turn"])
		turnID := str(turn["id"])
		status := str(turn["status"])
		detail := ""
		if status == "failed" {
			detail = str(obj(turn["error"])["message"])
		}
		// Codex clears blocking requests when their turn ends. Claude has a
		// different lifetime: background tasks can still require a response.
		kept := d.State.View.Requests[:0]
		for _, r := range d.State.View.Requests {
			if r.TurnID != turnID {
				kept = append(kept, r)
			}
		}
		d.State.View.Requests = kept
		return nil, d.State.Complete(turnID, status, detail)
	case "item/started", "item/completed":
		return nil, d.codexItem(obj(params["item"]), method == "item/started")
	case "item/agentMessage/delta", "item/reasoning/summaryTextDelta", "item/reasoning/textDelta", "item/commandExecution/outputDelta":
		role := "assistant"
		tool := ""
		if strings.Contains(method, "reasoning") {
			role = "reasoning"
		}
		if strings.Contains(method, "commandExecution") {
			role = "tool"
			tool = "Command"
		}
		item := Item{ID: stableID("item", str(params["itemId"])), Role: role, Text: str(params["delta"]), Tool: tool, Status: "running"}
		return nil, d.State.AddItem(item, true)
	case "serverRequest/resolved":
		native := params["requestId"]
		for _, r := range d.State.View.Requests {
			if string(r.NativeID) == string(native) {
				d.State.ResolveRequest(r.ID)
				break
			}
		}
		return nil, nil
	case "error":
		d.State.View.Failure = str(obj(params["error"])["message"])
		d.State.touch()
		return nil, nil
	}
	if native, hasID := m["id"]; hasID {
		turn := str(params["turnId"])
		if turn == "" || turn != d.State.View.TurnID || session != d.State.View.SessionID {
			return nil, errors.New("unscoped Codex request")
		}
		r := Request{ID: stableID("request", string(native)+":"+turn), TurnID: turn, NativeID: append(json.RawMessage(nil), native...), Method: method, Kind: "approval", Title: "Approval required", Detail: pretty(m["params"])}
		switch method {
		case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
			if method == "item/commandExecution/requestApproval" {
				r.Title = "Run command"
			} else {
				r.Title = "Apply file changes"
			}
			// Only offer an allow-once decision when the provider advertises it.
			if decisions := array(params["availableDecisions"]); len(decisions) > 0 {
				accept, decline := false, false
				for _, v := range decisions {
					accept = accept || str(v) == "accept"
					decline = decline || str(v) == "decline"
				}
				if !accept || !decline {
					return []json.RawMessage{wire(map[string]any{"id": native, "error": map[string]any{"code": -32602, "message": "Relay requires allow-once and decline approval decisions"}})}, nil
				}
			}
		case "item/tool/requestUserInput":
			r.Kind = "question"
			r.Title = "Your input is needed"
			r.Detail = ""
			for _, raw := range array(params["questions"]) {
				q := obj(raw)
				question := Question{ID: str(q["id"]), Text: str(q["question"]), Header: str(q["header"]), Secret: flag(q["isSecret"])}
				for _, oRaw := range array(q["options"]) {
					o := obj(oRaw)
					question.Options = append(question.Options, Option{ID: str(o["label"]), Label: str(o["label"]), Description: str(o["description"])})
				}
				r.Questions = append(r.Questions, question)
			}
		default:
			_ = d.State.AddItem(Item{ID: stableID("unsupported", string(native)), Role: "system", Text: "Unsupported provider request: " + method, Status: "failed"}, false)
			return []json.RawMessage{wire(map[string]any{"id": native, "error": map[string]any{"code": -32601, "message": "Relay does not support this provider request"}})}, nil
		}
		return nil, d.State.AddRequest(r)
	}
	return nil, nil
}
func (d *Driver) codexItem(m map[string]json.RawMessage, started bool) error {
	nativeID := str(m["id"])
	if nativeID == "" {
		return nil
	}
	item := Item{ID: stableID("item", nativeID), Status: str(m["status"])}
	if item.Status == "" {
		if started {
			item.Status = "running"
		} else {
			item.Status = "completed"
		}
	}
	switch str(m["type"]) {
	case "agentMessage":
		item.Role = "assistant"
		item.Text = str(m["text"])
	case "userMessage":
		if !d.restoring {
			return nil
		}
		item.Role = "user"
		for _, part := range array(m["content"]) {
			p := obj(part)
			if str(p["type"]) == "text" {
				item.Text += str(p["text"])
			} else if str(p["type"]) == "localImage" {
				item.Text += "\n[Image: " + str(p["path"]) + "]"
			}
		}
	case "reasoning":
		item.Role = "reasoning"
		for _, part := range array(m["summary"]) {
			if x := str(part); x != "" {
				item.Text += x + "\n"
			} else {
				item.Text += str(obj(part)["text"]) + "\n"
			}
		}
	case "commandExecution":
		item.Role = "tool"
		item.Tool = "Command"
		item.Text = str(m["command"])
		if output := str(m["aggregatedOutput"]); output != "" {
			item.Text += "\n" + output
		}
	case "fileChange":
		item.Role = "tool"
		item.Tool = "File changes"
		item.Text = pretty(m["changes"])
	case "mcpToolCall", "dynamicToolCall", "webSearch", "collabAgentToolCall":
		item.Role = "tool"
		item.Tool = str(m["tool"])
		if item.Tool == "" {
			item.Tool = str(m["type"])
		}
		item.Text = pretty(wire(m))
	case "plan":
		item.Role = "assistant"
		item.Tool = "Plan"
		item.Text = str(m["text"])
	default:
		return nil
	}
	return d.State.AddItem(item, false)
}
func (d *Driver) claudeCommand(a Action) (json.RawMessage, error) {
	switch a.Kind {
	case "send":
		d.lastTurn = a.ID
		d.interruptedTurn = ""
		if e := d.State.Running(a.ID); e != nil {
			return nil, e
		}
		content := []any{}
		if a.Text != "" {
			content = append(content, map[string]string{"type": "text", "text": a.Text})
		}
		// Image bytes are prepared by the worker, never interpreted as user text.
		if len(a.Images) > 0 {
			return nil, errors.New("Claude image input must be prepared by the host worker")
		}
		return wire(map[string]any{"type": "user", "uuid": a.ID, "session_id": d.State.View.SessionID, "parent_tool_use_id": nil, "message": map[string]any{"role": "user", "content": content}}), nil
	case "interrupt":
		d.interruptedTurn = a.TurnID
		return wire(map[string]any{"type": "control_request", "request_id": "relay-" + a.ID, "request": map[string]string{"subtype": "interrupt"}}), nil
	case "respond":
		r, e := d.request(a)
		if e != nil {
			return nil, e
		}
		response := map[string]any{"behavior": "deny", "message": "Declined in Relay"}
		if r.Kind == "question" {
			input := obj(r.ToolInput)
			answers := map[string]string{}
			for _, q := range r.Questions {
				answers[q.Text] = strings.Join(a.Answers[q.ID], ", ")
			}
			input["answers"] = wire(answers)
			response = map[string]any{"behavior": "allow", "updatedInput": input}
		} else if a.Decision == "allow" {
			response = map[string]any{"behavior": "allow", "updatedInput": r.ToolInput}
		}
		return wire(map[string]any{"type": "control_response", "response": map[string]any{"subtype": "success", "request_id": str(r.NativeID), "response": response}}), nil
	}
	return nil, errors.New("unsupported Claude operation")
}
func (d *Driver) claude(m map[string]json.RawMessage) ([]json.RawMessage, error) {
	if session := str(m["session_id"]); session != "" && session != d.Options.Session {
		return nil, errors.New("Claude emitted a different session")
	}
	switch str(m["type"]) {
	case "control_response":
		response := obj(m["response"])
		if str(response["request_id"]) == "relay-initialize" {
			if str(response["subtype"]) != "success" {
				return nil, errors.New("Claude initialization failed: " + str(response["error"]))
			}
			return nil, d.State.Ready(d.Options.Session)
		}
		if str(response["subtype"]) == "error" {
			d.State.View.Failure = str(response["error"])
			d.State.touch()
		}
	case "system":
		switch str(m["subtype"]) {
		case "init":
			return nil, d.State.Ready(str(m["session_id"]))
		case "session_state_changed":
			activity := str(m["state"])
			switch activity {
			case "idle":
				d.State.ProviderBusy = false
			case "running", "busy", "requires_action":
				d.State.ProviderBusy = true
			default:
				// Unknown future states do not advertise a ready composer.
				d.State.ProviderBusy = true
			}
			d.State.touch()
			return nil, nil
		case "task_started", "task_notification", "task_progress", "task_updated", "background_tasks_changed":
			id := str(m["task_id"])
			if id == "" {
				id = str(m["uuid"])
			}
			return nil, d.State.AddItem(Item{ID: stableID("task", id), Role: "tool", Tool: "Background task", Status: str(m["status"]), Text: pretty(wire(m))}, false)
		}
	case "stream_event":
		event := obj(m["event"])
		var index int
		_ = json.Unmarshal(event["index"], &index)
		switch str(event["type"]) {
		case "message_start":
			d.messageID = str(obj(event["message"])["id"])
			d.blockKinds = map[int]string{}
		case "content_block_start":
			block := obj(event["content_block"])
			kind := str(block["type"])
			d.blockKinds[index] = kind
			role := "assistant"
			if kind == "thinking" {
				role = "reasoning"
			} else if kind == "tool_use" {
				role = "tool"
			}
			return nil, d.State.AddItem(Item{ID: stableID("block", fmt.Sprintf("%s:%d", d.messageID, index)), Role: role, Tool: str(block["name"]), Text: str(block["text"]), Status: "running"}, false)
		case "content_block_delta":
			delta := obj(event["delta"])
			kind := str(delta["type"])
			role := "assistant"
			text := str(delta["text"])
			if kind == "thinking_delta" {
				role = "reasoning"
				text = str(delta["thinking"])
			}
			if kind != "text_delta" && kind != "thinking_delta" {
				return nil, nil
			}
			return nil, d.State.AddItem(Item{ID: stableID("block", fmt.Sprintf("%s:%d", d.messageID, index)), Role: role, Text: text, Status: "running"}, true)
		}
	case "assistant":
		message := obj(m["message"])
		id := str(message["id"])
		for index, raw := range array(message["content"]) {
			block := obj(raw)
			item := Item{ID: stableID("block", fmt.Sprintf("%s:%d", id, index)), Role: "assistant", Status: "completed"}
			switch str(block["type"]) {
			case "text":
				item.Text = str(block["text"])
			case "thinking":
				item.Role = "reasoning"
				item.Text = str(block["thinking"])
			case "tool_use":
				item.Role = "tool"
				item.Tool = str(block["name"])
				item.Text = pretty(block["input"])
				item.Status = "running"
			default:
				continue
			}
			if e := d.State.AddItem(item, false); e != nil {
				return nil, e
			}
		}
	case "user":
		message := obj(m["message"])
		for _, raw := range array(message["content"]) {
			block := obj(raw)
			if str(block["type"]) == "tool_result" {
				status := "completed"
				if flag(block["is_error"]) {
					status = "failed"
				}
				text := str(block["content"])
				if text == "" {
					text = pretty(block["content"])
				}
				if e := d.State.AddItem(Item{ID: stableID("result", str(block["tool_use_id"])), Role: "tool", Tool: "Tool result", Text: text, Status: status}, false); e != nil {
					return nil, e
				}
			}
		}
	case "result":
		if d.State.View.TurnID == "" {
			return nil, nil
		}
		status, detail := "completed", ""
		if flag(m["is_error"]) {
			status = "failed"
			detail = str(m["result"])
			if errors := array(m["errors"]); len(errors) > 0 {
				parts := []string{}
				for _, e := range errors {
					parts = append(parts, str(e))
				}
				detail = strings.Join(parts, "; ")
			}
			if detail == "" {
				detail = str(m["subtype"])
			}
		}
		if d.interruptedTurn == d.State.View.TurnID {
			status = "interrupted"
			detail = ""
		}
		return nil, d.State.Complete(d.State.View.TurnID, status, detail)
	case "control_cancel_request":
		id := str(m["request_id"])
		for _, r := range d.State.View.Requests {
			if str(r.NativeID) == id {
				d.State.ResolveRequest(r.ID)
				break
			}
		}
	case "control_request":
		native := str(m["request_id"])
		request := obj(m["request"])
		subtype := str(request["subtype"])
		if native == "" || d.lastTurn == "" {
			return nil, errors.New("unscoped Claude control request")
		}
		if subtype != "can_use_tool" {
			return []json.RawMessage{wire(map[string]any{"type": "control_response", "response": map[string]any{"subtype": "error", "request_id": native, "error": "Unsupported Relay control request: " + subtype}})}, nil
		}
		tool := str(request["tool_name"])
		r := Request{ID: stableID("request", native), TurnID: d.lastTurn, NativeID: wire(native), Kind: "approval", Title: tool, Detail: pretty(request["input"]), ToolInput: append(json.RawMessage(nil), request["input"]...), Method: subtype}
		if tool == "AskUserQuestion" {
			r.Kind = "question"
			r.Title = "Your input is needed"
			r.Detail = ""
			for index, raw := range array(obj(request["input"])["questions"]) {
				q := obj(raw)
				question := Question{ID: fmt.Sprintf("question-%d", index), Text: str(q["question"]), Header: str(q["header"]), Multiple: flag(q["multiSelect"])}
				for _, rawOption := range array(q["options"]) {
					o := obj(rawOption)
					question.Options = append(question.Options, Option{ID: str(o["label"]), Label: str(o["label"]), Description: str(o["description"])})
				}
				r.Questions = append(r.Questions, question)
			}
		}
		return nil, d.State.AddRequest(r)
	}
	return nil, nil
}
