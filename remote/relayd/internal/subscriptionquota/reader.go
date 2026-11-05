package subscriptionquota

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/relay-terminal/relayd/internal/agentaccounts"
)

// Reader's dependencies are private: production endpoints and credentials are
// fixed here, while package tests replace them with isolated files/TLS/sockets.
type Reader struct {
	home        string
	uid         uint32
	env         func(string) (string, bool)
	now         func() time.Time
	platform    string
	client      *http.Client
	usageURL    string
	credentials func(context.Context) ([]byte, error)
	connect     func(context.Context, string, uint32) (*readSocket, error)
	codexCLI    func(context.Context, string, string) ([]byte, error)
}

func NewReader() (*Reader, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	r := &Reader{home: home, uid: uint32(os.Getuid()), env: os.LookupEnv, now: time.Now, platform: runtime.GOOS,
		client: &http.Client{}, usageURL: "https://api.anthropic.com/api/oauth/usage", connect: openReadSocket}
	r.credentials = r.readCredentials
	r.codexCLI = agentaccounts.ProviderUsage
	return r, nil
}

func marshal(v any) ([]byte, error) {
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	if err := e.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(b.Bytes(), []byte("\n")), nil
}
func (r *Reader) configured(key, fallback string) string {
	if value, exists := r.env(key); exists {
		return value
	}
	return fallback
}

func (r *Reader) accountScope(provider string) any {
	if provider == "codex" {
		root := r.configured("CODEX_HOME", filepath.Join(r.home, ".codex"))
		value, err := privateFile(filepath.Join(root, "auth.json"), Limit, r.uid)
		if err != nil {
			return nil
		}
		ident := text(object(value["tokens"])["account_id"])
		if ident == "" || len([]rune(ident)) > 256 {
			return nil
		}
		return identityDigest([]any{"codex", ident})
	}
	path := filepath.Join(r.home, ".claude.json")
	if root, _ := r.env("CLAUDE_CONFIG_DIR"); root != "" {
		path = filepath.Join(root, ".claude.json")
	}
	value, err := privateFile(path, 4<<20, r.uid)
	if err != nil {
		return nil
	}
	account := object(value["oauthAccount"])
	ident, org := text(account["accountUuid"]), text(account["organizationUuid"])
	if ident == "" || org == "" || len([]rune(ident)) > 256 || len([]rune(org)) > 256 {
		return nil
	}
	return identityDigest([]any{"claude", ident, org})
}

type boundedBuffer struct {
	bytes.Buffer
	maximum int
}

func (b *boundedBuffer) Write(p []byte) (int, error) {
	if b.Len()+len(p) > b.maximum {
		return 0, errUnavailable
	}
	return b.Buffer.Write(p)
}

func (r *Reader) readCredentials(ctx context.Context) ([]byte, error) {
	if r.platform != "darwin" {
		root := r.configured("CLAUDE_CONFIG_DIR", filepath.Join(r.home, ".claude"))
		value, err := privateFile(filepath.Join(root, ".credentials.json"), Limit, r.uid)
		if err != nil {
			return nil, err
		}
		return marshal(value)
	}
	ctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/bin/security", "find-generic-password", "-s", "Claude Code-credentials", "-w")
	out := &boundedBuffer{maximum: Limit}
	cmd.Stdout = out
	cmd.Stderr = io.Discard
	if err := cmd.Run(); err != nil {
		return nil, errUnavailable
	}
	return out.Bytes(), nil
}

func (r *Reader) claudeUsage(ctx context.Context) (map[string]any, error) {
	raw, err := r.credentials(ctx)
	if err != nil {
		return nil, errUnavailable
	}
	value, err := decodeObject(raw, Limit)
	if err != nil {
		return nil, err
	}
	oauth := object(value["claudeAiOauth"])
	token := text(oauth["accessToken"])
	if token == "" || len([]rune(token)) > 16384 {
		return nil, nil
	}
	scoped := false
	if scopes, ok := oauth["scopes"].([]any); ok {
		for _, scope := range scopes {
			if scope == "user:profile" {
				scoped = true
			}
		}
	}
	// Python's membership operation also accepts a string-valued scopes field.
	if scopes, ok := oauth["scopes"].(string); ok {
		scoped = strings.Contains(scopes, "user:profile")
	}
	if scopes, ok := oauth["scopes"].(map[string]any); ok {
		_, scoped = scopes["user:profile"]
	}
	if !scoped {
		return nil, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, r.usageURL, nil)
	if err != nil {
		return nil, errUnavailable
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("anthropic-beta", "oauth-2025-04-20")
	req.Header.Set("User-Agent", "Relay/0.5.2")
	client := *r.client
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := client.Do(req)
	if err != nil {
		return nil, errUnavailable
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, errUnavailable
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, Limit+1))
	if err != nil || len(data) > Limit {
		return nil, errUnavailable
	}
	return parseUsage(data, oauth["subscriptionType"], r.accountScope("claude"), r.now())
}

