package agentaccounts

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	codexLimitsLine  = `{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":4,"windowDurationMins":300,"resetsAt":1792649609},"secondary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1792874456}},"accountId":"ORG-ONE"}}`
	codexAccountLine = `{"id":3,"result":{"account":{"type":"chatgpt","email":"ana@example.org","planType":"pro"},"requiresOpenaiAuth":true}}`
)

func TestCodexUsageSessionReportsWhoIsLoggedIn(t *testing.T) {
	home := t.TempDir()
	for _, dir := range []string{".codex", ".codex-personal"} {
		if err := os.MkdirAll(filepath.Join(home, dir), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	answers := map[string]string{
		"":                                     codexAccountLine + "\n" + codexLimitsLine,
		filepath.Join(home, ".codex-personal"): codexLimitsLine + "\n" + codexAccountLine,
	}
	runner := func(_ context.Context, _ string, override string) ([]byte, error) {
		return []byte(answers[override]), nil
	}
	usage := ReadUsage(home, []Account{{Provider: "codex", Label: "work"}, {Provider: "codex", Label: "personal", Dir: "~/.codex-personal"}}, runner, time.Now())
	for _, reading := range usage {
		if reading.Status != UsageOK || len(reading.Windows) != 2 || reading.Email != "ana@example.org" || reading.Plan != "pro" || reading.IdentityKey == "" {
			t.Fatalf("%+v", reading)
		}
	}
	// The same user in the same workspace is the same identity, whichever
	// directory holds the login.
	if usage[0].IdentityKey != usage[1].IdentityKey {
		t.Fatal("one identity got two keys")
	}
	data, _ := json.Marshal(usage)
	if strings.Contains(string(data), "ORG-ONE") || strings.Contains(string(data), "accountId") {
		t.Fatalf("the provider's account id was forwarded: %s", data)
	}
	other := strings.Replace(codexLimitsLine, "ORG-ONE", "ORG-TWO", 1)
	if parseCodexIdentity([]byte(other+"\n"+codexAccountLine)).IdentityKey == usage[0].IdentityKey {
		t.Fatal("one email in two workspaces must be two identities")
	}
	for line, want := range map[string]Identity{
		`{"id":3,"result":{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}}`:                     {Plan: "api_key"},
		`{"id":3,"result":{"account":null,"requiresOpenaiAuth":true}}`:                                  {},
		`{"id":3,"result":{"account":{"type":"chatgpt","email":"not an email","planType":"pro"}}}`:      {},
		`{"id":3,"result":{"account":{"type":"chatgpt","email":"b@example.org","planType":"Pro <b>"}}}`: {Email: "b@example.org", IdentityKey: identityKey("codex", "", "b@example.org")},
		`{"id":3,"error":{"code":-32600,"message":"no"}}`:                                               {},
	} {
		if got := parseCodexIdentity([]byte(line)); got != want {
			t.Fatalf("%s: %+v", line, got)
		}
	}
}

func TestClaudeStatusReportsPlanAndIdentity(t *testing.T) {
	home := t.TempDir()
	for _, dir := range []string{".claude", ".claude-personal"} {
		if err := os.MkdirAll(filepath.Join(home, dir), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	report := `{"loggedIn":true,"authMethod":"claude.ai","email":"Ana@Example.org","orgId":"org-1","orgName":"Lab","subscriptionType":"max"}`
	probe := func(context.Context, string, string) ([]byte, error) { return []byte(report), nil }
	work := AccountStatus(home, Account{Provider: "claude", Label: "work"}, probe)
	personal := AccountStatus(home, Account{Provider: "claude", Label: "personal", Dir: "~/.claude-personal"}, probe)
	if work.LoggedIn != "yes" || work.Email != "Ana@Example.org" || work.Plan != "max" || work.IdentityKey == "" || work.IdentityKey != personal.IdentityKey {
		t.Fatalf("%+v %+v", work, personal)
	}
	if work.IdentityKey != identityKey("claude", "org-1", "ana@example.org") {
		t.Fatal("email case must not split one identity")
	}
	data, _ := json.Marshal(work)
	if strings.Contains(string(data), "org-1") {
		t.Fatalf("the organization id was forwarded: %s", data)
	}
}

func TestResponseLinesCollectEveryAnswerInAnyOrder(t *testing.T) {
	seen := map[string]bool{}
	matches := func(line []byte) bool {
		var message struct {
			ID json.RawMessage `json:"id"`
		}
		if json.Unmarshal(line, &message) != nil || (string(message.ID) != "2" && string(message.ID) != "3") || seen[string(message.ID)] {
			return false
		}
		seen[string(message.ID)] = true
		return true
	}
	input := "{\"id\":1}\n{\"method\":\"note\"}\n{\"id\":3,\"result\":{}}\n{\"method\":\"note\"}\n{\"id\":3,\"result\":\"again\"}\n{\"id\":2,\"result\":{}}\n"
	lines, err := readResponseLines(strings.NewReader(input), matches, 2)
	if err != nil || string(lines) != "{\"id\":3,\"result\":{}}\n{\"id\":2,\"result\":{}}" {
		t.Fatalf("%q %v", lines, err)
	}
	if _, err := readResponseLines(strings.NewReader("{\"id\":2}\n"), func([]byte) bool { return true }, 2); err == nil {
		t.Fatal("a missing answer must fail")
	}
}

// A probe that was asked for says whether it answered; one not asked says nothing.
func TestStatusSaysWhetherTheProviderProbeAnswered(t *testing.T) {
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, ".claude"), 0o700); err != nil {
		t.Fatal(err)
	}
	work := Account{Provider: "claude", Label: "work"}
	if status := AccountStatus(home, work, nil); status.Probe != "" || status.LoggedIn != "unknown" {
		t.Fatalf("unprobed %+v", status)
	}
	failing := func(context.Context, string, string) ([]byte, error) {
		return nil, errors.New("claude did not answer in time")
	}
	if status := AccountStatus(home, work, failing); status.Probe != "failed" || status.LoggedIn != "unknown" || status.Email != "" {
		t.Fatalf("failed %+v", status)
	}
	garbage := func(context.Context, string, string) ([]byte, error) { return []byte("{"), nil }
	if status := AccountStatus(home, work, garbage); status.Probe != "failed" {
		t.Fatalf("garbage %+v", status)
	}
	answered := func(context.Context, string, string) ([]byte, error) { return []byte(`{"loggedIn":false}`), nil }
	if status := AccountStatus(home, work, answered); status.Probe != "ok" || status.LoggedIn != "no" {
		t.Fatalf("answered %+v", status)
	}
}
