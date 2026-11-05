package capacity

import (
	"errors"
	"path/filepath"
	"strings"
	"unicode"
)

// Recipe is a checked data recipe from a native argv observation. It never
// accepts shell command text, imports environment variables or executes itself.
type Recipe struct {
	Provider      string   `json:"provider"`
	Executable    string   `json:"executable"`
	Arguments     []string `json:"arguments"`
	Config        string   `json:"config"`
	PriorSession  string   `json:"prior_session"`
	RemovedPrompt bool     `json:"removed_prompt"`
}

func ParseRecipe(provider, executable, config string, args []string) (Recipe, error) {
	r := Recipe{Provider: provider, Executable: executable, Config: config, Arguments: []string{}}
	clean := func(s string) bool {
		return len(s) <= 8192 && !strings.ContainsFunc(s, func(c rune) bool { return unicode.IsControl(c) })
	}
	if (provider != "claude" && provider != "codex") || !filepath.IsAbs(executable) || !filepath.IsAbs(config) || !clean(executable) || !clean(config) || len(args) > 128 {
		return r, errors.New("native_restart_recipe_unavailable")
	}
	values := map[string]bool{"--model": true, "--effort": true, "--permission-mode": true, "--settings": true, "--setting-sources": true, "--agent": true, "--system-prompt": true, "--system-prompt-file": true, "--append-system-prompt": true, "--append-system-prompt-file": true, "--fallback-model": true, "--teammate-mode": true, "--add-dir": true, "--mcp-config": true, "--plugin-dir": true, "--tools": true, "--allowedTools": true, "--disallowedTools": true, "--betas": true, "--config": true, "--profile": true, "--sandbox": true, "--ask-for-approval": true}
	flags := map[string]bool{"--dangerously-skip-permissions": true, "--allow-dangerously-skip-permissions": true, "--strict-mcp-config": true, "--verbose": true, "--chrome": true, "--no-chrome": true}
	if provider == "codex" {
		values = map[string]bool{"--model": true, "--config": true, "--profile": true, "--sandbox": true, "--ask-for-approval": true, "--add-dir": true}
		flags = map[string]bool{}
		if len(args) > 0 && args[0] == "resume" {
			if len(args) < 2 || !recipeSession(args[1]) {
				return r, errors.New("native_restart_recipe_exact_resume_session_required")
			}
			r.PriorSession = args[1]
			args = args[2:]
		}
	} else {
		// Provider-specific data only. Codex profile/sandbox switches are not
		// Claude permissions, and no shell subcommand is interpreted here.
		for _, key := range []string{"--config", "--profile", "--sandbox", "--ask-for-approval"} {
			delete(values, key)
		}
	}
	seen := map[string]bool{}
	positional := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		if !clean(a) {
			return r, errors.New("native_restart_recipe_invalid_argument")
		}
		if a == "--" {
			if positional || i+2 != len(args) {
				return r, errors.New("native_restart_recipe_ambiguous_prompt")
			}
			if !clean(args[i+1]) {
				return r, errors.New("native_restart_recipe_invalid_prompt")
			}
			r.RemovedPrompt = true
			return r, nil
		}
		if !strings.HasPrefix(a, "-") {
			if positional {
				return r, errors.New("native_restart_recipe_ambiguous_prompt")
			}
			positional = true
			r.RemovedPrompt = true
			continue
		}
		key, value, inline := strings.Cut(a, "=")
		if seen[key] && key != "--add-dir" && key != "--plugin-dir" {
			return r, errors.New("native_restart_recipe_duplicate_option")
		}
		seen[key] = true
		if key == "--resume" || key == "-r" || key == "--session-id" {
			if provider != "claude" {
				return r, errors.New("native_restart_recipe_provider_selector_unsupported")
			}
			if !inline {
				if i+1 >= len(args) {
					return r, errors.New("native_restart_recipe_missing_session")
				}
				i++
				value = args[i]
			}
			if !recipeSession(value) || r.PriorSession != "" {
				return r, errors.New("native_restart_recipe_ambiguous_session")
			}
			r.PriorSession = value
			continue
		}
		if flags[key] && !inline {
			r.Arguments = append(r.Arguments, a)
			continue
		}
		if !values[key] {
			return r, errors.New("native_restart_recipe_unsupported_option")
		}
		if inline {
			if value == "" || !clean(value) {
				return r, errors.New("native_restart_recipe_missing_value")
			}
			r.Arguments = append(r.Arguments, a)
		} else {
			if i+1 >= len(args) || args[i+1] == "" || strings.HasPrefix(args[i+1], "--") || !clean(args[i+1]) {
				return r, errors.New("native_restart_recipe_missing_value")
			}
			i++
			r.Arguments = append(r.Arguments, key, args[i])
		}
	}
	return r, nil
}

func recipeSession(s string) bool {
	if len(s) == 0 || len(s) > 128 {
		return false
	}
	for i, c := range s {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
			continue
		}
		if i > 0 && (c == '-' || c == '_') {
			continue
		}
		return false
	}
	return true
}
