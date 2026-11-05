package agentaccounts

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Usage is what a provider CLI itself reports about an account's plan
// limits. Only window percentages and reset times are kept; anything the CLI
// cannot report is "unknown", never estimated.
type Usage struct {
	Provider string        `json:"provider"`
	Label    string        `json:"label"`
	Status   string        `json:"status"`
	Reason   string        `json:"reason,omitempty"`
	Source   string        `json:"source,omitempty"`
	ReadAt   string        `json:"read_at"`
	Windows  []UsageWindow `json:"windows,omitempty"`
	// Who the provider says this account is (Codex, from the same
	// app-server session as the limits). Empty when it did not say.
	Identity
}

// Identity is what a provider CLI reports about whose account it uses: the
// email, the plan's name and a key that is equal for two accounts exactly
// when the provider reports the same user and organization for both. The
// key is a hash; the provider's own account ids are not forwarded.
type Identity struct {
	Email       string `json:"email,omitempty"`
	Plan        string `json:"plan,omitempty"`
	IdentityKey string `json:"identity_key,omitempty"`
	// WorkspaceKey is equal for two accounts exactly when the provider
	// reports the same workspace (organization) for both, whatever the
	// email.
	WorkspaceKey string `json:"workspace_key,omitempty"`
}

func identityKey(provider, organization, email string) string {
	if email == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(provider + "\x00" + organization + "\x00" + strings.ToLower(email)))
	return hex.EncodeToString(sum[:8])
}

// workspaceKey hashes a provider's organization or workspace account id; ""
// when the provider did not report one.
func workspaceKey(provider, organization string) string {
	if organization == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(provider + "\x00workspace\x00" + organization))
	return hex.EncodeToString(sum[:8])
}

