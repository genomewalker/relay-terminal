package agentlaunch

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
)

// Claude's own --permission-mode values that a Relay default may select.
var claudePermissionModes = map[string]bool{"default": true, "acceptEdits": true, "plan": true, "auto": true, "bypassPermissions": true}

// ClaudeLaunchDefaults reads the user-owned <account>/relay-launch-defaults.json.
// Absence leaves Claude's own configuration in charge; a malformed policy
// never enables access.
func ClaudeLaunchDefaults(configDir string) (string, bool, error) {
	if !filepath.IsAbs(configDir) {
		return "", false, errors.New("Claude account directory is not absolute")
	}
	path := filepath.Join(configDir, "relay-launch-defaults.json")
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || stat.Uid != uint32(os.Getuid()) || info.Size() > 4096 {
		return "", false, errors.New("Relay Claude launch defaults are not a private owned file")
	}
	file, err := os.Open(path)
	if err != nil {
		return "", false, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !os.SameFile(info, opened) {
		return "", false, errors.New("Relay Claude launch defaults changed while opening")
	}
	var value struct {
		Version        int    `json:"version"`
		PermissionMode string `json:"permission_mode"`
	}
	decoder := json.NewDecoder(io.LimitReader(file, 4097))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&value); err != nil {
		return "", false, err
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return "", false, errors.New("Relay Claude launch defaults contain trailing data")
	}
	if value.Version != 1 || !claudePermissionModes[value.PermissionMode] {
		return "", false, errors.New("Relay Claude launch defaults have unknown permission values")
	}
	return value.PermissionMode, true, nil
}

// ManagedClaudeLaunchArguments prepares the arguments that follow Relay's own
// --settings <hooksPath>. Copies of that exact option carried in by a replayed
// launch are removed so it appears once, and retired Relay settings files are
// no longer passed. An explicit starting permission mode
// wins over the account's Relay default, which is otherwise added. Option
// values are skipped by arity, so prompt text is never read as an option; after
// an option of unknown arity the rest is kept verbatim and no default is added.
func ManagedClaudeLaunchArguments(configDir, hooksPath string, arguments []string, retired ...string) ([]string, error) {
	mode, configured, err := ClaudeLaunchDefaults(configDir)
	if err != nil {
		return nil, err
	}
	result, explicit, complete := scanClaudeArguments(hooksPath, arguments, retired)
	if explicit || !complete || !configured {
		return result, nil
	}
	if mode == "bypassPermissions" {
		return append([]string{"--dangerously-skip-permissions"}, result...), nil
	}
	return append([]string{"--permission-mode", mode}, result...), nil
}

// WithoutRelayClaudeSettings removes only Relay's own and retired settings
// files from the caller's arguments. It adds no defaults.
func WithoutRelayClaudeSettings(hooksPath string, arguments []string, retired ...string) []string {
	result, _, _ := scanClaudeArguments(hooksPath, arguments, retired)
	return result
}

// scanClaudeArguments reports whether a starting permission mode was given and
// whether the whole argument list was scanned.
func scanClaudeArguments(hooksPath string, arguments []string, retired []string) ([]string, bool, bool) {
	value, plain, variadic := map[string]bool{}, map[string]bool{}, map[string]bool{}
	for _, flag := range strings.Fields(claudeValueOptions + " --resume -r --session-id") {
		value[flag] = true
	}
	for _, flag := range strings.Fields(claudePlainOptions + " --continue -c --fork-session") {
		plain[flag] = true
	}
	for _, flag := range strings.Fields(claudeVariadicOptions) {
		variadic[flag] = true
	}
	result := make([]string, 0, len(arguments)+2)
	explicit := false
	for i := 0; i < len(arguments); i++ {
		argument := arguments[i]
		flag, _, equals := strings.Cut(argument, "=")
		switch {
		case argument == "--" || (strings.HasPrefix(argument, "-") && !value[flag] && !plain[flag] && !variadic[flag]):
			result = append(result, arguments[i:]...)
			// As before, no default is added once scanning stops here.
			return result, explicit, false
		case !strings.HasPrefix(argument, "-"):
			result = append(result, argument)
		case flag == "--settings" && relaySettingsPath(argument, arguments, i, equals, hooksPath, retired):
			if !equals {
				i++
			}
		case value[flag]:
			explicit = explicit || flag == "--permission-mode"
			result = append(result, argument)
			// --resume and -r take an optional session; other value options always take one.
			optional := flag == "--resume" || flag == "-r"
			if !equals && i+1 < len(arguments) && (!optional || !strings.HasPrefix(arguments[i+1], "-")) {
				i++
				result = append(result, arguments[i])
			}
		case variadic[flag]:
			result = append(result, argument)
			for !equals && i+1 < len(arguments) && !strings.HasPrefix(arguments[i+1], "-") {
				i++
				result = append(result, arguments[i])
			}
		default:
			explicit = explicit || flag == "--dangerously-skip-permissions"
			result = append(result, argument)
		}
	}
	return result, explicit, true
}

func relaySettingsPath(argument string, arguments []string, i int, equals bool, hooksPath string, retired []string) bool {
	path := strings.TrimPrefix(argument, "--settings=")
	if !equals {
		if i+1 >= len(arguments) {
			return false
		}
		path = arguments[i+1]
	}
	return path == hooksPath || slices.Contains(retired, path)
}
