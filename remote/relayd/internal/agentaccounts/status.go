package agentaccounts

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Status describes one account without reading credential material. Logged-in
// state comes from the existence of the provider's credential file or from
// the provider's own status command, never from a token's contents.
type Status struct {
	Provider string `json:"provider"`
	Label    string `json:"label"`
	Dir      string `json:"dir"`
	Root     string `json:"root"`
	Default  bool   `json:"default"`
	Exists   bool   `json:"exists"`
	// LoggedIn is "yes", "no" or "unknown".
	LoggedIn string `json:"logged_in"`
	// Method is "file", "keychain", "chatgpt", "api_key" or "" when unknown.
	Method string `json:"method,omitempty"`
	// Email, Plan and IdentityKey are what Claude's status command reports
	// (Codex reports them with its usage).
	Email       string `json:"email,omitempty"`
	Plan        string `json:"plan,omitempty"`
	IdentityKey string `json:"identity_key,omitempty"`
	// Probe is "ok" when the provider's status command answered, "failed"
	// when it was asked and did not, and "" when it was not asked.
	Probe string `json:"probe,omitempty"`
	// ProbeReason says why a check failed, as a fixed text (an exit status,
	// or how long it was given). Provider output is never forwarded.
	ProbeReason string `json:"probe_reason,omitempty"`
	// Workspace is the organization Claude reports; WorkspaceKey is equal
	// for two accounts exactly when the provider reports the same
	// organization (Codex reports it with its usage).
	Workspace    string       `json:"workspace,omitempty"`
	WorkspaceKey string       `json:"workspace_key,omitempty"`
	Links        []LinkResult `json:"links,omitempty"`
	// The account's sync settings, echoed so Settings can edit them.
	ShareHistory bool     `json:"share_history,omitempty"`
	MCPExclude   []string `json:"mcp_exclude,omitempty"`
	// The workspace and plan the user expects here, echoed from the
	// registry.
	ExpectWorkspace string `json:"expect_workspace,omitempty"`
	ExpectPlan      string `json:"expect_plan,omitempty"`
	ExpectKey       string `json:"expect_key,omitempty"`
	// Model and Effort are the account's launch defaults; DefaultsError
	// says why its defaults file could not be used.
	Model         string `json:"model,omitempty"`
	Effort        string `json:"effort,omitempty"`
	DefaultsError string `json:"defaults_error,omitempty"`
}

// Prober runs a provider's non-secret status command with one account
// selected. It returns stdout only; tests substitute it.
type Prober func(ctx context.Context, provider, override string) ([]byte, error)

// List checks every account at once, so one slow provider delays the answer
// by at most its own time limit.
func List(home string, registry Registry, probe Prober) []Status {
	result := make([]Status, len(registry.Accounts))
	var wait sync.WaitGroup
	for index, account := range registry.Accounts {
		wait.Add(1)
		go func() {
			defer wait.Done()
			result[index] = AccountStatus(home, account, probe)
		}()
	}
	wait.Wait()
	return result
}

func AccountStatus(home string, account Account, probe Prober) Status {
	root := account.Root(home)
	status := Status{Provider: account.Provider, Label: account.Label, Dir: account.Dir, Root: root,
		Default: account.Dir == "", LoggedIn: "unknown", ShareHistory: account.ShareHistory, MCPExclude: account.MCPExclude,
		ExpectWorkspace: account.ExpectWorkspace, ExpectPlan: account.ExpectPlan, ExpectKey: account.ExpectKey}
	if status.Dir == "" {
		status.Dir = "~/." + account.Provider
	}
	if info, err := os.Stat(root); err == nil && info.IsDir() {
		status.Exists = true
	}
	if !status.Exists {
		status.LoggedIn = "no"
		return status
	}
	if defaults, err := ReadModelDefaults(account.Provider, root); err != nil {
		status.DefaultsError = printable(err.Error(), 120)
	} else {
		status.Model, status.Effort = defaults.Model, defaults.Effort
	}
	if !status.Default {
		names := claudeLinks
		if account.Provider == "codex" {
			names = append(append([]string{}, codexLinks...), "config.toml")
		}
		if account.ShareHistory {
			names = append(append([]string{}, names...), historyLinks[account.Provider]...)
		}
		for _, name := range names {
			status.Links = append(status.Links, LinkResult{Name: name,
				State: linkState(filepath.Join(defaultRoot(home, account.Provider), name), filepath.Join(root, name))})
		}
	}
	// Existence only: the credential file is never opened.
	credential := ".credentials.json"
	if account.Provider == "codex" {
		credential = "auth.json"
	}
	if _, err := os.Lstat(filepath.Join(root, credential)); err == nil {
		status.LoggedIn, status.Method = "yes", "file"
	}
	if probe == nil {
		return status
	}
	ctx, cancel := context.WithTimeout(context.Background(), probeLimit)
	defer cancel()
	output, err := probe(ctx, account.Provider, account.Override(home))
	status.Probe = "failed"
	if err != nil {
		status.ProbeReason = shortReason(err)
		return status
	}
	status.ProbeReason = "the provider's status answer was not recognized"
	if account.Provider == "claude" {
		var report struct {
			LoggedIn         *bool  `json:"loggedIn"`
			Email            string `json:"email"`
			OrgID            string `json:"orgId"`
			OrgName          string `json:"orgName"`
			SubscriptionType string `json:"subscriptionType"`
		}
		if json.Unmarshal(output, &report) == nil && report.LoggedIn != nil {
			status.Probe, status.ProbeReason = "ok", ""
			if *report.LoggedIn {
				status.LoggedIn = "yes"
				if status.Method == "" {
					status.Method = "keychain"
				}
				if emailPattern.MatchString(report.Email) {
					status.Email = report.Email
					status.IdentityKey = identityKey("claude", report.OrgID, report.Email)
				}
				status.Plan = planName(report.SubscriptionType)
				status.Workspace = printable(report.OrgName, 80)
				status.WorkspaceKey = workspaceKey("claude", report.OrgID)
			} else {
				status.LoggedIn, status.Method = "no", ""
			}
		}
		return status
	}
	// Codex prints one line; a masked API key suffix is never forwarded.
	line := strings.TrimSpace(string(bytes.SplitN(output, []byte{'\n'}, 2)[0]))
	if strings.HasPrefix(line, "Logged in using ChatGPT") || strings.HasPrefix(line, "Logged in using an API key") ||
		strings.HasPrefix(line, "Not logged in") {
		status.ProbeReason = ""
	}
	switch {
	case strings.HasPrefix(line, "Logged in using ChatGPT"):
		status.LoggedIn, status.Method, status.Probe = "yes", "chatgpt", "ok"
	case strings.HasPrefix(line, "Logged in using an API key"):
		status.LoggedIn, status.Method, status.Probe = "yes", "api_key", "ok"
	case strings.HasPrefix(line, "Not logged in"):
		status.LoggedIn, status.Method, status.Probe = "no", "", "ok"
	}
	return status
}

