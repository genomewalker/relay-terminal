package agentaccounts

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	personalID = "4fea6400-0000-4000-8000-000000000001"
	businessID = "02bb1caa-0000-4000-8000-000000000002"
)

// fakeJWT is an unsigned token with Codex's identity claims.
func fakeJWT(t *testing.T, account, plan, email string) string {
	t.Helper()
	payload, err := json.Marshal(map[string]any{"email": email,
		"https://api.openai.com/auth": map[string]any{"chatgpt_account_id": account, "chatgpt_plan_type": plan}})
	if err != nil {
		t.Fatal(err)
	}
	encode := base64.RawURLEncoding.EncodeToString
	return encode([]byte(`{"alg":"none"}`)) + "." + encode(payload) + ".c2lnbmF0dXJl"
}

func writeAuth(t *testing.T, root string, value any) {
	t.Helper()
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "auth.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func chatgptAuth(t *testing.T, account, plan string) map[string]any {
	return map[string]any{"OPENAI_API_KEY": nil, "tokens": map[string]any{
		"id_token": fakeJWT(t, account, plan, "someone.private@example.org"), "access_token": "secret-access-token",
		"refresh_token": "secret-refresh-token", "account_id": account}}
}

func TestReadCodexLoginChatGPT(t *testing.T) {
	root := t.TempDir()
	writeAuth(t, root, chatgptAuth(t, businessID, "self_serve_business_prolite"))
	login := ReadCodexLogin(root)
	if login.State != "chatgpt" || login.AccountID != businessID || login.Account != "02bb1caa" ||
		login.Plan != "self_serve_business_prolite" || login.EmailDomain != "example.org" || login.Modified.IsZero() {
		t.Fatalf("login = %+v", login)
	}
	// Nothing secret or personal is serialized: no token, no full email, no full id.
	data, _ := json.Marshal(login)
	for _, secret := range []string{"secret-access-token", "secret-refresh-token", "someone.private", businessID} {
		if strings.Contains(string(data), secret) {
			t.Fatalf("serialized login leaks %q: %s", secret, data)
		}
	}
}

