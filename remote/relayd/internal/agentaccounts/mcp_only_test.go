package agentaccounts

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestMCPOnlySyncPreservesAccountAndRefusesStaleReview(t *testing.T) {
	home := t.TempDir()
	account := Account{Provider: "claude", Label: "business", Dir: "~/.claude-team", MCPExclude: []string{"exclude"}}
	main := filepath.Join(home, ".claude.json")
	target := filepath.Join(account.Root(home), ".claude.json")
	writeFile(t, main, `{"mcpServers":{"relay":{"command":"relay"},"exclude":{"command":"private"}}}`)
	writeFile(t, target, `{"keep":{"user":"identity"},"mcpServers":{"own":{"command":"own"}}}`)
	preview, err := PreviewMCPExact(home, account)
	if err != nil {
		t.Fatal(err)
	}
	before := string(mustRead(t, target))
	if _, err := SyncMCPOnlyReviewed(home, account, time.Now(), "wrong"); err == nil {
		t.Fatal("stale review accepted")
	}
	if got := string(mustRead(t, target)); got != before {
		t.Fatal("stale review modified target")
	}
	result, err := SyncMCPOnlyReviewed(home, account, time.Now(), preview.Fingerprint)
	if err != nil {
		t.Fatal(err)
	}
	if result.MCPCount != 1 {
		t.Fatalf("unexpected count: %+v", result)
	}
	value := readJSON(t, target)
	if _, ok := value["keep"]; !ok {
		t.Fatal("account identity field lost")
	}
	servers, ok := value["mcpServers"].(map[string]any)
	if !ok {
		t.Fatal("missing servers")
	}
	if _, ok := servers["relay"]; !ok {
		t.Fatal("reviewed server missing")
	}
	if _, ok := servers["exclude"]; ok {
		t.Fatal("excluded server copied")
	}
	if _, ok := servers["own"]; !ok {
		t.Fatal("existing server lost")
	}
	for _, name := range []string{"skills", "settings.json", "projects"} {
		if _, err := os.Lstat(filepath.Join(account.Root(home), name)); !os.IsNotExist(err) {
			t.Fatalf("unexpected shared item %s: %v", name, err)
		}
	}
	if strings.Contains(string(mustRead(t, target)), "private") {
		t.Fatal("excluded content leaked")
	}
}

func TestMCPOnlySyncRejectsConflictingServerWithoutChanges(t *testing.T) {
	home := t.TempDir()
	account := Account{Provider: "claude", Label: "business", Dir: "~/.claude-team"}
	source := filepath.Join(home, ".claude.json")
	target := filepath.Join(account.Root(home), ".claude.json")
	writeFile(t, source, `{"mcpServers":{"relay":{"command":"source"}}}`)
	writeFile(t, target, `{"mcpServers":{"relay":{"command":"target"}}}`)
	preview, err := PreviewMCPExact(home, account)
	if err != nil {
		t.Fatal(err)
	}
	before := string(mustRead(t, target))
	if _, err := SyncMCPOnlyReviewed(home, account, time.Now(), preview.Fingerprint); err == nil {
		t.Fatal("conflicting server accepted")
	}
	if got := string(mustRead(t, target)); got != before {
		t.Fatal("conflict modified target")
	}
}

func TestExistingPreviewFingerprintDoesNotBindServerCommand(t *testing.T) {
	home := t.TempDir()
	account := Account{Provider: "claude", Label: "business", Dir: "~/.claude-team"}
	source := filepath.Join(home, ".claude.json")
	writeFile(t, source, `{"mcpServers":{"relay":{"command":"first"}}}`)
	a, err := PreviewMCP(home, account)
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, source, `{"mcpServers":{"relay":{"command":"changed"}}}`)
	b, err := PreviewMCP(home, account)
	if err != nil {
		t.Fatal(err)
	}
	if a.Fingerprint != b.Fingerprint {
		t.Fatal("preview contract changed; reevaluate this known limitation")
	}
}

