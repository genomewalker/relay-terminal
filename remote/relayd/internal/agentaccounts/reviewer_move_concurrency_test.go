// Root reviewer test from move-account-onboarding-review-20261022 (evidence
// 50e0da91), adapted to -b.
package agentaccounts

import (
	"encoding/json"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

const reviewerConcurrentSave = `{"userID":"reviewer-new-user","oauthAccount":{"accountUuid":"reviewer-new-identity"},"mcpServers":{"reviewer-new":{"command":"fixture-only"}},"projects":{"/work/repos/project":{"history":["reviewer-new-history"]}}}`

func reviewerProviderSave(t *testing.T, path string) {
	t.Helper()
	p := filepath.Join(filepath.Dir(path), ".reviewer-provider-save")
	if err := os.WriteFile(p, []byte(reviewerConcurrentSave), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(p, path); err != nil {
		t.Fatal(err)
	}
}

func reviewerAssertConcurrentSaveSurvived(t *testing.T, path string) {
	t.Helper()
	var d map[string]json.RawMessage
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &d); err != nil {
		t.Fatal(err)
	}
	var user string
	_ = json.Unmarshal(d["userID"], &user)
	if user != "reviewer-new-user" {
		t.Errorf("NON_ALLOWLISTED_SAVE_LOST: userID=%q, want concurrent userID", user)
	}
	var identity map[string]string
	_ = json.Unmarshal(d["oauthAccount"], &identity)
	if identity["accountUuid"] != "reviewer-new-identity" {
		t.Errorf("NON_ALLOWLISTED_SAVE_LOST: oauthAccount changed back to the stale target identity")
	}
	if d["mcpServers"] == nil {
		t.Errorf("NON_ALLOWLISTED_SAVE_LOST: new target mcpServers entry disappeared")
	}
	var projects map[string]map[string]json.RawMessage
	_ = json.Unmarshal(d["projects"], &projects)
	if projects[movePaneDir]["history"] == nil {
		t.Errorf("NON_ALLOWLISTED_SAVE_LOST: new target project history disappeared")
	}
}

// Adapted for -b: the plain-rename fallback is gone. The provider save
// lands at the commit point of the unsupported-exchange path (where the
// frozen patch renamed); the move must be refused and the save kept.
func TestReviewerMoveFallbackPreservesSaveAtCommitBoundary(t *testing.T) {
	home, path := moveFixture(t, `{"userID":"reviewer-old-user","oauthAccount":{"accountUuid":"reviewer-old-identity"}}`, 0600)
	exchange := launchStateExchange
	t.Cleanup(func() { launchStateExchange = exchange })
	raced := false
	launchStateExchange = func(a, b string) (bool, error) {
		raced = true
		reviewerProviderSave(t, b) // after sameContent, immediately before the commit
		return false, syscall.EINVAL
	}
	result, err := PrepareClaudeMove(home, "", "~/.claude-personal", movePaneDir)
	t.Logf("fallback: writer_called=%v result=%+v err=%v", raced, result, err)
	if !raced {
		t.Fatal("commit seam not reached")
	}
	if err == nil {
		t.Fatal("an unsupported exchange was not refused")
	}
	reviewerAssertConcurrentSaveSurvived(t, path)
}

func TestReviewerMoveExchangePreservesSaveAtCommitBoundary(t *testing.T) {
	home, path := moveFixture(t, `{"userID":"reviewer-old-user","oauthAccount":{"accountUuid":"reviewer-old-identity"}}`, 0600)
	exchange := launchStateExchange
	t.Cleanup(func() { launchStateExchange = exchange })
	raced := false
	launchStateExchange = func(a, b string) (bool, error) {
		if !raced {
			raced = true
			reviewerProviderSave(t, b)
		}
		return exchange(a, b)
	}
	result, err := PrepareClaudeMove(home, "", "~/.claude-personal", movePaneDir)
	t.Logf("exchange: writer_called=%v result=%+v err=%v", raced, result, err)
	if !raced {
		t.Fatal("exchange seam not reached")
	}
	if err == nil {
		t.Fatal("concurrent save was not refused")
	}
	reviewerAssertConcurrentSaveSurvived(t, path)
}