func TestReadCodexLoginAPIKeyMissingAndStore(t *testing.T) {
	root := t.TempDir()
	if login := ReadCodexLogin(root); login.State != "missing" {
		t.Fatalf("missing file = %+v", login)
	}
	writeAuth(t, root, map[string]any{"OPENAI_API_KEY": "sk-test", "tokens": nil})
	if login := ReadCodexLogin(root); login.State != "api_key" || login.AccountID != "" {
		t.Fatalf("api key = %+v", login)
	}
	if err := os.WriteFile(filepath.Join(root, "auth.json"), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if login := ReadCodexLogin(root); login.State != "unknown" {
		t.Fatalf("invalid json = %+v", login)
	}
	// A credential store other than the file: even an existing auth.json decides nothing.
	writeAuth(t, root, chatgptAuth(t, personalID, "pro"))
	if err := os.WriteFile(filepath.Join(root, "config.toml"), []byte("cli_auth_credentials_store = \"keyring\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if login := ReadCodexLogin(root); login.State != "unknown" || login.AccountID != "" {
		t.Fatalf("keyring = %+v", login)
	}
	if err := os.WriteFile(filepath.Join(root, "config.toml"), []byte("cli_auth_credentials_store = \"file\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if login := ReadCodexLogin(root); login.State != "chatgpt" || login.AccountID != personalID || login.Plan != "pro" {
		t.Fatalf("file store = %+v", login)
	}
}

func TestReadCodexLoginRefusesDisagreeingIDs(t *testing.T) {
	root := t.TempDir()
	auth := chatgptAuth(t, personalID, "pro")
	auth["tokens"].(map[string]any)["account_id"] = businessID
	writeAuth(t, root, auth)
	if login := ReadCodexLogin(root); login.State != "unknown" {
		t.Fatalf("disagreeing ids = %+v", login)
	}
	writeAuth(t, root, map[string]any{"tokens": map[string]any{"id_token": "not-a-jwt"}})
	if login := ReadCodexLogin(root); login.State != "unknown" {
		t.Fatalf("bad jwt = %+v", login)
	}
}

func TestDecideLogin(t *testing.T) {
	personal := CodexLogin{State: "chatgpt", AccountID: personalID}
	business := CodexLogin{State: "chatgpt", AccountID: businessID}
	for _, c := range []struct {
		expected string
		login    CodexLogin
		want     string
	}{
		{"", business, "unpinned"},
		{personalID, personal, "match"},
		{personalID, business, "mismatch"},
		{personalID, CodexLogin{State: "api_key"}, "mismatch"},
		{personalID, CodexLogin{State: "missing"}, "unknown"},
		{personalID, CodexLogin{State: "unknown"}, "unknown"},
	} {
		if got := DecideLogin(c.expected, c.login); got != c.want {
			t.Errorf("DecideLogin(%q, %+v) = %q, want %q", c.expected, c.login, got, c.want)
		}
	}
}

// The incident: ~/.codex-personal holds the business login.
func TestCheckCodexLoginRefusesPinnedFolderWithOtherAccount(t *testing.T) {
	home := t.TempDir()
	writeAuth(t, filepath.Join(home, ".codex"), chatgptAuth(t, businessID, "self_serve_business_prolite"))
	personalRoot := filepath.Join(home, ".codex-personal")
	writeAuth(t, personalRoot, chatgptAuth(t, personalID, "pro"))
	registry := DefaultRegistry()
	registry, err := PinLogin(home, registry, "codex", "personal")
	if err != nil {
		t.Fatal(err)
	}
	if saved, _ := Load(home); saved.Accounts[3].ExpectAccount != personalID {
		t.Fatalf("pin not saved: %+v", saved.Accounts[3])
	}
	if err := AdmitCodexLogin(home, personalRoot); err != nil {
		t.Fatalf("matching login refused: %v", err)
	}
	// The default folder is unpinned: allowed, reported yellow.
	if check := CheckCodexLogin(home, registry, ""); check.Status != "unpinned" || check.Label != "work" {
		t.Fatalf("default = %+v", check)
	}
	writeAuth(t, personalRoot, chatgptAuth(t, businessID, "self_serve_business_prolite"))
	check := CheckCodexLogin(home, registry, personalRoot)
	if check.Status != "mismatch" || check.Expected != "4fea6400" || check.Login.Account != "02bb1caa" {
		t.Fatalf("check = %+v", check)
	}
	err = AdmitCodexLogin(home, personalRoot)
	if err == nil {
		t.Fatal("mismatched login admitted")
	}
	for _, want := range []string{"personal", "~/.codex-personal", "4fea6400", "02bb1caa", "self_serve_business_prolite"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("refusal %q lacks %q", err, want)
		}
	}
	if strings.Contains(err.Error(), personalID) || strings.Contains(err.Error(), "example.org") {
		t.Errorf("refusal leaks a full id or email: %q", err)
	}
	// A configure from a client that does not know the pin keeps it.
	kept := KeepExpectations(registry, DefaultRegistry())
	if kept.Accounts[3].ExpectAccount != personalID {
		t.Fatalf("configure dropped the pin: %+v", kept.Accounts[3])
	}
	if registry, err = UnpinLogin(home, registry, "codex", "personal"); err != nil || registry.Accounts[3].ExpectAccount != "" {
		t.Fatalf("unpin = %+v, %v", registry.Accounts[3], err)
	}
	if err := AdmitCodexLogin(home, personalRoot); err != nil {
		t.Fatalf("unpinned folder refused: %v", err)
	}
}

func TestPinLoginNeedsAChatGPTLogin(t *testing.T) {
	home := t.TempDir()
	writeAuth(t, filepath.Join(home, ".codex-personal"), map[string]any{"OPENAI_API_KEY": "sk-test"})
	if _, err := PinLogin(home, DefaultRegistry(), "codex", "personal"); err == nil {
		t.Fatal("pinned an API-key login")
	}
	if _, err := PinLogin(home, DefaultRegistry(), "claude", "personal"); err == nil {
		t.Fatal("pinned a Claude account")
	}
}

func TestReadCodexLoginModesAndStores(t *testing.T) {
	root := t.TempDir()
	both := chatgptAuth(t, personalID, "pro")
	both["OPENAI_API_KEY"] = "sk-test"
	writeAuth(t, root, both)
	// Without auth_mode a ChatGPT login is what Codex uses.
	if login := ReadCodexLogin(root); login.State != "chatgpt" || login.AccountID != personalID {
		t.Fatalf("tokens and key = %+v", login)
	}
	both["auth_mode"] = "apikey"
	writeAuth(t, root, both)
	if login := ReadCodexLogin(root); login.State != "api_key" {
		t.Fatalf("auth_mode apikey = %+v", login)
	}
	writeAuth(t, root, chatgptAuth(t, personalID, "pro"))
	config := filepath.Join(root, "config.toml")
	for _, c := range []struct{ text, want string }{
		{"cli_auth_credentials_store = \"auto\"\n", "unknown"},
		// The strict reader refuses multi-line strings; the key is still found.
		{"cli_auth_credentials_store = 'keyring' # os store\nnotes = \"\"\"\nx\n\"\"\"\n", "unknown"},
		{"notes = \"\"\"\nx\n\"\"\"\ncli_auth_credentials_store = \"file\"\n", "chatgpt"},
		{"notes = \"\"\"\nx\n\"\"\"\n[profiles.a]\ncli_auth_credentials_store = \"keyring\"\n", "chatgpt"},
	} {
		if err := os.WriteFile(config, []byte(c.text), 0o600); err != nil {
			t.Fatal(err)
		}
		if login := ReadCodexLogin(root); login.State != c.want {
			t.Errorf("config %q: login = %+v, want %s", c.text, login, c.want)
		}
	}
}

// Only pin_login sets a pin: a configure cannot write one, not even a
// display prefix copied from a status row.
func TestConfigureCannotSetAPin(t *testing.T) {
	current := DefaultRegistry()
	incoming := DefaultRegistry()
	incoming.Accounts[3].ExpectAccount = "4fea6400"
	if kept := KeepExpectations(current, incoming); kept.Accounts[3].ExpectAccount != "" {
		t.Fatalf("configure set a pin: %+v", kept.Accounts[3])
	}
	current.Accounts[3].ExpectAccount = personalID
	incoming.Accounts[3].ExpectAccount = businessID
	if kept := KeepExpectations(current, incoming); kept.Accounts[3].ExpectAccount != personalID {
		t.Fatalf("configure replaced a pin: %+v", kept.Accounts[3])
	}
}
