package agentlaunch

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestClaudeFreshArgumentsPreserveConfigurationAndRemoveHistory(t *testing.T) {
	input := []string{"--model", "sonnet", "--settings", "config with spaces.json", "--permission-mode", "plan", "--resume", "550e8400-e29b-41d4-a716-446655440000", "--fork-session", "--session-id", "11111111-1111-4111-8111-111111111111", "--continue", "--bg", "--tools=Read,Edit", "previous request"}
	result := FreshArguments("claude", input)
	expected := []string{"--model", "sonnet", "--settings", "config with spaces.json", "--permission-mode", "plan", "--tools=Read,Edit"}
	if !result.Reusable || !reflect.DeepEqual(result.Fresh, expected) || !reflect.DeepEqual(result.Prompts, []string{"previous request"}) {
		t.Fatalf("incorrect fresh configuration: %#v", result)
	}
	if input[0] != "--model" {
		t.Fatal("input mutated")
	}
}

func TestCodexConfigShortFlagIsNotClaudeContinue(t *testing.T) {
	result := FreshArguments("codex", []string{"-c", "model=sol", "resume", "old-id", "--last", "--all", "--profile", "relay-terminal", "-s", "read-only", "old prompt"})
	expected := []string{"-c", "model=sol", "--profile", "relay-terminal", "-s", "read-only"}
	if !result.Reusable || !reflect.DeepEqual(result.Fresh, expected) {
		t.Fatalf("configuration not preserved: %#v", result)
	}
}

func TestCodexTransportAndDelayedHistorySelectorAreNotReplayed(t *testing.T) {
	id := "01a0e66a-8cae-72d0-9d35-bd5c5c881c77"
	input := []string{"--model", "gpt-6-sol", "resume", "--remote", "unix:///home/user/.codex/app-server-control/app-server-control.sock", id}
	result := FreshArguments("codex", input)
	if !result.Reusable || !reflect.DeepEqual(result.Fresh, []string{"--model", "gpt-6-sol"}) || len(result.Prompts) != 0 {
		t.Fatalf("transport or history selector leaked into fresh launch: %#v", result)
	}
	if result := FreshArguments("codex", []string{"resume", "--remote", "unix:///tmp/control.sock", "not-a-uuid"}); result.Reusable {
		t.Fatalf("ambiguous selector replayed: %#v", result)
	}
	if result := FreshArguments("codex", []string{"--remote-auth-token-env", "TOKEN_NAME"}); result.Reusable {
		t.Fatalf("remote bearer transport silently replayed: %#v", result)
	}
}

func TestHistoryLookingOptionValueIsPreserved(t *testing.T) {
	result := FreshArguments("claude", []string{"--append-system-prompt", "--resume", "--model", "sonnet", "--continue"})
	if !result.Reusable || !reflect.DeepEqual(result.Fresh, []string{"--append-system-prompt", "--resume", "--model", "sonnet"}) {
		t.Fatalf("option value stripped: %#v", result)
	}
}

func TestUnknownAndAmbiguousOptionsCannotBeReplayed(t *testing.T) {
	for _, input := range [][]string{{"--future-option", "--resume"}, {"--resume", "search words"}, {"--resume=old-id"}, {"--from-pr", "123"}, {"-rOLD"}, {"--cloud", "task"}} {
		if result := FreshArguments("claude", input); result.Reusable {
			t.Fatalf("ambiguous input reusable: %#v", input)
		}
	}
}

func TestDoubleDashPromptCannotBecomeLaunchFlags(t *testing.T) {
	result := FreshArguments("claude", []string{"--model=sonnet", "--", "--resume", "old query"})
	if !result.Reusable || !reflect.DeepEqual(result.Fresh, []string{"--model=sonnet"}) || len(result.Prompts) != 2 {
		t.Fatalf("prompt parsed as options: %#v", result)
	}
}

func TestPrivateSnapshotRetainsExactRequestedAndEffectiveVectors(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "launches")
	requested := []string{"--model", "sonnet", "--continue"}
	effective := append([]string{"--settings", "/private/relay-hooks.json"}, requested...)
	path, err := Save(dir, "claude", "/usr/bin/claude", "/project", "pane-1", "123", requested, effective)
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var snapshot Snapshot
	if err := json.Unmarshal(data, &snapshot); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(snapshot.RequestedArgs, requested) || !reflect.DeepEqual(snapshot.EffectiveArgs, effective) || !snapshot.Arguments.Reusable {
		t.Fatal("raw launch vectors lost")
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0600 {
		t.Fatal("snapshot is not private")
	}
}

func TestSymlinkOrPublicDirectoryIsRefused(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "target")
	if err := os.Mkdir(target, 0700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if _, err := Save(link, "claude", "/usr/bin/claude", "/project", "pane", "1", nil, nil); err == nil {
		t.Fatal("symlink directory admitted")
	}
	if err := os.Chmod(target, 0755); err != nil {
		t.Fatal(err)
	}
	if _, err := Save(target, "claude", "/usr/bin/claude", "/project", "pane", "1", nil, nil); err == nil {
		t.Fatal("public directory admitted")
	}
}
