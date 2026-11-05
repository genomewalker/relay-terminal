// Package providersetup installs only Relay's explicitly managed provider UI
// assets. Commands require an existing, recognizable Claude command statusline.
package providersetup

import (
	"bytes"
	"crypto/sha256"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

//go:embed assets/*
var embedded embed.FS
var assetNames = []string{"relay-prompt.bash", "relay-cc-status.sh", "relay-claude-status"}
var destinations = []string{"prompt.bash", "cc-status.sh", "claude-status"}

const Launcher = `bash "$HOME/.config/relay/cc-status.sh"`
const settingsPath = ".claude/settings.json"
const adapterPath = ".claude/plugins/cache/genomewalker-chitta/chitta/5.73.1/chitta-mcp/hook_client.py"
const anchor = "    client.apply(plan)\n    if plan.get(\"provenance\"):"
const replacement = `    # The same daemon policy handles successful and failed tool calls.
    # Claude validates the output discriminator against the incoming event.
    if raw.get("hook_event_name") == "PostToolUseFailure":
        try:
            rendered = json.loads(plan["stdout"])
        except (ValueError, TypeError):
            rendered = None
        if isinstance(rendered, dict):
            specific = rendered.get("hookSpecificOutput")
            if isinstance(specific, dict) and specific.get("hookEventName") == "PostToolUse":
                specific["hookEventName"] = "PostToolUseFailure"
                plan["stdout"] = json.dumps(rendered, ensure_ascii=False) + "\n"
    client.apply(plan)
    if plan.get("provenance"):`

func hash(raw []byte) string { d := sha256.Sum256(raw); return hex.EncodeToString(d[:]) }
func DefaultAssets() map[string][]byte {
	m := map[string][]byte{}
	for _, n := range assetNames {
		raw, e := embedded.ReadFile("assets/" + n)
		if e != nil {
			panic(e)
		}
		m[n] = raw
	}
	return m
}
func validAssets(m map[string][]byte) error {
	if len(m) != len(assetNames) {
		return errors.New("unexpected bundle asset set")
	}
	for _, n := range assetNames {
		raw, ok := m[n]
		if !ok || len(raw) == 0 || len(raw) > FileLimit {
			return errors.New("missing or oversized bundle asset")
		}
	}
	return nil
}
func object(raw []byte) (map[string]any, error) {
	if len(raw) > FileLimit || !utf8.Valid(raw) || !scalarEscapes(raw) {
		return nil, errors.New("invalid or oversized JSON")
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	var v map[string]any
	if e := d.Decode(&v); e != nil {
		return nil, e
	}
	if v == nil {
		return nil, errors.New("expected JSON object")
	}
	var trailing any
	if e := d.Decode(&trailing); e != io.EOF {
		return nil, errors.New("trailing JSON")
	}
	return v, nil
}

// encoding/json replaces lone UTF-16 surrogates with U+FFFD. The canonical
// installer cannot emit these with ensure_ascii=False; refuse rather than
// silently rewriting an unrelated user string during the native migration.
func scalarEscapes(raw []byte) bool {
	quoted := false
	for i := 0; i < len(raw); i++ {
		if raw[i] == '"' {
			quoted = !quoted
			continue
		}
		if !quoted || raw[i] != '\\' {
			continue
		}
		i++
		if i >= len(raw) {
			return false
		}
		if raw[i] != 'u' {
			continue
		}
		if i+4 >= len(raw) {
			return false
		}
		value, e := strconv.ParseUint(string(raw[i+1:i+5]), 16, 16)
		if e != nil {
			return false
		}
		i += 4
		if value >= 0xDC00 && value <= 0xDFFF {
			return false
		}
		if value >= 0xD800 && value <= 0xDBFF {
			if i+6 >= len(raw) || raw[i+1] != '\\' || raw[i+2] != 'u' {
				return false
			}
			low, e := strconv.ParseUint(string(raw[i+3:i+7]), 16, 16)
			if e != nil || low < 0xDC00 || low > 0xDFFF {
				return false
			}
			i += 6
		}
	}
	return true
}
func encodedAssets(m map[string][]byte) (string, error) {
	if e := validAssets(m); e != nil {
		return "", e
	}
	raw, e := json.Marshal(m)
	if e != nil {
		return "", e
	}
	return base64.StdEncoding.EncodeToString(raw), nil
}
func DecodeAssets(encoded string) (map[string][]byte, error) {
	if len(encoded) > 6*FileLimit {
		return nil, errors.New("bundle exceeds bound")
	}
	raw, e := base64.StdEncoding.DecodeString(encoded)
	if e != nil {
		return nil, e
	}
	var m map[string][]byte
	if e = json.Unmarshal(raw, &m); e != nil {
		return nil, e
	}
	if e = validAssets(m); e != nil {
		return nil, e
	}
	return m, nil
}
func Bundle(m map[string][]byte) ([]byte, error) {
	enc, e := encodedAssets(m)
	if e != nil {
		return nil, e
	}
	return []byte("#!/bin/sh\nset -eu\nexec \"$HOME/.local/bin/relay-provider-setup\" --assets-base64 '" + enc + "' \"$@\"\n"), nil
}

// Python's canonical \\s is Unicode whitespace, including U+001C..U+001F.
var wrapperRE = regexp.MustCompile(`(--statusline[\t\n\f\r \x{000B}\x{001C}-\x{001F}\x{0085}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}]+)[A-Za-z0-9+/=]+`)

// TransformSettings deliberately retains the surrounding user wrapper/footer.
func TransformSettings(raw []byte) ([]byte, error) {
	return transformSettings(raw, "")
}

func transformSettings(raw []byte, home string) ([]byte, error) {
	data, e := object(raw)
	if e != nil {
		return nil, e
	}
	status, ok := data["statusLine"].(map[string]any)
	if !ok || status["type"] != "command" {
		return nil, errors.New("existing command status line required")
	}
	command, ok := status["command"].(string)
	if !ok {
		return nil, errors.New("status command must be text")
	}
	if home != "" && strings.HasPrefix(command, nativeQuotaPrefix(home)) {
		if _, err := nativeQuotaEncoded(command, home); err != nil {
			return nil, err
		}
		command = nativeQuotaPrefix(home) + shellLiteral(base64.StdEncoding.EncodeToString([]byte(Launcher)))
	} else if strings.HasPrefix(command, "'") && strings.Contains(command, "/.local/bin/relayd' subscription-quota-statusline ") {
		return nil, errors.New("native status line belongs to a different home")
	} else if strings.Contains(command, "--statusline") {
		if len(wrapperRE.FindAllStringIndex(command, -1)) != 1 {
			return nil, errors.New("unknown status line wrapper format")
		}
		command = wrapperRE.ReplaceAllStringFunc(command, func(v string) string {
			p := wrapperRE.FindStringSubmatch(v)
			return p[1] + base64.StdEncoding.EncodeToString([]byte(Launcher))
		})
	} else if strings.Contains(command, "cc-status") {
		command = Launcher
	} else {
		return nil, errors.New("refusing to replace unrelated status line")
	}
	status["command"] = command
	data["promptSuggestionEnabled"] = true
	out, e := json.MarshalIndent(data, "", "  ")
	if len(out)+1 > FileLimit {
		return nil, errors.New("transformed settings exceed bound")
	}
	return append(out, '\n'), e
}

const thinShim = "#!/bin/sh\nset -eu\nRELAY_INVOKED_AS=claude\nexport RELAY_INVOKED_AS\nexec \"$HOME/.local/bin/relayd\" \"$@\"\n"

var legacyShim = strings.Replace(thinShim, `"$@"`, `--settings "$HOME/.config/relay/claude-hooks-status.json" "$@"`, 1)

func (s *Store) install(m map[string][]byte) error {
	if e := validAssets(m); e != nil {
		return e
	}
	// Preserve canonical ordering: shared assets may be updated even if the
	// independently guarded user settings prove unrecognized.
	for i, n := range assetNames {
		mode := uint32(0600)
		if n == "relay-claude-status" {
			mode = 0700
		}
		if e := s.put(".config/relay/"+destinations[i], m[n], mode); e != nil {
			return e
		}
	}
	old, e := s.read(settingsPath)
	if e != nil {
		return e
	}
	if old == nil {
		return errors.New("existing Claude settings are required")
	}
	updated, e := transformSettings(old.raw, s.home)
	if e != nil {
		return e
	}
	if e = s.replace(settingsPath, updated, old, 0600, ""); e != nil {
		return e
	}
	shim, e := s.read(".local/share/relay/shims/claude")
	if e != nil {
		return e
	}
	if shim != nil && string(shim.raw) == legacyShim {
		hooks, e := s.read(".relay/claude-hooks.json")
		if e != nil {
			return e
		}
		if hooks == nil {
			return errors.New("upgrade Relay helper before removing legacy launcher settings")
		}
		h, e := object(hooks.raw)
		if e != nil {
			return e
		}
		_, hasHooks := h["hooks"]
		if len(h) != 1 || !hasHooks {
			return errors.New("upgrade Relay helper before removing legacy launcher settings")
		}
		if e = s.replace(".local/share/relay/shims/claude", []byte(thinShim), shim, 0700, ""); e != nil {
			return e
		}
	}
	return nil
}
func (s *Store) Install(m map[string][]byte) error {
	return s.locked(func() error { return s.install(m) })
}
func RepairBytes(raw []byte) ([]byte, bool, error) {
	if len(raw) > FileLimit || !utf8.Valid(raw) {
		return nil, false, errors.New("invalid or oversized adapter")
	}
	source := string(raw)
	if strings.Contains(source, replacement) {
		return append([]byte(nil), raw...), false, nil
	}
	if strings.Count(source, anchor) != 1 {
		return nil, false, errors.New("adapter anchor is ambiguous or changed")
	}
	out := []byte(strings.Replace(source, anchor, replacement, 1))
	if len(out) > FileLimit {
		return nil, false, errors.New("repaired adapter exceeds bound")
	}
	return out, true, nil
}
func (s *Store) repair() (bool, error) {
	old, e := s.read(adapterPath)
	if e != nil {
		return false, e
	}
	if old == nil {
		return false, errors.New("expected installed Chitta 5.73.1 adapter")
	}
	raw, changed, e := RepairBytes(old.raw)
	if e != nil || !changed {
		return changed, e
	}
	// Keep the original content-addressed private backup outside the plugin tree.
	path := ".config/relay/backups/chitta-failure-event-20261004/hook_client-" + hash(old.raw) + ".py"
	bfd, name, e := s.parent(path, true)
	if e != nil {
		return false, e
	}
	if e = privateDirectory(bfd); e != nil {
		closeFD(bfd)
		return false, e
	}
	e = writeExclusive(bfd, name, old.raw, 0600)
	if e == nil {
		e = syncDir(bfd)
	}
	closeFD(bfd)
	if e != nil {
		return false, e
	}
	// replace also retains the common private backup and enforces full-byte CAS.
	e = s.replace(adapterPath, raw, old, uint32(old.stat.Mode&07777), "")
	return e == nil, e
}
func (s *Store) Repair() (bool, error) {
	var changed bool
	e := s.locked(func() error { var e error; changed, e = s.repair(); return e })
	return changed, e
}

type FileReport struct {
	File    string  `json:"file"`
	Managed bool    `json:"managed"`
	SHA256  *string `json:"sha256"`
}
type StatusReport struct {
	Managed      bool `json:"managed"`
	QuotaCapture bool `json:"quota_capture"`
}
type HookReport struct {
	UserEventCount         int  `json:"user_event_count"`
	ChittaEnabled          any  `json:"chitta_enabled"`
	FailureAdapterRepaired bool `json:"failure_adapter_repaired"`
}
type Report struct {
	SchemaVersion            int          `json:"schema_version"`
	BundleSHA256             string       `json:"bundle_sha256"`
	Platform                 string       `json:"platform"`
	Files                    []FileReport `json:"files"`
	Statusline               StatusReport `json:"statusline"`
	PromptSuggestionsEnabled bool         `json:"prompt_suggestions_enabled"`
	Hooks                    HookReport   `json:"hooks"`
	Drift                    bool         `json:"drift"`
	canonicalDrift           any
	canonicalDriftSet        bool
}

// The canonical Python `or ... or (enabled and ...)` expression can return a
// falsey scalar/container, rather than bool, for malformed plugin flag values.
// Preserve that wire type while keeping an explicit internal boolean decision.
func (r Report) MarshalJSON() ([]byte, error) {
	type plain Report
	value := any(r.Drift)
	if r.canonicalDriftSet {
		value = r.canonicalDrift
	}
	return json.Marshal(struct {
		plain
		Drift any `json:"drift"`
	}{plain(r), value})
}

func pythonTruthy(v any) bool {
	switch x := v.(type) {
	case nil:
		return false
	case bool:
		return x
	case string:
		return x != ""
	case json.Number:
		number, _ := x.Float64()
		return number != 0
	case []any:
		return len(x) > 0
	case map[string]any:
		return len(x) > 0
	default:
		return true
	}
}
func configEnabled(data map[string]any) (any, error) {
	if value, exists := data["enabledPlugins"]; exists {
		p, ok := value.(map[string]any)
		if !ok {
			return nil, errors.New("enabledPlugins must be an object")
		}
		if v, ok := p["chitta@genomewalker-chitta"]; ok {
			return v, nil
		}
	}
	return false, nil
}

func configHookCount(data map[string]any) (int, error) {
	value, exists := data["hooks"]
	if !exists {
		return 0, nil
	}
	switch value := value.(type) {
	case map[string]any:
		return len(value), nil
	case []any:
		return len(value), nil
	case string:
		return utf8.RuneCountInString(value), nil
	default:
		return 0, errors.New("hooks must have a defined event count")
	}
}

func configStatus(data map[string]any) (map[string]any, error) {
	value := data["statusLine"]
	if !pythonTruthy(value) {
		return map[string]any{}, nil
	}
	status, ok := value.(map[string]any)
	if !ok {
		return nil, errors.New("statusLine must be an object")
	}
	return status, nil
}
func (s *Store) Audit(m map[string][]byte) (Report, error) {
	var report Report
	if e := validAssets(m); e != nil {
		return report, e
	}
	bundle, e := Bundle(m)
	if e != nil {
		return report, e
	}
	platform := runtime.GOOS
	if platform == "linux" {
		platform = "linux"
	}
	report = Report{SchemaVersion: 1, BundleSHA256: hash(bundle), Platform: platform, Files: []FileReport{}, Hooks: HookReport{ChittaEnabled: false}}
	for i, n := range assetNames {
		old, e := s.read(".config/relay/" + destinations[i])
		if e != nil {
			return report, e
		}
		f := FileReport{File: destinations[i]}
		if old != nil {
			d := hash(old.raw)
			f.SHA256 = &d
			f.Managed = bytes.Equal(old.raw, m[n])
		}
		report.Files = append(report.Files, f)
		report.Drift = report.Drift || !f.Managed
	}
	data := map[string]any{}
	old, e := s.read(settingsPath)
	if e != nil {
		return report, e
	}
	if old != nil {
		data, e = object(old.raw)
		if e != nil {
			return report, e
		}
	}
	status, e := configStatus(data)
	if e != nil {
		return report, e
	}
	command, _ := status["command"].(string)
	if encoded, err := nativeQuotaEncoded(command, s.home); err == nil {
		raw, _ := quotaRendererBytes(encoded)
		command = string(raw)
		report.Statusline.QuotaCapture = true
	} else if strings.Contains(command, "--statusline ") {
		fields := strings.Fields(strings.SplitN(command, "--statusline ", 2)[1])
		command = ""
		if len(fields) > 0 {
			raw, e := base64.StdEncoding.DecodeString(fields[0])
			if e == nil && utf8.Valid(raw) {
				command = string(raw)
				report.Statusline.QuotaCapture = true
			}
		}
	}
	report.Statusline.Managed = status["type"] == "command" && command == Launcher
	report.PromptSuggestionsEnabled = data["promptSuggestionEnabled"] == true
	report.Hooks.UserEventCount, e = configHookCount(data)
	if e != nil {
		return report, e
	}
	report.Hooks.ChittaEnabled, e = configEnabled(data)
	if e != nil {
		return report, e
	}
	adapter, e := s.read(adapterPath)
	if e != nil {
		return report, e
	}
	report.Hooks.FailureAdapterRepaired = adapter != nil && bytes.Contains(adapter.raw, []byte(`specific["hookEventName"] = "PostToolUseFailure"`))
	// Deliberately retain the canonical status-type quirk: the managed status
	// field checks `type`, but the original drift expression checks the command.
	baseDrift := report.Drift || command != Launcher || !report.PromptSuggestionsEnabled
	if baseDrift {
		report.canonicalDrift = true
	} else if pythonTruthy(report.Hooks.ChittaEnabled) {
		report.canonicalDrift = !report.Hooks.FailureAdapterRepaired
	} else {
		report.canonicalDrift = report.Hooks.ChittaEnabled
	}
	report.canonicalDriftSet = true
	report.Drift = pythonTruthy(report.canonicalDrift)
	return report, nil
}
func (s *Store) Apply(m map[string][]byte) (Report, error) {
	var report Report
	e := s.locked(func() error {
		if e := s.install(m); e != nil {
			return e
		}
		old, e := s.read(settingsPath)
		if e != nil {
			return e
		}
		data, e := object(old.raw)
		if e != nil {
			return e
		}
		enabled, e := configEnabled(data)
		if e != nil {
			return e
		}
		if pythonTruthy(enabled) {
			if _, e = s.repair(); e != nil {
				return e
			}
		}
		bundle, e := Bundle(m)
		if e != nil {
			return e
		}
		if e = s.put(".config/relay/provider-setup", bundle, 0700); e != nil {
			return e
		}
		manifest := struct {
			SchemaVersion int               `json:"schema_version"`
			BundleSHA256  string            `json:"bundle_sha256"`
			Assets        map[string]string `json:"assets"`
		}{1, hash(bundle), map[string]string{}}
		keys := make([]string, 0, len(m))
		for k := range m {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			manifest.Assets[k] = hash(m[k])
		}
		raw, e := json.MarshalIndent(manifest, "", "  ")
		if e != nil {
			return e
		}
		if e = s.put(".config/relay/provider-setup-manifest.json", append(raw, '\n'), 0600); e != nil {
			return e
		}
		report, e = s.Audit(m)
		return e
	})
	return report, e
}
func FormatReport(r Report, w io.Writer) error { return json.NewEncoder(w).Encode(r) }
func ValidateAction(v string) error {
	switch v {
	case "audit", "apply", "bundle", "install-shell-ui", "repair-chitta-failure", "statusline":
		return nil
	}
	return fmt.Errorf("unknown provider setup action %q", v)
}
