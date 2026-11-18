package agentaccounts

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

// CodexLogin is which ChatGPT account a Codex folder's auth.json is logged
// in to. It is read from the local file only: the id_token's payload is
// decoded WITHOUT verifying its signature (nothing is authenticated with it,
// it only names the account), and no token, full email or key ever leaves
// this function. The folder label alone does not say which account Codex
// bills: on dandy-07 ~/.codex-personal held the business login for three
// days while ~20 "personal" panes ran in it.
type CodexLogin struct {
	// State is "chatgpt" (account known), "api_key", "missing" (no
	// auth.json: not logged in) or "unknown" (credential store, unreadable
	// or unrecognized file).
	State string `json:"state"`
	// AccountID is the full chatgpt_account_id. It is compared, stored by a
	// pin and never shown; Account is its 8-character display prefix.
	AccountID   string    `json:"-"`
	Account     string    `json:"account,omitempty"`
	Plan        string    `json:"plan,omitempty"`
	EmailDomain string    `json:"email_domain,omitempty"`
	Modified    time.Time `json:"modified,omitempty"`
	// Reason says why the state is unknown, as a fixed text.
	Reason string `json:"reason,omitempty"`
}

const authLimit = 1 << 20

var (
	codexAccountPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
	codexPlanPattern    = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,48}$`)
	domainPattern       = regexp.MustCompile(`^[A-Za-z0-9.-]{1,190}$`)
)

// AccountPrefix is the display form of an account id.
func AccountPrefix(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// ReadCodexLogin reads the login of the Codex folder root. It never fails:
// every problem is a state.
func ReadCodexLogin(root string) CodexLogin {
	if store := codexCredentialStore(root); store != "" && store != "file" {
		// keyring (or auto with a keyring entry): an auth.json there may be
		// stale, so it decides nothing.
		if store != "auto" {
			return CodexLogin{State: "unknown", Reason: "Codex keeps this login in the OS credential store"}
		}
		if _, err := os.Lstat(filepath.Join(root, "auth.json")); err != nil {
			return CodexLogin{State: "unknown", Reason: "Codex keeps this login in the OS credential store"}
		}
	}
	data, modified, err := readAuthFile(filepath.Join(root, "auth.json"))
	if errors.Is(err, os.ErrNotExist) {
		return CodexLogin{State: "missing"}
	}
	if err != nil {
		return CodexLogin{State: "unknown", Reason: "auth.json could not be read"}
	}
	login := parseCodexAuth(data)
	login.Modified = modified
	return login
}

// parseCodexAuth decodes auth.json's identity claims only.
func parseCodexAuth(data []byte) CodexLogin {
	var auth struct {
		Mode   string  `json:"auth_mode"`
		APIKey *string `json:"OPENAI_API_KEY"`
		Tokens *struct {
			IDToken   string `json:"id_token"`
			AccountID string `json:"account_id"`
		} `json:"tokens"`
	}
	if json.Unmarshal(data, &auth) != nil {
		return CodexLogin{State: "unknown", Reason: "auth.json is not valid JSON"}
	}
	if auth.Tokens == nil || auth.Tokens.IDToken == "" {
		if auth.APIKey != nil && *auth.APIKey != "" {
			return CodexLogin{State: "api_key"}
		}
		return CodexLogin{State: "unknown", Reason: "auth.json holds no ChatGPT login"}
	}
	claims, ok := idTokenClaims(auth.Tokens.IDToken)
	if !ok {
		return CodexLogin{State: "unknown", Reason: "the login's id_token could not be decoded"}
	}
	login := CodexLogin{State: "chatgpt"}
	id := claims.Auth.AccountID
	if id == "" {
		id = auth.Tokens.AccountID
	}
	if !codexAccountPattern.MatchString(id) {
		return CodexLogin{State: "unknown", Reason: "the login names no ChatGPT account"}
	}
	if other := auth.Tokens.AccountID; other != "" && other != id {
		// The two copies of the id disagree: neither is trusted.
		return CodexLogin{State: "unknown", Reason: "auth.json names two different ChatGPT accounts"}
	}
	login.AccountID, login.Account = id, AccountPrefix(id)
	if codexPlanPattern.MatchString(claims.Auth.Plan) {
		login.Plan = claims.Auth.Plan
	}
	if at := strings.LastIndexByte(claims.Email, '@'); at > 0 && domainPattern.MatchString(claims.Email[at+1:]) {
		login.EmailDomain = strings.ToLower(claims.Email[at+1:])
	}
	return login
}

type codexClaims struct {
	Email string `json:"email"`
	Auth  struct {
		AccountID string `json:"chatgpt_account_id"`
		Plan      string `json:"chatgpt_plan_type"`
	} `json:"https://api.openai.com/auth"`
}

// idTokenClaims decodes a JWT's payload. The signature is not verified.
func idTokenClaims(token string) (codexClaims, bool) {
	var claims codexClaims
	parts := strings.Split(token, ".")
	if len(parts) != 3 || len(parts[1]) > 64<<10 {
		return claims, false
	}
	payload, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(parts[1], "="))
	if err != nil || json.Unmarshal(payload, &claims) != nil {
		return claims, false
	}
	return claims, true
}

// readAuthFile reads a regular file owned by this user, without blocking on
// a FIFO. It follows a symbolic link, as Codex does.
func readAuthFile(path string) ([]byte, time.Time, error) {
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, time.Time{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || !ownedByUser(info) || info.Size() > authLimit {
		return nil, time.Time{}, errors.New("auth.json is not a private regular file")
	}
	data, err := io.ReadAll(io.LimitReader(file, authLimit+1))
	if err != nil || len(data) > authLimit {
		return nil, time.Time{}, errors.New("auth.json exceeds its limit")
	}
	return data, info.ModTime(), nil
}

// codexCredentialStore is config.toml's cli_auth_credentials_store ("" when
// unset, "unknown" when the file cannot be read).
func codexCredentialStore(root string) string {
	data, err := readBounded(filepath.Join(root, "config.toml"), 4<<20)
	if errors.Is(err, os.ErrNotExist) {
		return ""
	}
	if err != nil {
		return "unknown"
	}
	document, err := parseTOML(string(data))
	if err != nil {
		return "unknown"
	}
	value, present := document.root.values["cli_auth_credentials_store"]
	if !present {
		return ""
	}
	store, _ := value.(string)
	if store == "" {
		return "unknown"
	}
	return store
}

// LoginCheck compares a folder's login with the account its label is pinned
// to. Status is "match", "mismatch", "unpinned" (no pin for the label),
// "unknown" (pinned, login not readable: allowed, but flagged) or
// "unregistered" (the folder is no configured account).
type LoginCheck struct {
	Provider string     `json:"provider"`
	Label    string     `json:"label,omitempty"`
	Dir      string     `json:"dir,omitempty"`
	Expected string     `json:"expected,omitempty"`
	Login    CodexLogin `json:"login"`
	Status   string     `json:"status"`
}

// DecideLogin is the decision table. Only a pinned label whose folder is
// logged in to a different account (or to an API key) is a mismatch; a
// missing or unreadable login fails open as "unknown".
func DecideLogin(expected string, login CodexLogin) string {
	switch {
	case expected == "":
		return "unpinned"
	case login.State == "chatgpt" && login.AccountID == expected:
		return "match"
	case login.State == "chatgpt" || login.State == "api_key":
		return "mismatch"
	}
	return "unknown"
}

// CheckCodexLogin checks the Codex folder an override selects ("" = the
// default folder) against this host's registry.
func CheckCodexLogin(home string, registry Registry, override string) LoginCheck {
	root := defaultRoot(home, "codex")
	if override != "" {
		root = override
	}
	check := LoginCheck{Provider: "codex", Login: ReadCodexLogin(root), Status: "unregistered"}
	resolved := resolvedRoot(root)
	for _, account := range registry.Accounts {
		if account.Provider != "codex" || resolvedRoot(account.Root(home)) != resolved {
			continue
		}
		check.Label, check.Dir = account.Label, account.Dir
		if check.Dir == "" {
			check.Dir = "~/.codex"
		}
		check.Expected = AccountPrefix(account.ExpectAccount)
		check.Status = DecideLogin(account.ExpectAccount, check.Login)
		break
	}
	return check
}

// Refusal is the error a mismatch refuses a launch, move or restart with.
func (c LoginCheck) Refusal() error {
	if c.Status != "mismatch" {
		return nil
	}
	actual := "an API key"
	if c.Login.State == "chatgpt" {
		actual = c.Login.Account + "…"
		if c.Login.Plan != "" {
			actual += " (plan " + c.Login.Plan + ")"
		}
	}
	return fmt.Errorf("Codex account %s (%s) is pinned to ChatGPT account %s… but its auth.json is logged in to %s. "+
		"Nothing was started. Log in again with CODEX_HOME=%s codex login, or re-pin the label in Settings",
		c.Label, c.Dir, c.Expected, actual, c.Dir)
}

// AdmitCodexLogin refuses to start Codex in a pinned folder logged in to
// another account. A registry that cannot be read refuses nothing here; the
// folder admission reports it.
func AdmitCodexLogin(home, override string) error {
	registry, err := Load(home)
	if err != nil {
		return nil
	}
	return CheckCodexLogin(home, registry, override).Refusal()
}

// PinLogin pins a Codex label to the ChatGPT account its folder is logged in
// to now. It is an explicit user action; nothing pins a label silently.
func PinLogin(home string, registry Registry, provider, label string) (Registry, error) {
	account, ok := registry.Find(provider, label)
	if !ok || provider != "codex" {
		return Registry{}, errors.New("only a configured Codex account can be pinned to its login")
	}
	login := ReadCodexLogin(account.Root(home))
	if login.State != "chatgpt" {
		return Registry{}, errors.New("this Codex folder has no readable ChatGPT login to pin; nothing was changed")
	}
	return setPin(home, registry, provider, label, login.AccountID)
}

// UnpinLogin removes a label's pin.
func UnpinLogin(home string, registry Registry, provider, label string) (Registry, error) {
	if _, ok := registry.Find(provider, label); !ok {
		return Registry{}, errors.New("unknown account")
	}
	return setPin(home, registry, provider, label, "")
}

func setPin(home string, registry Registry, provider, label, id string) (Registry, error) {
	changed := Registry{Version: registryVersion}
	for _, account := range registry.Accounts {
		if account.Provider == provider && account.Label == label {
			account.ExpectAccount = id
		}
		changed.Accounts = append(changed.Accounts, account)
	}
	return Save(home, changed)
}
