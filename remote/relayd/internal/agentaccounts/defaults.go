package agentaccounts

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
)

// ModelDefaults is the model and reasoning effort Relay's launcher passes to
// a new agent of this account, unless the launch names its own. It lives in
// the account's directory as relay-model-defaults.json; Relay writes it only
// when the user sets it in Settings.
type ModelDefaults struct {
	Version int    `json:"version"`
	Model   string `json:"model,omitempty"`
	Effort  string `json:"effort,omitempty"`
}

const modelDefaultsName = "relay-model-defaults.json"

var (
	modelPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:/\[\]-]{0,79}$`)
	efforts      = map[string][]string{
		"claude": {"low", "medium", "high", "xhigh", "max"},
		"codex":  {"minimal", "low", "medium", "high", "xhigh"},
	}
)

// ValidateModelDefaults accepts an empty pair (no defaults) or a model name
// and an effort the provider's CLI knows.
func ValidateModelDefaults(provider, model, effort string) error {
	if model != "" && !modelPattern.MatchString(model) {
		return errors.New("a model name uses letters, digits and . _ : / - (at most 80)")
	}
	if effort != "" {
		allowed, ok := efforts[provider]
		if !ok {
			return errors.New("unsupported provider")
		}
		for _, value := range allowed {
			if value == effort {
				return nil
			}
		}
		return errors.New(provider + " effort is one of " + strings.Join(allowed, ", "))
	}
	return nil
}

// ReadModelDefaults returns the account's defaults; a missing file is no
// defaults. The file must be the owner's private regular file.
func ReadModelDefaults(provider, root string) (ModelDefaults, error) {
	path := filepath.Join(root, modelDefaultsName)
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return ModelDefaults{}, nil
	}
	if err != nil {
		return ModelDefaults{}, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.Mode().IsRegular() || int(stat.Uid) != os.Getuid() || info.Mode().Perm()&0o077 != 0 || info.Size() > 4096 {
		return ModelDefaults{}, errors.New("model defaults file is not a private file")
	}
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return ModelDefaults{}, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, 4097))
	if err != nil || len(data) > 4096 {
		return ModelDefaults{}, errors.New("model defaults file exceeds its limit")
	}
	var defaults ModelDefaults
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&defaults) != nil || defaults.Version != 1 ||
		ValidateModelDefaults(provider, defaults.Model, defaults.Effort) != nil {
		return ModelDefaults{}, errors.New("model defaults file is invalid")
	}
	return defaults, nil
}

// WriteModelDefaults replaces the account's defaults; an empty pair removes
// the file. The account directory must exist and not be a link.
func WriteModelDefaults(provider, root, model, effort string) error {
	if err := ValidateModelDefaults(provider, model, effort); err != nil {
		return err
	}
	info, err := os.Lstat(root)
	if err != nil || !info.IsDir() {
		return errors.New("create the account's folder first")
	}
	path := filepath.Join(root, modelDefaultsName)
	if existing, err := os.Lstat(path); err == nil && !existing.Mode().IsRegular() {
		return errors.New("model defaults path is not a regular file; nothing was changed")
	}
	if model == "" && effort == "" {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	data, _ := json.Marshal(ModelDefaults{Version: 1, Model: model, Effort: effort})
	return writeAtomic(path, append(data, '\n'), 0o600)
}

// claudeSubcommands do not start a conversation; they get no defaults.
var claudeSubcommands = map[string]bool{
	"agents": true, "attach": true, "auth": true, "auto-mode": true, "config": true, "doctor": true,
	"gateway": true, "import": true, "install": true, "kill": true, "logs": true, "mcp": true,
	"migrate-installer": true, "plugin": true, "plugins": true, "purge": true, "respawn": true,
	"rm": true, "setup-token": true, "stop": true, "ultrareview": true, "update": true, "upgrade": true,
}

// WithClaudeDefaults prepends --model and --effort from the account's
// defaults to a new conversation that does not set them itself. A continued
// or resumed conversation keeps its own model.
func WithClaudeDefaults(defaults ModelDefaults, arguments []string) []string {
	if len(arguments) > 0 && claudeSubcommands[arguments[0]] {
		return arguments
	}
	model, effort := defaults.Model, defaults.Effort
	for _, argument := range arguments {
		switch {
		case argument == "--help" || argument == "-h" || argument == "--version" || argument == "-v",
			argument == "-c" || argument == "--continue" || argument == "-r" || argument == "--resume",
			strings.HasPrefix(argument, "--resume="):
			return arguments
		case argument == "--model" || strings.HasPrefix(argument, "--model="):
			model = ""
		case argument == "--effort" || strings.HasPrefix(argument, "--effort="):
			effort = ""
		}
	}
	var prefix []string
	if model != "" {
		prefix = append(prefix, "--model", model)
	}
	if effort != "" {
		prefix = append(prefix, "--effort", effort)
	}
	return append(prefix, arguments...)
}

// codexSessions are the Codex subcommands that start a new conversation;
// any other subcommand (resume and fork included) gets no defaults.
var codexSessions = map[string]bool{"exec": true, "e": true, "review": true}

// codexValueFlags take the next argument as their value.
var codexValueFlags = map[string]bool{
	"-c": true, "--config": true, "--enable": true, "--disable": true, "-m": true, "--model": true,
	"-p": true, "--profile": true, "-s": true, "--sandbox": true, "-a": true, "--ask-for-approval": true,
	"-C": true, "--cd": true, "--add-dir": true, "-i": true, "--image": true, "--reasoning-effort": true,
	"--remote": true, "--remote-auth-token-env": true, "--local-provider": true,
}

// WithCodexDefaults prepends -c model=... and -c model_reasoning_effort=...
// (config overrides reach every Codex subcommand) unless the launch sets
// them itself or runs a subcommand that starts no new conversation.
func WithCodexDefaults(defaults ModelDefaults, arguments []string) []string {
	model, effort := defaults.Model, defaults.Effort
	skip, command := false, ""
	for index, argument := range arguments {
		if skip {
			skip = false
			continue
		}
		value := ""
		switch {
		case argument == "--help" || argument == "-h" || argument == "--version" || argument == "-V":
			return arguments
		case argument == "-m" || argument == "--model" || strings.HasPrefix(argument, "--model="):
			model = ""
		case argument == "--reasoning-effort" || strings.HasPrefix(argument, "--reasoning-effort="):
			effort = ""
		case argument == "-c" || argument == "--config":
			if index+1 < len(arguments) {
				value = arguments[index+1]
			}
		case strings.HasPrefix(argument, "--config="):
			value = strings.TrimPrefix(argument, "--config=")
		case strings.HasPrefix(argument, "-c") && len(argument) > 2:
			value = argument[2:]
		}
		if key, _, found := strings.Cut(value, "="); found {
			switch strings.TrimSpace(key) {
			case "model":
				model = ""
			case "model_reasoning_effort":
				effort = ""
			}
		}
		if codexValueFlags[argument] {
			skip = true
			continue
		}
		if strings.HasPrefix(argument, "-") {
			continue
		}
		if command == "" {
			command = argument
			// The first positional is a subcommand or the prompt; a
			// subcommand other than a session gets no defaults.
			if codexNonSession(argument) {
				return arguments
			}
		} else if (command == "exec" || command == "e") && argument == "resume" {
			return arguments
		} else {
			command = "-"
		}
	}
	var prefix []string
	if model != "" {
		prefix = append(prefix, "-c", "model="+tomlString(model))
	}
	if effort != "" {
		prefix = append(prefix, "-c", "model_reasoning_effort="+tomlString(effort))
	}
	return append(prefix, arguments...)
}

var codexCommands = map[string]bool{
	"agents": true, "login": true, "logout": true, "mcp": true, "mcp-server": true, "plugin": true,
	"app-server": true, "remote-control": true, "app": true, "completion": true, "update": true,
	"doctor": true, "sandbox": true, "debug": true, "apply": true, "a": true, "queue": true,
	"archive": true, "delete": true, "migrate-rollouts": true, "unarchive": true, "cloud": true,
	"exec-server": true, "features": true, "help": true, "resume": true, "fork": true,
}

func codexNonSession(argument string) bool {
	return codexCommands[argument] && !codexSessions[argument]
}

// tomlString quotes a validated model or effort name for -c.
func tomlString(value string) string { return `"` + value + `"` }
