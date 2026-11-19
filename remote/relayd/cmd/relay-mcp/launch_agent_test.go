package main

import (
	"reflect"
	"strings"
	"testing"
)

func launchArgs() map[string]any {
	id := "11111111-1111-4111-8111-111111111111"
	return map[string]any{"instance": id, "request_id": "22222222-2222-4222-8222-222222222222", "host": "dandy-07",
		"cwd": "/home/u/my project", "provider": "claude", "model": "claude-opus-4.1", "account": "personal",
		"brief_path": "/home/u/briefs/it's $(x).md"}
}

func TestLaunchAgentForwardsExactRequest(t *testing.T) {
	s, paths, bodies, done := stackServer(t)
	defer done()
	args := launchArgs()
	if code := callTool(s, "relay_launch_agent", args); code != 0 {
		t.Fatal(code)
	}
	want := map[string]string{"instance": "11111111-1111-4111-8111-111111111111", "requestID": "22222222-2222-4222-8222-222222222222",
		"host": "dandy-07", "cwd": "/home/u/my project", "provider": "claude", "model": "claude-opus-4.1", "account": "personal",
		"briefPath": "/home/u/briefs/it's $(x).md"}
	if len(*paths) != 1 || (*paths)[0] != "/api/workspace/launch-agent" || !reflect.DeepEqual((*bodies)[0], want) {
		t.Fatalf("forwarded %v %v", *paths, *bodies)
	}
	target := "33333333-3333-4333-8333-333333333333"
	for key, wire := range map[string]string{"target_pane_id": "targetPaneID", "anchor_tab_id": "anchorTabID", "anchor_pane_id": "anchorPaneID"} {
		args := launchArgs()
		args[key] = target
		args["provider"] = "codex"
		if code := callTool(s, "relay_launch_agent", args); code != 0 {
			t.Fatal(key, code)
		}
		got := (*bodies)[len(*bodies)-1]
		if got[wire] != target || got["provider"] != "codex" || len(got) != 9 {
			t.Fatalf("%s forwarded %v", key, got)
		}
	}
}

func TestLaunchAgentRefusesInvalidArgumentsBeforeRelay(t *testing.T) {
	s, paths, _, done := stackServer(t)
	defer done()
	pane := "33333333-3333-4333-8333-333333333333"
	cases := map[string]func(map[string]any){
		"missing brief":       func(a map[string]any) { delete(a, "brief_path") },
		"relative cwd":        func(a map[string]any) { a["cwd"] = "project" },
		"tilde cwd":           func(a map[string]any) { a["cwd"] = "~/project" },
		"newline in cwd":      func(a map[string]any) { a["cwd"] = "/tmp/a\nrm -rf ~" },
		"newline in brief":    func(a map[string]any) { a["brief_path"] = "/tmp/b\n.md" },
		"relative brief":      func(a map[string]any) { a["brief_path"] = "brief.md" },
		"unknown provider":    func(a map[string]any) { a["provider"] = "gemini" },
		"model with space":    func(a map[string]any) { a["model"] = "opus; rm -rf ~" },
		"model with quote":    func(a map[string]any) { a["model"] = "o'pus" },
		"model upper":         func(a map[string]any) { a["model"] = "Opus" },
		"model too long":      func(a map[string]any) { a["model"] = strings.Repeat("a", 65) },
		"model subst":         func(a map[string]any) { a["model"] = "$(id)" },
		"unknown permission":  func(a map[string]any) { a["permission_mode"] = "bypassPermissions" },
		"permission not str":  func(a map[string]any) { a["permission_mode"] = true },
		"account display":     func(a map[string]any) { a["account"] = "personal (~/.claude-personal)" },
		"host option":         func(a map[string]any) { a["host"] = "-oProxyCommand=x" },
		"host injection":      func(a map[string]any) { a["host"] = "h; rm -rf ~" },
		"bad instance":        func(a map[string]any) { a["instance"] = "not-a-uuid" },
		"bad placement":       func(a map[string]any) { a["target_pane_id"] = "x" },
		"two placements":      func(a map[string]any) { a["target_pane_id"] = pane; a["anchor_tab_id"] = pane },
		"anchor and stack":    func(a map[string]any) { a["anchor_pane_id"] = pane; a["target_pane_id"] = pane },
		"command override":    func(a map[string]any) { a["command"] = "claude" },
		"environment":         func(a map[string]any) { a["env"] = map[string]string{"CLAUDE_CONFIG_DIR": "/x"} },
		"non-string provider": func(a map[string]any) { a["provider"] = 1 },
	}
	for name, mutate := range cases {
		args := launchArgs()
		mutate(args)
		if code := callTool(s, "relay_launch_agent", args); code != -32602 {
			t.Fatalf("%s: code %d", name, code)
		}
	}
	if len(*paths) != 0 {
		t.Fatalf("a refused launch reached Relay: %v", *paths)
	}
}

