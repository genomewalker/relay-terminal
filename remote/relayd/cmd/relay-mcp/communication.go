package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

func (s *server) communicationActor() (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, s.daemonHelper, "communication-actor")
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("native caller pane unavailable: %s", strings.TrimSpace(stderr.String()))
	}
	var actor struct {
		Version     int    `json:"version"`
		PaneID      string `json:"pane_id"`
		ClientPID   int    `json:"client_pid"`
		ClientStart string `json:"client_start"`
		Source      string `json:"source"`
	}
	if stdout.Len() > 8192 || json.Unmarshal(stdout.Bytes(), &actor) != nil || actor.Version != 1 ||
		!paneID.MatchString(actor.PaneID) || actor.ClientPID != os.Getpid() || actor.ClientStart == "" ||
		(actor.Source != "foreground_worker_kernel_ancestry" && actor.Source != "native_parked_job_kernel_owner") {
		return "", fmt.Errorf("invalid native caller pane proof")
	}
	return actor.PaneID, nil
}

// Only communication is redirected here. UI/editor tools retain their existing
// client transport; none of those tools are advertised as server automation.
func (s *server) daemonCommunication(name string, arguments map[string]json.RawMessage) (any, bool) {
	operations := map[string]string{"relay_link_panes": "link", "relay_unlink_panes": "unlink", "relay_list_pane_links": "list",
		"relay_message_pane": "send", "relay_pane_message_receipt": "receipt"}
	operation, ok := operations[name]
	if !ok {
		return nil, false
	}
	packet := map[string]any{"operation": operation}
	if s.callerToken != "" {
		packet["client_token"] = s.callerToken
	}
	actor := ""
	if os.Getenv("RELAY_SESSION") != "" {
		var err error
		actor, err = s.communicationActor()
		if err != nil {
			return map[string]any{"content": []map[string]any{{"type": "text", "text": err.Error()}}, "isError": true}, true
		}
		packet["actor_pane_id"] = actor
	}
	allowed := map[string]bool{"source_pane_id": true, "pane_id": true, "message_id": true, "text": true, "link_id": true}
	result := func(text string, failed bool) any {
		return map[string]any{"content": []map[string]any{{"type": "text", "text": text}}, "isError": failed}
	}
	for key, raw := range arguments {
		if !allowed[key] {
			return result("Unexpected daemon communication argument", true), true
		}
		var value string
		if json.Unmarshal(raw, &value) != nil {
			return result("Communication arguments must be strings", true), true
		}
		packet[key] = value
	}
	// A provider-local MCP client can label only its own pane as sender.
	// Actual recipient/session/socket identity is checked again by relayd.
	if actor != "" && (operation == "send" || operation == "link" || operation == "unlink") {
		source, _ := packet["source_pane_id"].(string)
		if source != "" && !strings.EqualFold(source, actor) {
			return result("Sender must be this MCP client's own pane", true), true
		}
		packet["source_pane_id"] = actor
	}
	encoded, err := json.Marshal(packet)
	if err != nil || len(encoded) > 65536 {
		return result("Communication request exceeds limit", true), true
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, s.daemonHelper, "communication")
	cmd.Stdin = bytes.NewReader(encoded)
	var out, stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return result(fmt.Sprintf("Daemon communication unavailable: %s", strings.TrimSpace(stderr.String())), true), true
	}
	if out.Len() > 128<<10 || !json.Valid(out.Bytes()) {
		return result("Invalid daemon communication response", true), true
	}
	return result(out.String(), false), true
}