func TestExactReviewRejectsCommandChangeAndTargetChange(t *testing.T) {
	home := t.TempDir()
	account := Account{Provider: "claude", Label: "business", Dir: "~/.claude-team"}
	source := filepath.Join(home, ".claude.json")
	target := filepath.Join(account.Root(home), ".claude.json")
	writeFile(t, source, `{"mcpServers":{"relay":{"command":"original","env":{"TOKEN":"secret"}}}}`)
	writeFile(t, target, `{"untouched":true}`)
	preview, err := PreviewMCPExact(home, account)
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, source, `{"mcpServers":{"relay":{"command":"changed","env":{"TOKEN":"secret"}}}}`)
	before := string(mustRead(t, target))
	if _, err := SyncMCPOnlyReviewed(home, account, time.Now(), preview.Fingerprint); err == nil {
		t.Fatal("changed command accepted")
	}
	if string(mustRead(t, target)) != before {
		t.Fatal("rejected sync modified target")
	}
	writeFile(t, source, `{"mcpServers":{"relay":{"command":"original","env":{"TOKEN":"different"}}}}`)
	if _, err := SyncMCPOnlyReviewed(home, account, time.Now(), preview.Fingerprint); err == nil {
		t.Fatal("changed secret value accepted")
	}
	account.MCPExclude = []string{"relay"}
	if _, err := SyncMCPOnlyReviewed(home, account, time.Now(), preview.Fingerprint); err == nil {
		t.Fatal("changed exclusions accepted")
	}
}

// A real long-lived subprocess models a provider retaining its startup
// configuration in memory. It does not cooperate with Relay's account lock.
func TestMCPOnlyRunningProcessFixture(t *testing.T) {
	if os.Getenv("RELAY_MCP_RUNNING_FIXTURE") != "1" {
		return
	}
	before, err := os.ReadFile(os.Getenv("CLAUDE_CONFIG_DIR") + "/.claude.json")
	if err != nil {
		os.Exit(2)
	}
	fmt.Println("ready")
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		if scanner.Text() == "snapshot" {
			fmt.Println(base64.StdEncoding.EncodeToString(before))
		}
	}
	os.Exit(0)
}

func runningMCPProcessFixture(t *testing.T, root string) func() {
	t.Helper()
	before := string(mustRead(t, filepath.Join(root, ".claude.json")))
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	t.Cleanup(cancel)
	command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestMCPOnlyRunningProcessFixture$")
	command.Env = append(os.Environ(), "RELAY_MCP_RUNNING_FIXTURE=1", "CLAUDE_CONFIG_DIR="+root)
	input, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	output, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		input.Close()
		if err := command.Wait(); err != nil {
			t.Errorf("disposable provider fixture failed: %v", err)
		}
	})
	reader := bufio.NewReader(output)
	ready, err := reader.ReadString('\n')
	if err != nil || ready != "ready\n" {
		t.Fatalf("provider fixture not ready: %q %v", ready, err)
	}
	return func() {
		t.Helper()
		if _, err := fmt.Fprintln(input, "snapshot"); err != nil {
			t.Fatal(err)
		}
		retained, err := reader.ReadString('\n')
		if err != nil {
			t.Fatalf("running provider did not survive save: %v", err)
		}
		decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(retained))
		if err != nil || string(decoded) != before {
			t.Fatalf("running provider's retained configuration changed: %v", err)
		}
	}
}

