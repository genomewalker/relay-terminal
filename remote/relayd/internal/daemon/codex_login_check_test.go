package daemon

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeCodexLoginFixture(t *testing.T, root, account, plan string) {
	t.Helper()
	payload, _ := json.Marshal(map[string]any{"https://api.openai.com/auth": map[string]any{
		"chatgpt_account_id": account, "chatgpt_plan_type": plan}})
	token := "e30." + base64.RawURLEncoding.EncodeToString(payload) + ".sig"
	data, _ := json.Marshal(map[string]any{"tokens": map[string]any{"id_token": token, "account_id": account}})
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "auth.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
}

// A move into, or a restart in, a pinned folder holding another login is
// refused before any input; an unpinned folder is only reported.
func TestCodexLoginRefusalAndObservation(t *testing.T) {
	home := t.TempDir()
	personal := filepath.Join(home, ".codex-personal")
	writeCodexLoginFixture(t, personal, "4fea6400-aaaa", "pro")
	registry := `{"version":1,"accounts":[{"provider":"codex","label":"work","dir":""},` +
		`{"provider":"codex","label":"personal","dir":"~/.codex-personal","expect_account":"4fea6400-aaaa"}]}`
	if err := os.MkdirAll(filepath.Join(home, ".relay"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, ".relay", "agent-accounts.json"), []byte(registry), 0o600); err != nil {
		t.Fatal(err)
	}
	if refusal := codexLoginRefusal(home, personal); refusal != "" {
		t.Fatalf("matching login refused: %s", refusal)
	}
	if refusal := codexLoginRefusal(home, ""); refusal != "" {
		t.Fatalf("unpinned folder refused: %s", refusal)
	}
	writeCodexLoginFixture(t, personal, "02bb1caa-bbbb", "self_serve_business_prolite")
	refusal := codexLoginRefusal(home, personal)
	if !strings.Contains(refusal, "4fea6400") || !strings.Contains(refusal, "02bb1caa") || strings.Contains(refusal, "bbbb") {
		t.Fatalf("refusal = %q", refusal)
	}
	observed := codexLoginObservation(home, personal, float64(time.Now().Add(-time.Hour).Unix()))
	for key, want := range map[string]any{"status": "mismatch", "label": "personal", "expected": "4fea6400",
		"account": "02bb1caa", "plan": "self_serve_business_prolite", "started_before_login_change": true} {
		if got := observed.Get(key); got != want {
			t.Errorf("%s = %v, want %v", key, got, want)
		}
	}
	if got := codexLoginObservation(home, personal, -1).Get("started_before_login_change"); got != nil {
		t.Errorf("unknown start reported %v", got)
	}
}