var planPattern = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,23}$`)

// planName keeps a plan name the provider reported, never free text.
func planName(value string) string {
	if planPattern.MatchString(value) && value != "unknown" {
		return value
	}
	return ""
}

type UsageWindow struct {
	Name          string  `json:"name"`
	UsedPercent   float64 `json:"used_percent"`
	ResetsAt      string  `json:"resets_at,omitempty"`
	WindowMinutes int     `json:"window_minutes,omitempty"`
}

const (
	UsageOK      = "ok"
	UsageUnknown = "unknown"
	claudeSource = "claude get_usage"
	codexSource  = "codex app-server"
)

// UsageRunner starts the provider's own CLI with only the account variable
// changed and returns its one response line. Tests substitute it.
type UsageRunner func(ctx context.Context, provider, override string) ([]byte, error)

// ReadUsage asks each account's provider CLI for its plan limits. Accounts
// whose directory does not exist are never probed.
func ReadUsage(home string, accounts []Account, run UsageRunner, now time.Time) []Usage {
	result := make([]Usage, len(accounts))
	var wait sync.WaitGroup
	for index, account := range accounts {
		result[index] = Usage{Provider: account.Provider, Label: account.Label, Status: UsageUnknown,
			ReadAt: now.UTC().Format(time.RFC3339)}
		if info, err := os.Stat(account.Root(home)); err != nil || !info.IsDir() {
			result[index].Reason = "account directory does not exist"
			continue
		}
		wait.Add(1)
		go func(index int, account Account) {
			defer wait.Done()
			ctx, cancel := context.WithTimeout(context.Background(), usageLimit)
			defer cancel()
			line, err := run(ctx, account.Provider, account.Override(home))
			usage := &result[index]
			if err != nil {
				usage.Reason = shortReason(err)
				return
			}
			if account.Provider == "claude" {
				usage.Source = claudeSource
				usage.Windows, usage.Reason = parseClaudeUsage(line)
			} else {
				usage.Source = codexSource
				usage.Windows, usage.Reason = parseCodexUsage(line)
				usage.Identity = parseCodexIdentity(line)
			}
			if len(usage.Windows) > 0 {
				usage.Status, usage.Reason = UsageOK, ""
			} else if usage.Reason == "" {
				usage.Reason = "the provider reported no usage windows"
			}
		}(index, account)
	}
	wait.Wait()
	return result
}

func shortReason(err error) string {
	return withheld(err.Error())
}

func parseClaudeUsage(line []byte) ([]UsageWindow, string) {
	var message struct {
		Type     string `json:"type"`
		Response struct {
			Subtype   string `json:"subtype"`
			RequestID string `json:"request_id"`
			Response  *struct {
				SubscriptionType string          `json:"subscription_type"`
				Limits           json.RawMessage `json:"limits"`
				Available        *bool           `json:"rate_limits_available"`
				RateLimits       *struct {
					FiveHour json.RawMessage `json:"five_hour"`
					SevenDay json.RawMessage `json:"seven_day"`
					OAuth    json.RawMessage `json:"seven_day_oauth_apps"`
					Opus     json.RawMessage `json:"seven_day_opus"`
					Sonnet   json.RawMessage `json:"seven_day_sonnet"`
					Cowork   json.RawMessage `json:"seven_day_cowork"`
					Omelette json.RawMessage `json:"seven_day_omelette"`
				} `json:"rate_limits"`
			} `json:"response"`
		} `json:"response"`
	}
	if len(line) > 64<<10 {
		return nil, "Claude usage exceeds the input limit"
	}
	decoder := json.NewDecoder(bytes.NewReader(line))
	decoder.DisallowUnknownFields()
	var trailing any
	if decoder.Decode(&message) != nil || decoder.Decode(&trailing) != io.EOF || message.Response.Subtype != "success" || message.Response.Response == nil {
		return nil, "Claude did not report usage"
	}
	report := message.Response.Response
	if report.Available == nil || !*report.Available || report.RateLimits == nil {
		return nil, "Claude reports no plan limits for this account"
	}
	var windows []UsageWindow
	for _, window := range []struct {
		name    string
		minutes int
		value   json.RawMessage
	}{{"five_hour", 300, report.RateLimits.FiveHour}, {"seven_day", 10080, report.RateLimits.SevenDay},
		{"seven_day_oauth_apps", 10080, report.RateLimits.OAuth}, {"seven_day_opus", 10080, report.RateLimits.Opus},
		{"seven_day_sonnet", 10080, report.RateLimits.Sonnet}, {"seven_day_cowork", 10080, report.RateLimits.Cowork},
		{"seven_day_omelette", 10080, report.RateLimits.Omelette}} {
		if len(window.value) == 0 || string(window.value) == "null" {
			continue
		}
		parsed, err := parseClaudeQuotaWindow(window.value)
		if err != nil {
			return nil, "Claude reported an invalid quota window"
		}
		windows = append(windows, UsageWindow{Name: window.name, UsedPercent: parsed.UsedPercent,
			ResetsAt: parsed.ResetsAt, WindowMinutes: window.minutes})
	}
	return windows, ""
}

// Strict at the authoritative window boundary. An unknown field must not be
// mistaken for a recognized quota. used_dollars is known, non-quota metadata.
func parseClaudeQuotaWindow(data []byte) (UsageWindow, error) {
	var window struct {
		Utilization    *float64        `json:"utilization"`
		UsedPercentage *float64        `json:"used_percentage"`
		ResetsAt       json.RawMessage `json:"resets_at"`
		UsedDollars    json.RawMessage `json:"used_dollars"`
	}
	bad := errors.New("invalid Claude quota window")
	if len(data) > 4096 {
		return UsageWindow{}, bad
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&window) != nil {
		return UsageWindow{}, bad
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return UsageWindow{}, bad
	}
	percent := window.Utilization
	if percent == nil {
		percent = window.UsedPercentage
	}
	if percent == nil || math.IsNaN(*percent) || math.IsInf(*percent, 0) || *percent < 0 || *percent > 100 ||
		(window.Utilization != nil && window.UsedPercentage != nil && *window.Utilization != *window.UsedPercentage) {
		return UsageWindow{}, bad
	}
	var text string
	var reset time.Time
	if json.Unmarshal(window.ResetsAt, &text) == nil {
		reset, _ = time.Parse(time.RFC3339Nano, text)
		if reset.IsZero() {
			seconds, err := strconv.ParseFloat(text, 64)
			if err == nil && !math.IsNaN(seconds) && !math.IsInf(seconds, 0) && seconds > 0 && seconds < 253402300800 {
				reset = time.Unix(int64(seconds), int64((seconds-math.Floor(seconds))*1e9))
			}
		}
	} else {
		var seconds float64
		if json.Unmarshal(window.ResetsAt, &seconds) == nil && seconds > 0 && seconds < 253402300800 {
			reset = time.Unix(int64(seconds), int64((seconds-math.Floor(seconds))*1e9))
		}
	}
	if reset.IsZero() || reset.Unix() <= 0 || reset.Unix() >= 253402300800 {
		return UsageWindow{}, bad
	}
	return UsageWindow{UsedPercent: *percent, ResetsAt: reset.UTC().Format(time.RFC3339)}, nil
}

// codexResponse is the app-server's answer with the given id among the
// response lines ProviderUsage returns.
func codexResponse(lines []byte, id string) []byte {
	for _, line := range bytes.Split(lines, []byte{'\n'}) {
		var message struct {
			ID json.RawMessage `json:"id"`
		}
		if json.Unmarshal(line, &message) == nil && string(message.ID) == id {
			return line
		}
	}
	return nil
}

// parseCodexIdentity reads account/read: a ChatGPT login's email and plan.
// An API key login reports neither; the key then stays empty.
func parseCodexIdentity(lines []byte) Identity {
	var account, limits struct {
		Result *struct {
			Account *struct {
				Type     string `json:"type"`
				Email    string `json:"email"`
				PlanType string `json:"planType"`
			} `json:"account"`
			AccountID string `json:"accountId"`
		} `json:"result"`
	}
	if json.Unmarshal(codexResponse(lines, "3"), &account) != nil || account.Result == nil || account.Result.Account == nil {
		return Identity{}
	}
	reported := account.Result.Account
	if reported.Type == "apiKey" {
		return Identity{Plan: "api_key"}
	}
	if reported.Type != "chatgpt" || !emailPattern.MatchString(reported.Email) {
		return Identity{}
	}
	organization := ""
	if json.Unmarshal(codexResponse(lines, "2"), &limits) == nil && limits.Result != nil {
		organization = limits.Result.AccountID
	}
	return Identity{Email: reported.Email, Plan: planName(reported.PlanType),
		IdentityKey: identityKey("codex", organization, reported.Email), WorkspaceKey: workspaceKey("codex", organization)}
}

func parseCodexUsage(lines []byte) ([]UsageWindow, string) {
	line := codexResponse(lines, "2")
	var message struct {
		Error  json.RawMessage `json:"error"`
		Result *struct {
			RateLimits *struct {
				Primary   *codexWindow `json:"primary"`
				Secondary *codexWindow `json:"secondary"`
			} `json:"rateLimits"`
		} `json:"result"`
	}
	if json.Unmarshal(line, &message) != nil || len(message.Error) > 0 || message.Result == nil {
		return nil, "Codex did not report rate limits"
	}
	if message.Result.RateLimits == nil {
		return nil, "Codex reports no rate limits for this account"
	}
	var windows []UsageWindow
	for _, window := range []struct {
		name  string
		value *codexWindow
	}{{"primary", message.Result.RateLimits.Primary}, {"secondary", message.Result.RateLimits.Secondary}} {
		if window.value == nil || window.value.UsedPercent == nil || *window.value.UsedPercent < 0 || *window.value.UsedPercent > 1000 {
			continue
		}
		usage := UsageWindow{Name: window.name, UsedPercent: *window.value.UsedPercent}
		if window.value.WindowMinutes != nil && *window.value.WindowMinutes > 0 && *window.value.WindowMinutes < 1<<20 {
			usage.WindowMinutes = *window.value.WindowMinutes
		}
		if window.value.ResetsAt != nil && *window.value.ResetsAt > 0 {
			usage.ResetsAt = time.Unix(*window.value.ResetsAt, 0).UTC().Format(time.RFC3339)
		}
		windows = append(windows, usage)
	}
	return windows, ""
}

type codexWindow struct {
	UsedPercent   *float64 `json:"usedPercent"`
	WindowMinutes *int     `json:"windowDurationMins"`
	ResetsAt      *int64   `json:"resetsAt"`
}

func normalizeTime(value string) string {
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return ""
	}
	return parsed.UTC().Format(time.RFC3339)
}

// ProviderUsage runs the provider's own usage interface: Claude Code's
// get_usage control request (no settings, hooks, MCP servers or session
// persistence) or Codex's app-server account/rateLimits/read. Relay sends
// no request of its own to the provider and never reads its credentials.
func ProviderUsage(ctx context.Context, provider, override string) ([]byte, error) {
	var name, variable string
	var args, input []string
	var matches func(line []byte) bool
	// Every answer in want must arrive; they are returned one per line.
	want := 1
	switch provider {
	case "claude":
		name, variable = "claude", "CLAUDE_CONFIG_DIR"
		args = []string{"-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
			"--setting-sources", "", "--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands"}
		input = []string{
			`{"type":"control_request","request_id":"u1","request":{"subtype":"initialize"}}`,
			`{"type":"control_request","request_id":"u2","request":{"subtype":"get_usage","skip_behaviors":true}}`,
		}
		matches = func(line []byte) bool {
			var message struct {
				Type     string `json:"type"`
				Response struct {
					RequestID string `json:"request_id"`
				} `json:"response"`
			}
			return json.Unmarshal(line, &message) == nil && message.Type == "control_response" && message.Response.RequestID == "u2"
		}
	case "codex":
		name, variable = "codex", "CODEX_HOME"
		args = []string{"app-server"}
		input = []string{
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"relay","version":"1"}}}`,
			`{"jsonrpc":"2.0","method":"initialized"}`,
			`{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}`,
			// Who is logged in, from the same session as the limits.
			`{"jsonrpc":"2.0","id":3,"method":"account/read","params":{}}`,
		}
		seen := map[string]bool{}
		want = 2
		matches = func(line []byte) bool {
			var message struct {
				ID json.RawMessage `json:"id"`
			}
			if json.Unmarshal(line, &message) != nil || (string(message.ID) != "2" && string(message.ID) != "3") || seen[string(message.ID)] {
				return false
			}
			seen[string(message.ID)] = true
			return true
		}
	default:
		return nil, errors.New("unsupported provider")
	}
	executable, err := ProviderExecutable(name)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	command := exec.CommandContext(ctx, executable, args...)
	defer isolate(command)()
	// Ending the session, on time or after the answer, is SIGTERM first so
	// Claude removes its sessions/<pid>.json and .key records; SIGKILL after
	// usageExitLimit is the fallback (and isolate's end on return).
	terminateGently(command)
	command.WaitDelay = usageExitLimit
	command.Dir = os.TempDir()
	command.Env = accountEnvironment(variable, override)
	// Stderr is discarded: it can contain credential material.
	stdin, err := command.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		return nil, err
	}
	started := time.Now()
	if err := command.Start(); err != nil {
		return nil, failure(ctx, name, started, err)
	}
	// A child that inherited stdout must not hold the read open past the
	// time limit: closing the read end ends the read below.
	go func() {
		<-ctx.Done()
		stdout.Close()
	}()
	// Stdin stays open until the answer arrives: both CLIs stop on EOF.
	go func() {
		for _, line := range input {
			if _, err := io.WriteString(stdin, line+"\n"); err != nil {
				return
			}
		}
	}()
	line, readErr := readResponseLines(stdout, matches, want)
	timedOut := ctx.Err() != nil
	var timeout error
	if timedOut {
		// Named before the SIGTERM grace, so the reason keeps the limit.
		timeout = timeoutError(name, started)
	}
	// Both CLIs stop on EOF and exit by themselves; Claude then removes its
	// session records. One that does not exit within usageExitLimit is ended.
	stdin.Close()
	exited := make(chan error, 1)
	go func() { exited <- command.Wait() }()
	var waitErr error
	select {
	case waitErr = <-exited:
	case <-time.After(usageExitLimit):
		cancel()
		waitErr = <-exited
	}
	switch {
	case readErr == nil:
		return line, nil
	case timedOut:
		return nil, timeout
	case errors.Is(readErr, io.EOF):
		if waitErr != nil {
			return nil, failure(context.Background(), name, started, waitErr)
		}
		return nil, errors.New(name + " exited without reporting usage")
	}
	return nil, readErr
}