func TestMCPOnlySyncSavesFutureLaunchConfigWithoutChangingRunningState(t *testing.T) {
	home := t.TempDir()
	account := Account{Provider: "claude", Label: "business", Dir: "~/.claude-team"}
	source := filepath.Join(home, ".claude.json")
	target := filepath.Join(account.Root(home), ".claude.json")
	writeFile(t, source, `{"hasCompletedOnboarding":true,"mcpServers":{"relay":{"command":"relay"}}}`)
	writeFile(t, target, `{"keep":true}`)
	preview, err := PreviewMCPExact(home, account)
	if err != nil {
		t.Fatal(err)
	}
	assertRunningConfigurationUnchanged := runningMCPProcessFixture(t, account.Root(home))
	defer assertRunningConfigurationUnchanged()
	result, err := SyncMCPOnlyReviewed(home, account, time.Now(), preview.Fingerprint)
	if err != nil || result.MCP != MergeUpdated {
		t.Fatalf("future-launch save failed: %+v %v", result, err)
	}
	value := readJSON(t, target)
	if value["keep"] != true || value["hasCompletedOnboarding"] != nil || value["mcpServers"] == nil {
		t.Fatal("MCP-only save changed running/account state or omitted MCP")
	}
}

func TestExactReviewIsSingleUseAndFreshPreviewIsDifferent(t *testing.T) {
	home := t.TempDir()
	account := Account{Provider: "claude", Label: "business", Dir: "~/.claude-team"}
	source := filepath.Join(home, ".claude.json")
	target := filepath.Join(account.Root(home), ".claude.json")
	writeFile(t, source, `{"mcpServers":{"relay":{"command":"relay"}}}`)
	writeFile(t, target, `{"existing":true}`)
	one, err := PreviewMCPExact(home, account)
	if err != nil {
		t.Fatal(err)
	}
	two, err := PreviewMCPExact(home, account)
	if err != nil {
		t.Fatal(err)
	}
	if one.Fingerprint == two.Fingerprint {
		t.Fatal("reviews share token")
	}
	if _, err := SyncMCPOnlyReviewed(home, account, time.Now(), one.Fingerprint); err != nil {
		t.Fatal(err)
	}
	if _, err := SyncMCPOnlyReviewed(home, account, time.Now(), one.Fingerprint); err == nil {
		t.Fatal("review replay accepted")
	}
	if _, err := SyncMCPOnlyReviewed(home, account, time.Now(), two.Fingerprint); err != nil {
		t.Fatal(err)
	}
}

func TestExactPreviewHostRequestBindsCommandWithoutExposingIt(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	source := filepath.Join(home, ".claude.json")
	writeFile(t, source, `{"mcpServers":{"relay":{"command":"secret-command","env":{"KEY":"synthetic-secret"}}}}`)
	request := Request{Action: "mcp_preview_exact", Provider: "claude", Label: "personal"}
	a, err := Handle(request, nil)
	if err != nil {
		t.Fatal(err)
	}
	if a.MCPPreview == nil || len(a.MCPPreview.Fingerprint) != 129 {
		t.Fatalf("missing exact preview: %+v", a.MCPPreview)
	}
	encoded, err := json.Marshal(a.MCPPreview)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "secret-command") || strings.Contains(string(encoded), "synthetic-secret") {
		t.Fatal("preview exposed a value")
	}
	writeFile(t, source, `{"mcpServers":{"relay":{"command":"changed","env":{"KEY":"synthetic-secret"}}}}`)
	b, err := Handle(request, nil)
	if err != nil {
		t.Fatal(err)
	}
	if b.MCPPreview == nil || a.MCPPreview.Fingerprint == b.MCPPreview.Fingerprint {
		t.Fatal("token was reused")
	}
}

