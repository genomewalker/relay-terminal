package subscriptionquota

import (
	"bytes"
	"context"
	"encoding/json"
	"path/filepath"
	"testing"
)

func TestConfiguredClaudeTeamIdentityIsNotOmitted(t *testing.T) {
	r := testReader(t)
	setIdentities(t, r)
	putPrivate(t, filepath.Join(r.home, ".relay/agent-accounts.json"), map[string]any{
		"version": 1, "accounts": []any{map[string]any{"provider": "claude", "label": "business", "dir": "~/.claude-team", "expect_plan": "Team"}},
	})
	putPrivate(t, filepath.Join(r.home, ".claude-team/.claude.json"), map[string]any{
		"oauthAccount": map[string]any{"accountUuid": "team-account", "organizationUuid": "team-org"}, "secret": "never-export-this",
	})
	scope := identityDigest([]any{"claude", "team-account", "team-org"})
	putPrivate(t, filepath.Join(r.home, ".local/share/relay/claude-status/session-team.json"), map[string]any{
		"session_id": "team-session", "account_scope": scope, "captured_at": captureTime(fixtureNow),
		"rate_limits": map[string]any{"five_hour": map[string]any{"used_percentage": 12}},
	})
	data, err := r.Read(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	var rows []map[string]any
	if err := json.Unmarshal(data, &rows); err != nil {
		t.Fatal(err)
	}
	foundTeam, foundDefault, foundMeter := false, false, false
	for _, row := range rows {
		if row["identity_only"] == true && row["account_label"] == "business" {
			foundTeam = row["account_scope"] == scope && row["configured_plan"] == "Team"
		}
		if row["identity_only"] == true && row["provider"] == "claude" && row["account_scope"] == r.accountScope("claude") {
			foundDefault = true
		}
		if row["account_scope"] == scope && object(row["observation"])["session_id"] == "team-session" {
			foundMeter = true
		}
	}
	if !foundTeam || !foundDefault || !foundMeter {
		t.Fatal("Team identity/meter or default account omitted")
	}
	if bytes.Contains(data, []byte("never-export-this")) {
		t.Fatal("identity inventory leaked private config")
	}
}

func TestConfiguredAccountWithoutIdentityRemainsExplicitlyUnavailable(t *testing.T) {
	r := testReader(t)
	putPrivate(t, filepath.Join(r.home, ".relay/agent-accounts.json"), map[string]any{
		"version": 1, "accounts": []any{map[string]any{"provider": "claude", "label": "business", "dir": "~/.claude-team"}},
	})
	putPrivate(t, filepath.Join(r.home, ".claude-team/.claude.json"), map[string]any{"oauthAccount": map[string]any{}})
	for _, row := range r.identities() {
		if row["account_label"] == "business" {
			if row["account_scope"] != nil || row["identity_only"] != true {
				t.Fatal("unverified account acquired identity")
			}
			return
		}
	}
	t.Fatal("configured account disappeared when meter unavailable")
}