// Read returns account-scoped observations. Codex prefers its existing socket;
// when unavailable, its own short-lived CLI reads limits without a model turn.
// Unavailable observations are omitted; current identities are still returned.
func (r *Reader) Read(ctx context.Context, panes []string) ([]byte, error) {
	result := []any{}
	if live, err := r.claudeUsage(ctx); err == nil && live != nil {
		result = append(result, live)
	}
	dir := filepath.Join(r.home, ".local/share/relay/claude-status")
	type snapshot struct {
		path     string
		modified time.Time
	}
	snapshots := []snapshot{}
	if directory, err := os.Open(dir); err == nil {
		entries, readErr := directory.ReadDir(-1)
		directory.Close()
		if readErr == nil {
			for _, entry := range entries {
				if matches, _ := filepath.Match("session-*.json", entry.Name()); !matches {
					continue
				}
				path := filepath.Join(dir, entry.Name())
				info, err := os.Stat(path)
				if err != nil {
					snapshots = nil
					break
				} // original sorted glob fails as a whole on stat failure
				snapshots = append(snapshots, snapshot{path, info.ModTime()})
			}
		}
	}
	sort.SliceStable(snapshots, func(i, j int) bool { return snapshots[i].modified.After(snapshots[j].modified) })
	if len(snapshots) > 16 {
		snapshots = snapshots[:16]
	}
	appendCache := func(value map[string]any) {
		result = append(result, map[string]any{"provider": "claude", "account_scope": value["account_scope"], "observation": projection(value, "session_id", "rate_limits", "captured_at")})
	}
	for _, item := range snapshots {
		if value, err := privateFile(item.path, Limit, r.uid); err == nil {
			appendCache(value)
		}
	}
	if len(panes) > 128 {
		panes = panes[:128]
	}
	for _, pane := range panes {
		if !validID(pane) {
			continue
		}
		if value, err := privateFile(filepath.Join(dir, pane+".json"), Limit, r.uid); err == nil && strings.EqualFold(text(value["pane_id"]), pane) {
			appendCache(value)
		}
	}
	codexRead := false
	path := r.configured("CODEX_APP_SERVER_CONTROL_SOCKET", filepath.Join(r.home, ".codex/app-server-control/app-server-control.sock"))
	if client, err := r.connect(ctx, path, r.uid); err == nil {
		defer client.close()
		if _, err = client.rpc(1, "initialize", map[string]any{"clientInfo": map[string]any{"name": "relay_quota", "version": "1"}}); err == nil {
			if err = client.send(map[string]any{"method": "initialized", "params": map[string]any{}}); err == nil {
				if value, err := client.rpc(2, "account/rateLimits/read", map[string]any{}); err == nil {
					result = append(result, map[string]any{"provider": "codex", "account_scope": r.accountScope("codex"), "observation": projection(value, "rateLimits", "rateLimitsByLimitId", "rateLimitResetCredits")})
					codexRead = true
				}
			}
		}
	}
	if !codexRead && r.codexCLI != nil {
		// Pin the explicit home and identity across the CLI read. A sign-in change
		// invalidates the result rather than attributing it to another account.
		scope := r.accountScope("codex")
		root := r.configured("CODEX_HOME", filepath.Join(r.home, ".codex"))
		if scope != nil {
			call, cancel := context.WithTimeout(ctx, 8*time.Second)
			raw, err := r.codexCLI(call, "codex", root)
			cancel()
			if err == nil && scope == r.accountScope("codex") {
				for _, line := range bytes.Split(raw, []byte("\n")) {
					var message map[string]any
					if json.Unmarshal(line, &message) != nil || message["id"] != float64(2) {
						continue
					}
					value := object(message["result"])
					observation := projection(value, "rateLimits", "rateLimitsByLimitId", "rateLimitResetCredits")
					if len(observation) != 0 {
						result = append(result, map[string]any{"provider": "codex", "account_scope": scope, "observation": observation})
					}
				}
			}
		}
	}
	for _, identity := range r.identities() {
		result = append(result, identity)
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return marshal(result)
}

// RunStatusline preserves the original bounded stdin prefix, command stdout,
// stderr and exit status. Capture failure never prevents the user's command.
// The supplied command is the user's existing statusline, not a provider CLI.
func (r *Reader) RunStatusline(ctx context.Context, encoded string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	raw, err := io.ReadAll(io.LimitReader(stdin, Limit+1))
	if err != nil {
		return 1, err
	}
	if len(raw) <= Limit {
		_ = r.CaptureStatus(raw)
	}
	command, err := decodeCommand(encoded)
	if err != nil {
		return 1, err
	}
	cmd := exec.CommandContext(ctx, "/bin/sh", "-c", command)
	cmd.Stdin = bytes.NewReader(raw)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	if err = cmd.Run(); err == nil {
		return 0, nil
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return statusExitCode(exit.ExitCode(), exit.ProcessState.Sys()), nil
	}
	return 1, err
}

// subprocess.returncode uses the negative signal number; os/exec otherwise
// collapses every signal to -1. Keep the existing statusline's exact outcome.
func statusExitCode(code int, state any) int {
	if status, ok := state.(syscall.WaitStatus); ok && code == -1 && status.Signaled() {
		return -int(status.Signal())
	}
	return code
}

func decodeCommand(encoded string) (string, error) {
	if len(encoded) > 1<<20 {
		return "", errUnavailable
	}
	// Match b64decode(validate=False): ignore non-alphabet bytes.
	clean := strings.Map(func(r rune) rune {
		if strings.ContainsRune("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=", r) {
			return r
		}
		return -1
	}, encoded)
	// CPython's permissive decoder stops after a completed padded group and
	// tolerates leading/excess padding; it still rejects incomplete groups.
	data := make([]byte, 0, len(clean)*3/4)
	position, pads := 0, 0
	var accumulated byte
	for _, c := range []byte(clean) {
		if c == '=' {
			if position >= 2 {
				pads++
				if position+pads >= 4 {
					position = 0
					break
				}
			}
			continue
		}
		pads = 0
		index := strings.IndexByte("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", c)
		if index < 0 {
			continue
		}
		x := byte(index)
		switch position {
		case 0:
			accumulated = x << 2
		case 1:
			data = append(data, accumulated|x>>4)
			accumulated = x << 4
		case 2:
			data = append(data, accumulated|x>>2)
			accumulated = x << 6
		case 3:
			data = append(data, accumulated|x)
		}
		position = (position + 1) % 4
	}
	if position != 0 || !utf8.Valid(data) {
		return "", errUnavailable
	}
	return string(data), nil
}
