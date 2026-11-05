package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// Compile through the current installed image, so a long-lived stdio client
// discovers newly installed tools without restarting its provider session.
// These two helper modes are pure: they never load credentials or send input.
func (s *server) installedCatalogCommand(mode string, input []byte) ([]byte, error) {
	if s.catalogRunner != nil {
		return s.catalogRunner(mode, input)
	}
	path, err := os.Executable()
	if err != nil {
		return nil, err
	}
	if filepath.Base(path) != "relay-mcp" {
		return nil, errors.New("not an installed MCP image")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, path, mode)
	command.Stdin = bytes.NewReader(input)
	raw, err := command.Output()
	if err != nil || len(raw) > 1<<20 {
		return nil, errors.New("current installed MCP catalog unavailable")
	}
	return raw, nil
}

func (s *server) currentInstalledCatalog() ([]map[string]any, error) {
	raw, err := s.installedCatalogCommand("--miko-catalog", nil)
	if err != nil {
		return nil, err
	}
	var catalog []map[string]any
	if json.Unmarshal(raw, &catalog) != nil {
		return nil, errors.New("invalid current MCP catalog")
	}
	return catalog, nil
}

func (s *server) currentInstalledCall(name string, args map[string]json.RawMessage) (any, bool) {
	if s.daemonHelper != "" {
		switch name {
		case "relay_link_panes", "relay_unlink_panes", "relay_list_pane_links", "relay_message_pane", "relay_pane_message_receipt", "relay_bind_question_thread", "relay_unbind_question_thread":
			return nil, false
		}
	}
	catalog, err := s.currentInstalledCatalog()
	if err != nil {
		return nil, false
	}
	present := false
	for _, definition := range catalog {
		if definition["name"] == name {
			present = true
			break
		}
	}
	if !present {
		return nil, false
	}
	raw, err := json.Marshal(map[string]any{"tool_name": name, "arguments": args})
	if err != nil {
		return currentCatalogFailure("Invalid tool arguments"), true
	}
	compiled, err := s.installedCatalogCommand("--miko-plan", raw)
	if err != nil {
		return currentCatalogFailure("The current MCP tool schema refused these arguments; nothing was submitted"), true
	}
	var plan mikoPlan
	if json.Unmarshal(compiled, &plan) != nil || plan.Tool != name || len(plan.Path) < 5 || plan.Path[:5] != "/api/" || (plan.Method != "GET" && plan.Method != "POST" && plan.Method != "DELETE") {
		return currentCatalogFailure("Invalid current MCP request plan; nothing was submitted"), true
	}
	value, err := s.exchange(plan.Method, plan.Path, plan.Body)
	if err != nil {
		return currentCatalogFailure(err.Error()), true
	}
	return map[string]any{"content": []any{map[string]any{"type": "text", "text": value}}, "isError": false}, true
}

func currentCatalogFailure(detail string) any {
	return map[string]any{"isError": true, "content": []any{map[string]any{"type": "text", "text": detail}}}
}