func TestLaunchAgentCatalogEntry(t *testing.T) {
	raw, _, _ := (&server{}).handle(request{Method: "tools/list"})
	for _, entry := range raw.(map[string]any)["tools"].([]any) {
		tool := entry.(map[string]any)
		if tool["name"] != "relay_launch_agent" {
			continue
		}
		if tool["annotations"].(map[string]any)["readOnlyHint"] != false {
			t.Fatal("launch is not marked as a mutation")
		}
		schema := tool["inputSchema"].(map[string]any)
		required := schema["required"].([]string)
		if !reflect.DeepEqual(required, []string{"instance", "request_id", "host", "cwd", "provider", "model", "account", "brief_path"}) {
			t.Fatalf("required %v", required)
		}
		for _, name := range mikoCatalog() {
			if name["name"] == "relay_launch_agent" {
				t.Fatal("Miko must not be offered relay_launch_agent yet")
			}
		}
		found := false
		for _, name := range agentCatalog() {
			found = found || name["name"] == "relay_launch_agent"
		}
		if !found {
			t.Fatal("agents' relay_call_tool catalog lacks relay_launch_agent")
		}
		return
	}
	t.Fatal("relay_launch_agent not in catalog")
}

func TestLaunchAgentForwardsPermissionMode(t *testing.T) {
	s, _, bodies, done := stackServer(t)
	defer done()
	for _, mode := range []string{"account", "ask", "read_only", "yolo"} {
		args := launchArgs()
		args["permission_mode"] = mode
		args["anchor_tab_id"] = "33333333-3333-4333-8333-333333333333"
		if code := callTool(s, "relay_launch_agent", args); code != 0 {
			t.Fatal(mode, code)
		}
		got := (*bodies)[len(*bodies)-1]
		if got["permissionMode"] != mode || len(got) != 10 {
			t.Fatalf("%s forwarded %v", mode, got)
		}
	}
}

// 2026-11-19: agents started from a pane in one workspace opened in whichever
// workspace was shown. relay-mcp names its own pane so Relay can place the
// tab beside it; an explicit placement is forwarded unchanged instead.
func TestLaunchAgentNamesTheCallingPaneOnlyWithoutAPlacement(t *testing.T) {
	s, _, bodies, done := stackServer(t)
	defer done()
	s.callerPane = "44444444-4444-4444-8444-444444444444"
	if code := callTool(s, "relay_launch_agent", launchArgs()); code != 0 {
		t.Fatal(code)
	}
	if got := (*bodies)[len(*bodies)-1]; got["callerPaneID"] != s.callerPane || len(got) != 9 {
		t.Fatalf("no placement forwarded %v", got)
	}
	args := launchArgs()
	args["anchor_tab_id"] = "33333333-3333-4333-8333-333333333333"
	if code := callTool(s, "relay_launch_agent", args); code != 0 {
		t.Fatal(code)
	}
	if got := (*bodies)[len(*bodies)-1]; got["callerPaneID"] != "" || got["anchorTabID"] == "" {
		t.Fatalf("explicit placement forwarded %v", got)
	}
}

func TestCallerPaneIsOnlyAValidPaneID(t *testing.T) {
	for value, want := range map[string]string{"": "", "not-a-uuid": "", "44444444-4444-4444-8444-444444444444": "44444444-4444-4444-8444-444444444444",
		"44444444-4444-4444-8444-444444444444\nx": ""} {
		if got := callerPaneFrom(value); got != want {
			t.Fatalf("%q -> %q", value, got)
		}
	}
}
