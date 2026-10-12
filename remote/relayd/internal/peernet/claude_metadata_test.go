package peernet

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestClaudeTeamMetadataIsNotLivenessAndRedactsPrompts(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, ".claude", "teams", "test")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	data := []byte(`{"name":"test","leadSessionId":"live","members":[{"agentId":"worker@team","name":"worker","agentType":"Explore","model":"test-model","prompt":"SECRET_DO_NOT_EXPORT","subscriptions":["private"]}]}`)
	if err := os.WriteFile(filepath.Join(dir, "config.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	if teams, _ := discoverClaudeTeams(home, nil); len(teams) != 0 {
		t.Fatal("dead leader accepted")
	}
	if teams, _ := discoverClaudeTeams(home, []Record{{Session: "live"}, {Session: "live"}}); len(teams) != 0 {
		t.Fatal("ambiguous leader accepted")
	}
	teams, partial := discoverClaudeTeams(home, []Record{{Session: "live"}})
	if len(teams) != 1 || len(teams[0].Members) != 1 || partial {
		t.Fatalf("unexpected result %+v", teams)
	}
	encoded, _ := json.Marshal(teams)
	if strings.Contains(string(encoded), "SECRET") || strings.Contains(string(encoded), "subscriptions") || strings.Contains(string(encoded), "active") {
		t.Fatal("private data or invented activity exported")
	}
}