func TestMCPOnlyHostRequestsRequireExactReviewAndKeepScope(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	source := filepath.Join(home, ".claude.json")
	target := filepath.Join(home, ".claude-personal", ".claude.json")
	writeFile(t, source, `{"hasCompletedOnboarding":true,"mcpServers":{"relay":{"command":"relay"}}}`)
	writeFile(t, target, `{"own":true}`)
	preview, err := Handle(Request{Action: "mcp_preview_exact", Provider: "claude", Label: "personal"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if preview.MCPPreview == nil {
		t.Fatal("preview missing")
	}
	request := Request{Action: "mcp_sync_only", Provider: "claude", Label: "personal", PreviewFingerprint: preview.MCPPreview.Fingerprint}
	result, err := Handle(request, nil)
	if err != nil || result.Sync == nil {
		t.Fatalf("sync: %+v %v", result.Sync, err)
	}
	got := readJSON(t, target)
	if got["own"] != true {
		t.Fatal("existing value lost")
	}
	if _, ok := got["hasCompletedOnboarding"]; ok {
		t.Fatal("onboarding was modified")
	}
	replay, err := Handle(request, nil)
	if err != nil || replay.Sync == nil || replay.Sync.MCP != MergeRefused || replay.Sync.Error == "" {
		t.Fatalf("review replay not reported as refusal: %+v %v", replay.Sync, err)
	}
}

func TestExactPreviewRefusesPendingRemovalWithoutRecovery(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	writeFile(t, filepath.Join(home, ".claude.json"), `{"mcpServers":{"relay":{"command":"relay"}}}`)
	pending := filepath.Join(removalsDir(home), "unrecognized-pending-record")
	writeFile(t, pending, "do not change")
	_, err := Handle(Request{Action: "mcp_preview_exact", Provider: "claude", Label: "personal"}, nil)
	if err == nil {
		t.Fatal("preview proceeded with pending removal state")
	}
	if string(mustRead(t, pending)) != "do not change" {
		t.Fatal("preview altered pending removal")
	}
}

func TestMCPOnlyHostRequestSavesFutureLaunchConfiguration(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	account := Account{Provider: "claude", Label: "personal", Dir: "~/.claude-personal"}
	target := filepath.Join(account.Root(home), ".claude.json")
	writeFile(t, filepath.Join(home, ".claude.json"), `{"mcpServers":{"relay":{"command":"relay"}}}`)
	writeFile(t, target, `{"existing":true}`)
	preview, err := Handle(Request{Action: "mcp_preview_exact", Provider: "claude", Label: "personal"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	assertRunningConfigurationUnchanged := runningMCPProcessFixture(t, account.Root(home))
	defer assertRunningConfigurationUnchanged()
	r, err := Handle(Request{Action: "mcp_sync_only", Provider: "claude", Label: "personal", PreviewFingerprint: preview.MCPPreview.Fingerprint}, nil)
	if err != nil || r.Sync == nil || r.Sync.MCP != MergeUpdated || r.Sync.Error != "" {
		t.Fatalf("future-launch save failed: %+v %v", r.Sync, err)
	}
	value := readJSON(t, target)
	if value["existing"] != true || value["mcpServers"] == nil {
		t.Fatal("future-launch save lost account fields")
	}
}

func TestMCPOnlyConcurrentProviderSaveIsPreservedAndNotAcknowledged(t *testing.T) {
	home := t.TempDir()
	account := Account{Provider: "claude", Label: "business", Dir: "~/.claude-team"}
	source := filepath.Join(home, ".claude.json")
	target := filepath.Join(account.Root(home), ".claude.json")
	writeFile(t, source, `{"mcpServers":{"relay":{"command":"relay"}}}`)
	writeFile(t, target, `{"own":"before"}`)
	preview, err := PreviewMCPExact(home, account)
	if err != nil {
		t.Fatal(err)
	}
	previous := afterLaunchStateSwap
	t.Cleanup(func() { afterLaunchStateSwap = previous })
	afterLaunchStateSwap = func(path string) {
		if path == target {
			writeFile(t, target, `{"own":"concurrent-provider-save"}`)
		}
	}
	result, err := SyncMCPOnlyReviewed(home, account, time.Now(), preview.Fingerprint)
	if err == nil || result.MCP != "outcome_unknown" {
		t.Fatalf("concurrent save acknowledged: %+v %v", result, err)
	}
	if string(mustRead(t, target)) != `{"own":"concurrent-provider-save"}` {
		t.Fatal("concurrent provider save lost")
	}
}
