// Package agentlaunch retains exact launch arguments without shell re-quoting.
package agentlaunch

import (
	"regexp"
	"strings"
)

var sessionUUID = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

type Arguments struct {
	Fresh    []string `json:"fresh_args,omitempty"`
	Prompts  []string `json:"initial_prompts,omitempty"`
	Reusable bool     `json:"reusable"`
	Reason   string   `json:"reason,omitempty"`
}

// FreshArguments removes conversation selection, not configuration. Unknown
// options are retained in the raw snapshot but prevent automatic replay: their
// arity cannot safely be inferred from whitespace or the next token.
func FreshArguments(client string, argv []string) Arguments {
	result := Arguments{Fresh: []string{}, Prompts: []string{}, Reusable: true}
	if client != "claude" && client != "codex" {
		return Arguments{Reason: "unsupported_client"}
	}
	value := map[string]bool{}
	plain := map[string]bool{}
	variadic := map[string]bool{}
	if client == "claude" {
		for _, flag := range strings.Fields("--name -n --model --effort --permission-mode --settings --setting-sources --agent --agents --append-system-prompt --append-system-prompt-file --system-prompt --system-prompt-file --append-subagent-system-prompt --append-subagent-system-prompt-file --system-prompt-snapshot --output-format --input-format --json-schema --max-turns --max-budget-usd --fallback-model --debug-file --teammate-mode --autocompact") {
			value[flag] = true
		}
		for _, flag := range strings.Fields("--print -p --verbose --include-partial-messages --replay-user-messages --strict-mcp-config --dangerously-skip-permissions --allow-dangerously-skip-permissions --chrome --no-chrome --disable-slash-commands --include-hook-events --forward-subagent-text") {
			plain[flag] = true
		}
		for _, flag := range strings.Fields("--tools --allowedTools --allowed-tools --disallowedTools --disallowed-tools --add-dir --mcp-config --plugin-dir --betas") {
			variadic[flag] = true
		}
	} else {
		for _, flag := range strings.Fields("--config -c --model -m --profile -p --sandbox -s --ask-for-approval -a --cd -C --reasoning-effort --permissions --approval-policy") {
			value[flag] = true
		}
		for _, flag := range strings.Fields("--full-auto --dangerously-bypass-approvals-and-sandbox --no-alt-screen --search --strict-config --oss --ephemeral --no-session-persistence") {
			plain[flag] = true
		}
		for _, flag := range strings.Fields("--enable --disable --add-dir") {
			value[flag] = true
		}
		// Initial attachments are content, not reusable session configuration.
		variadic["--image"] = true
		variadic["-i"] = true
	}
	historyMode := false
	historySelectorPending := false
	for i := 0; i < len(argv); i++ {
		arg := argv[i]
		flag, _, equals := strings.Cut(arg, "=")
		if arg == "--" {
			result.Prompts = append(result.Prompts, argv[i+1:]...)
			break
		}
		if client == "codex" && (arg == "resume" || arg == "fork") {
			historyMode = true
			historySelectorPending = true
			if i+1 < len(argv) && !strings.HasPrefix(argv[i+1], "-") {
				i++
				historySelectorPending = false
			}
			continue
		}
		if client == "codex" && flag == "--remote" {
			if !equals {
				if i+1 >= len(argv) || strings.HasPrefix(argv[i+1], "-") {
					return Arguments{Reason: "missing_remote_endpoint"}
				}
				i++
			}
			// Transport is resolved from the live process at rotation time.
			continue
		}
		if client == "codex" && flag == "--remote-auth-token-env" {
			return Arguments{Reason: "remote_auth_requires_review"}
		}
		if client == "codex" && arg == "--no-daemon" {
			continue
		}
		if client == "claude" && (flag == "--continue" || flag == "-c" || flag == "--fork-session" || flag == "--bg" || flag == "--background") {
			continue
		}
		if client == "claude" && (flag == "--resume" || flag == "-r" || flag == "--from-pr" || flag == "--teleport") {
			if equals {
				return Arguments{Reason: "selector_equals_form_requires_review"}
			}
			if i+1 < len(argv) && !strings.HasPrefix(argv[i+1], "-") {
				if (flag != "--resume" && flag != "-r") || !sessionUUID.MatchString(argv[i+1]) {
					return Arguments{Reason: "ambiguous_optional_selector"}
				}
				i++
			}
			continue
		}
		if client == "claude" && flag == "--cloud" {
			return Arguments{Reason: "cloud_mode_requires_review"}
		}
		if client == "claude" && flag == "--session-id" {
			if !equals {
				if i+1 >= len(argv) || strings.HasPrefix(argv[i+1], "-") {
					return Arguments{Reason: "missing_session_id"}
				}
				i++
			}
			continue
		}
		if client == "codex" && historyMode && (flag == "--last" || flag == "--all") {
			historySelectorPending = false
			continue
		}
		if value[flag] {
			result.Fresh = append(result.Fresh, arg)
			if !equals {
				if i+1 >= len(argv) {
					return Arguments{Reason: "missing_option_value"}
				}
				i++
				result.Fresh = append(result.Fresh, argv[i])
			}
			continue
		}
		if variadic[flag] {
			if client == "codex" && (flag == "--image" || flag == "-i") {
				result.Reusable = false
				result.Reason = "initial_attachment_requires_review"
			}
			result.Fresh = append(result.Fresh, arg)
			if !equals {
				if i+1 >= len(argv) {
					return Arguments{Reason: "missing_option_value"}
				}
				for i+1 < len(argv) && !strings.HasPrefix(argv[i+1], "-") {
					i++
					result.Fresh = append(result.Fresh, argv[i])
				}
			}
			continue
		}
		if plain[flag] && !equals {
			result.Fresh = append(result.Fresh, arg)
			continue
		}
		if strings.HasPrefix(arg, "-") {
			result.Reusable = false
			result.Reason = "unknown_option_requires_review"
			// Stop parsing; an unknown flag may consume a history-looking token.
			result.Fresh = nil
			return result
		}
		if client == "codex" && historySelectorPending {
			if !sessionUUID.MatchString(arg) {
				return Arguments{Reason: "ambiguous_history_selector"}
			}
			historySelectorPending = false
			continue
		}
		if client == "claude" && len(result.Prompts) == 0 {
			switch arg {
			case "mcp", "plugin", "plugins", "install", "update", "auth", "agents", "attach", "daemon", "doctor", "import", "logs", "respawn", "rm", "stop", "kill", "gateway", "remote-control", "setup-token":
				return Arguments{Reason: "noninteractive_command_requires_review"}
			}
		}
		if client == "codex" && len(result.Fresh) == 0 && len(result.Prompts) == 0 && !historyMode {
			switch arg {
			case "exec", "e", "review", "login", "logout", "app-server", "mcp", "mcp-server", "sandbox", "doctor", "apply", "features":
				return Arguments{Reason: "noninteractive_command_requires_review"}
			}
		}
		result.Prompts = append(result.Prompts, arg)
	}
	if client == "codex" && historySelectorPending {
		return Arguments{Reason: "unresolved_history_picker"}
	}
	return result
}
