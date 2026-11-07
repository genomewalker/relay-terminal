package peernet

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// Each account was capped at 16 teams but accounts were concatenated without
// a total cap. On dandy-07 (16 from ~/.claude, 5 from ~/.claude-team) the
// helper reported 21 teams, the app's decoder refuses more than 16, and the
// whole discovery failed with 503, so no desktop route to any pane on the host
// could be created. The total is capped and marked truncated.
func TestClaudeTeamsAreCappedAcrossAccounts(t *testing.T) {
	home := t.TempDir()
	records := []Record{}
	for _, account := range []string{".claude", ".claude-personal"} {
		for i := 0; i < 16; i++ {
			lead := fmt.Sprintf("%s-lead-%02d", account[1:], i)
			dir := filepath.Join(home, account, "teams", fmt.Sprintf("team-%02d", i))
			if err := os.MkdirAll(dir, 0700); err != nil {
				t.Fatal(err)
			}
			data := fmt.Sprintf(`{"name":"t%02d","leadSessionId":%q,"members":[]}`, i, lead)
			if err := os.WriteFile(filepath.Join(dir, "config.json"), []byte(data), 0600); err != nil {
				t.Fatal(err)
			}
			records = append(records, Record{Session: lead})
		}
	}
	teams, truncated := discoverClaudeTeams(home, records)
	if len(teams) != 16 || !truncated {
		t.Fatalf("got %d teams truncated=%v, want 16 and truncated", len(teams), truncated)
	}
}
