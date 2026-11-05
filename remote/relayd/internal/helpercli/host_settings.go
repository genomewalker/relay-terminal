package helpercli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"regexp"
	"strings"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// HostSettingsRequest uses the same owner-authenticated node route as Settings.
// It never rewrites a settings file or reads a credential from the key store.
type HostSettingsRequest func(context.Context, string, map[string]any) (map[string]any, error)

var settingsHostName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$`)
var settingsOperationID = regexp.MustCompile(`^[a-f0-9]{32}$`)

func nativeSettingsNode(ctx context.Context, host string, request map[string]any) (map[string]any, error) {
	ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	var cmd *exec.Cmd
	if host == "This Mac" || host == "local" {
		cmd = exec.CommandContext(ctx, "/Applications/Relay.app/Contents/MacOS/relayd", "node")
	} else {
		if !settingsHostName.MatchString(host) {
			return nil, errors.New("expected an exact SSH host alias")
		}
		cmd = exec.CommandContext(ctx, "/usr/bin/ssh", "-T", "--", host, "~/.local/bin/relayd node")
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	diagnostics := &boundedOutput{limit: 16384}
	cmd.Stderr = diagnostics
	if err = cmd.Start(); err != nil {
		return nil, err
	}
	defer func() { _ = stdin.Close(); cancel(); _ = cmd.Wait() }()
	payload, err := json.Marshal(request)
	if err != nil || len(payload) > 66<<10 {
		return nil, errors.New("bounded native configuration request required")
	}
	if err = protocol.NewWriter(stdin).Write(protocol.Frame{Type: protocol.HostRequest, Payload: payload}); err != nil {
		return nil, err
	}
	for i := 0; i < 32; i++ {
		frame, err := protocol.ReadFrame(stdout)
		if err != nil {
			return nil, errors.New("native configuration response unavailable; reconcile the original request ID before retrying")
		}
		if frame.Type != protocol.HostResponse {
			continue
		}
		reply, err := jsonObject(frame.Payload, 1<<20)
		if err != nil {
			return nil, err
		}
		if reply["request_id"] != request["request_id"] {
			continue
		}
		if message, ok := reply["error"].(string); ok && message != "" {
			return nil, fmt.Errorf("native configuration refused: %s", message)
		}
		result, ok := reply["result"].(map[string]any)
		if !ok {
			return nil, errors.New("invalid native configuration response")
		}
		return result, nil
	}
	return nil, errors.New("matching native configuration receipt unavailable")
}

// RunHostSettings provides host model/account limits without the desktop UI.
// All mutations retain the native compare-and-swap and idempotent operation ID.
func RunHostSettings(ctx context.Context, args []string, stdout, stderr io.Writer, deps SettingsDependencies) error {
	if len(args) < 3 || (args[1] != "text" && args[1] != "capacity" && args[1] != "accounts") {
		return &UsageError{Message: "Usage: relay-settings host HOST {text|capacity} {get [key],set key JSON,update --file PATH} [--request-id ID] [--expected-revision REV]; host HOST {accounts|text} request --file PATH"}
	}
	host := args[0]
	if host != "This Mac" && host != "local" && !settingsHostName.MatchString(host) {
		return &UsageError{Message: "expected an exact SSH host alias"}
	}
	domain := args[1]
	if args[2] == "request" || domain == "accounts" {
		return runNativeSettingsRequest(ctx, host, domain, args[2:], stdout, stderr, deps)
	}
	a, err := parseSettings(args[2:])
	if err != nil {
		return &UsageError{Message: err.Error()}
	}
	if a.action != "get" && a.action != "set" && a.action != "update" {
		return &UsageError{Message: "host settings supports get, set and update"}
	}
	if deps.NativeRequest == nil || deps.UUID == nil || deps.ReadFile == nil {
		return errors.New("native settings dependencies unavailable")
	}
	rpcID, err := deps.UUID()
	if err != nil {
		return err
	}
	current, err := deps.NativeRequest(ctx, host, map[string]any{
		"request_id": "settings-" + rpcID, "operation": "host_accounts",
		"host_accounts": map[string]any{"request": map[string]any{"v": 1, "operation": domain + "_status"}},
	})
	if err != nil {
		return err
	}
	settings, hasSettings := current["settings"].(map[string]any)
	if a.action == "get" {
		if a.key == "" {
			return printJSON(stdout, current)
		}
		value, err := required(settings, a.key)
		if err != nil {
			return err
		}
		return printJSON(stdout, value)
	}
	var changes map[string]any
	if a.action == "set" {
		if !hasSettings {
			return errors.New("host is not configured; supply a complete update file")
		}
		if _, exists := settings[a.key]; !exists {
			return fmt.Errorf("unknown native setting: %s", a.key)
		}
		changes = make(map[string]any, len(settings))
		for key, value := range settings {
			changes[key] = value
		}
		value, err := decodeJSON([]byte(a.value), 32768)
		if err != nil {
			return errors.New("host setting values must be valid JSON")
		}
		changes[a.key] = value
	} else {
		data, err := deps.ReadFile(a.file)
		if err != nil {
			return err
		}
		changes, err = jsonObject(data, 32768)
		if err != nil {
			return err
		}
	}
	revision, _ := current["configuration_id"].(string)
	if domain == "capacity" {
		revision = fmt.Sprint(current["revision"])
	}
	if a.revision != "" && a.revision != revision {
		return errors.New("host configuration changed; read current settings before saving")
	}
	id := a.requestID
	if id == "" {
		id, err = deps.UUID()
		if err != nil {
			return err
		}
	}
	id = strings.ReplaceAll(strings.ToLower(id), "-", "")
	if !settingsOperationID.MatchString(id) {
		return &UsageError{Message: "request ID must be a UUID or 32 hexadecimal characters"}
	}
	if _, err = fmt.Fprintln(stderr, "Native settings request:", id); err != nil {
		return err
	}
	request := map[string]any{"v": 1, "operation": domain + "_configure", "id": id}
	forward := map[string]any{"request": request}
	if domain == "text" {
		request["text_settings"] = changes
		forward["expected_configuration_id"] = revision
	} else {
		request["settings"] = changes
		request["expected_revision"] = current["revision"]
	}
	result, err := deps.NativeRequest(ctx, host, map[string]any{
		"request_id": "settings-" + id, "operation": "host_accounts", "host_accounts": forward,
	})
	if err != nil {
		return err
	}
	return printJSON(stdout, result)
}

// Explicit native configuration requests cover provider account slots and API
// credentials. Data comes from a bounded file, never an interpolated command.
// Runtime actions (process termination, sign-out/removal, sending or migration)
// are excluded; they retain their separate native action/approval contracts.
func runNativeSettingsRequest(ctx context.Context, host, domain string, args []string, stdout, stderr io.Writer, deps SettingsDependencies) error {
	if deps.NativeRequest == nil || deps.UUID == nil || deps.ReadFile == nil {
		return errors.New("native settings dependencies unavailable")
	}
	var request map[string]any
	if domain == "accounts" && len(args) == 1 && args[0] == "get" {
		request = map[string]any{"action": "list", "probe": false}
	} else {
		if len(args) != 3 || args[0] != "request" || args[1] != "--file" {
			return &UsageError{Message: "native settings: get, or request --file PATH"}
		}
		data, err := deps.ReadFile(args[2])
		if err != nil {
			return err
		}
		request, err = jsonObject(data, 32768)
		if err != nil {
			return err
		}
		operation, _ := request["operation"].(string)
		action, _ := request["action"].(string)
		allowed := false
		if domain == "text" {
			switch operation {
			case "text_credential_save", "text_credential_status", "text_credential_delete", "text_credential_list", "text_vault_unlock":
				allowed = true
			}
		} else {
			switch action {
			case "list", "configure", "usage", "launchers", "repair_launchers", "mcp_preview", "prepare", "set_expectation", "set_defaults":
				allowed = true
			}
		}
		if !allowed {
			return errors.New("not a native configuration operation; use its dedicated action interface")
		}
	}
	id, err := deps.UUID()
	if err != nil {
		return err
	}
	envelope := map[string]any{"request_id": "settings-" + id}
	if domain == "accounts" {
		envelope["operation"] = "agent_accounts"
		envelope["agent_accounts"] = request
	} else {
		envelope["operation"] = "host_accounts"
		envelope["host_accounts"] = map[string]any{"request": request}
	}
	if _, err = fmt.Fprintln(stderr, "Native settings request:", id); err != nil {
		return err
	}
	result, err := deps.NativeRequest(ctx, host, envelope)
	if err != nil {
		return err
	}
	return printJSON(stdout, result)
}
