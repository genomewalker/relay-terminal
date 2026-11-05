package agentlaunch

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// CodexLaunchDefaults is an explicit, user-owned Relay policy. Absence keeps
// legacy saved-thread permissions; a malformed policy never enables access.
func CodexLaunchDefaults(codexHome string) (CodexPermissions, bool, error) {
	if !filepath.IsAbs(codexHome) {
		return CodexPermissions{}, false, errors.New("Codex home is not absolute")
	}
	path := filepath.Join(codexHome, "relay-launch-defaults.json")
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return CodexPermissions{}, false, nil
	}
	if err != nil {
		return CodexPermissions{}, false, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || stat.Uid != uint32(os.Getuid()) || info.Size() > 4096 {
		return CodexPermissions{}, false, errors.New("Relay Codex launch defaults are not a private owned file")
	}
	file, err := os.Open(path)
	if err != nil {
		return CodexPermissions{}, false, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !os.SameFile(info, opened) {
		return CodexPermissions{}, false, errors.New("Relay Codex launch defaults changed while opening")
	}
	var value struct {
		Version        int    `json:"version"`
		SandboxMode    string `json:"sandbox_mode"`
		ApprovalPolicy string `json:"approval_policy"`
	}
	decoder := json.NewDecoder(io.LimitReader(file, 4097))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&value); err != nil {
		return CodexPermissions{}, false, err
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return CodexPermissions{}, false, errors.New("Relay Codex launch defaults contain trailing data")
	}
	permissions := CodexPermissions{SandboxMode: value.SandboxMode, ApprovalPolicy: value.ApprovalPolicy}
	if value.Version != 1 || !codexSandboxModes[permissions.SandboxMode] || !codexApprovalPolicies[permissions.ApprovalPolicy] {
		return CodexPermissions{}, false, errors.New("Relay Codex launch defaults have unknown permission values")
	}
	return permissions, true, nil
}

// ManagedCodexLaunchPolicy moves permission choices to the private backend:
// official --remote frontends reject these flags. Explicit flags override the
// user's Relay defaults, which in turn override a resumed thread's old mode.
func ManagedCodexLaunchPolicy(codexHome string, arguments []string) ([]string, CodexPermissions, error) {
	permissions, configured, err := CodexLaunchDefaults(codexHome)
	if err != nil {
		return nil, CodexPermissions{}, err
	}
	if !configured {
		// Find the thread independently of explicit permission options.
		for i := 0; i+1 < len(arguments); i++ {
			if arguments[i] == "resume" && sessionUUID.MatchString(arguments[i+1]) {
				if saved, readErr := SavedCodexPermissions(codexHome, arguments[i+1]); readErr == nil {
					permissions = saved
				}
				break
			}
		}
	}
	frontend := make([]string, 0, len(arguments))
	explicit := false
	for i := 0; i < len(arguments); i++ {
		argument := arguments[i]
		if argument == "--" {
			frontend = append(frontend, arguments[i:]...)
			break
		}
		flag, inline, hasInline := strings.Cut(argument, "=")
		switch flag {
		case "--dangerously-bypass-approvals-and-sandbox":
			permissions = CodexPermissions{SandboxMode: "danger-full-access", ApprovalPolicy: "never"}
			explicit = true
		case "--full-auto":
			permissions = CodexPermissions{SandboxMode: "workspace-write", ApprovalPolicy: "on-request"}
			explicit = true
		case "--sandbox", "-s", "--ask-for-approval", "-a", "-c", "--config":
			value := inline
			if !hasInline {
				if i+1 >= len(arguments) {
					return nil, CodexPermissions{}, fmt.Errorf("missing value for %s", flag)
				}
				i++
				value = arguments[i]
			}
			field := "sandbox_mode"
			if flag == "--ask-for-approval" || flag == "-a" {
				field = "approval_policy"
			}
			if flag == "-c" || flag == "--config" {
				key, configValue, _ := strings.Cut(value, "=")
				field = strings.TrimSpace(key)
				if field != "sandbox_mode" && field != "approval_policy" {
					if strings.HasPrefix(field, "sandbox_") {
						return nil, CodexPermissions{}, errors.New("custom Codex sandbox configuration requires a direct launch")
					}
					if hasInline {
						frontend = append(frontend, argument)
					} else {
						frontend = append(frontend, argument, value)
					}
					continue
				}
				value = strings.Trim(strings.TrimSpace(configValue), "\"'")
			}
			if field == "sandbox_mode" {
				if !codexSandboxModes[value] {
					return nil, CodexPermissions{}, errors.New("unknown Codex sandbox mode")
				}
				permissions.SandboxMode = value
			} else {
				if !codexApprovalPolicies[value] {
					return nil, CodexPermissions{}, errors.New("unknown Codex approval policy")
				}
				permissions.ApprovalPolicy = value
			}
			explicit = true
		default:
			frontend = append(frontend, argument)
		}
	}
	if explicit && (!codexSandboxModes[permissions.SandboxMode] || !codexApprovalPolicies[permissions.ApprovalPolicy]) {
		return nil, CodexPermissions{}, errors.New("specify both sandbox and approval policy for this new managed Codex launch")
	}
	return frontend, permissions, nil
}