var emailPattern = regexp.MustCompile(`^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,190}$`)

func linkState(source, destination string) string {
	info, err := os.Lstat(destination)
	if err != nil {
		if _, sourceErr := os.Lstat(source); sourceErr != nil {
			return LinkMissingMain
		}
		return "missing"
	}
	if info.Mode()&os.ModeSymlink == 0 {
		return "own_file"
	}
	if target, err := os.Readlink(destination); err == nil && target == source {
		return LinkLinked
	}
	return LinkForeign
}

// ProviderProbe runs `claude auth status --json` or `codex login status` with
// only the account variable changed. It is called only for an existing
// directory: Claude's status command creates files in its config directory.
func ProviderProbe(ctx context.Context, provider, override string) ([]byte, error) {
	name, args := "claude", []string{"auth", "status", "--json"}
	variable := "CLAUDE_CONFIG_DIR"
	if provider == "codex" {
		name, args, variable = "codex", []string{"login", "status"}, "CODEX_HOME"
	} else if provider != "claude" {
		return nil, errors.New("unsupported provider")
	}
	executable, err := ProviderExecutable(name)
	if err != nil {
		return nil, err
	}
	command := exec.CommandContext(ctx, executable, args...)
	defer isolate(command)()
	command.WaitDelay = waitLimit
	command.Env = accountEnvironment(variable, override)
	command.Stdin = nil
	var output bytes.Buffer
	started := time.Now()
	if provider == "codex" {
		// Codex reports login state on stderr, and exits non-zero when
		// logged out. Only the recognized status line is ever used.
		command.Stdout, command.Stderr = &output, &output
		err := command.Run()
		if ctx.Err() != nil || (output.Len() == 0 && err != nil) {
			return nil, failure(ctx, name, started, err)
		}
		return bounded(output.Bytes())
	}
	// Claude's JSON answer is what counts, whatever its exit status. Its
	// stderr is discarded.
	command.Stdout = &output
	if err := command.Run(); ctx.Err() != nil || (err != nil && len(bytes.TrimSpace(output.Bytes())) == 0) {
		return nil, failure(ctx, name, started, err)
	}
	return bounded(output.Bytes())
}

func bounded(data []byte) ([]byte, error) {
	if len(data) > 65536 {
		return nil, errors.New("status output exceeds its limit")
	}
	return data, nil
}

// ProviderExecutable resolves the provider CLI like relayd's agent launch:
// RELAY_<NAME>_BIN when set (the version ~/.local/bin/<name> links to once
// that file is gone; see ConfiguredExecutableFallback), else PATH and then ~/.local/bin,
// /opt/homebrew/bin and /usr/local/bin, without Relay's shim directory and
// without relayd itself, so a status probe never re-enters Relay's launcher.
func ProviderExecutable(name string) (string, error) {
	self, _ := os.Executable()
	selfInfo, _ := os.Stat(self)
	if configured := strings.TrimSpace(os.Getenv("RELAY_" + strings.ToUpper(name) + "_BIN")); configured != "" {
		if fallback, ok := ConfiguredExecutableFallback(name, configured); ok {
			return fallback, nil
		}
		info, err := os.Stat(configured)
		if err != nil || !filepath.IsAbs(configured) || !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 ||
			(selfInfo != nil && os.SameFile(info, selfInfo)) {
			return "", errors.New("configured " + name + " executable is not runnable")
		}
		return configured, nil
	}
	shims := ""
	directories := filepath.SplitList(os.Getenv("PATH"))
	if home, err := os.UserHomeDir(); err == nil {
		shims = filepath.Join(home, ".local", "share", "relay", "shims")
		// A daemon started by launchd or a supervisor has a minimal PATH;
		// these are where the providers' own installers put their CLIs.
		directories = append(directories, filepath.Join(home, ".local", "bin"))
	}
	directories = append(directories, "/opt/homebrew/bin", "/usr/local/bin")
	for _, directory := range directories {
		if directory == "" || !filepath.IsAbs(directory) || filepath.Clean(directory) == shims {
			continue
		}
		candidate := filepath.Join(directory, name)
		info, err := os.Stat(candidate)
		if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
			continue
		}
		if selfInfo != nil && os.SameFile(info, selfInfo) {
			continue
		}
		return candidate, nil
	}
	return "", errors.New(name + " is not installed on this host")
}