// readResponseLine scans newline-delimited JSON (1 MiB per line, 4 MiB in
// all) for the first line the matcher accepts.
func readResponseLine(reader io.Reader, matches func([]byte) bool) ([]byte, error) {
	return readResponseLines(reader, matches, 1)
}

// readResponseLines returns the first count accepted lines, in arrival
// order, joined by newlines. All of them must arrive.
func readResponseLines(reader io.Reader, matches func([]byte) bool, count int) ([]byte, error) {
	buffered := bufio.NewReaderSize(reader, 64<<10)
	total := 0
	var accepted [][]byte
	for {
		var line []byte
		for {
			chunk, err := buffered.ReadSlice('\n')
			line = append(line, chunk...)
			total += len(chunk)
			if len(line) > 1<<20 || total > 4<<20 {
				return nil, errors.New("the provider's output exceeds its limit")
			}
			if err == bufio.ErrBufferFull {
				continue
			}
			if err != nil {
				if trimmed := bytes.TrimSpace(line); len(trimmed) > 0 && matches(trimmed) {
					if accepted = append(accepted, trimmed); len(accepted) == count {
						return bytes.Join(accepted, []byte{'\n'}), nil
					}
				}
				return nil, io.EOF
			}
			break
		}
		if trimmed := bytes.TrimSpace(line); len(trimmed) > 0 && matches(trimmed) {
			// line is a fresh slice each round, so keeping it is safe.
			if accepted = append(accepted, trimmed); len(accepted) == count {
				return bytes.Join(accepted, []byte{'\n'}), nil
			}
		}
	}
}

// accountEnvironment is this process's environment with only the account
// variable changed (and Relay's shim marker removed).
func accountEnvironment(variable, override string) []string {
	environment := []string{}
	for _, entry := range os.Environ() {
		if !strings.HasPrefix(entry, variable+"=") && !strings.HasPrefix(entry, "RELAY_INVOKED_AS=") {
			environment = append(environment, entry)
		}
	}
	if override != "" {
		environment = append(environment, variable+"="+override)
	}
	return environment
}
