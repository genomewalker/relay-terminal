package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// Credentials are never journal settings or provider output. This private
// protocol accepts only an exact Relay item; no read operation is exported.
func hostRotationCredentialService(ctx context.Context, operation, reference, secret string) (json.RawMessage, error) {
	if !validPromptEditorID(reference) || (operation != "save" && operation != "status" && operation != "delete") ||
		(operation == "save") != (secret != "") {
		return nil, errors.New("invalid credential request")
	}
	if operation == "save" {
		if len(secret) < 16 || len(secret) > 512 {
			return nil, errors.New("invalid API credential")
		}
		for _, c := range []byte(secret) {
			if c <= 32 || c >= 127 {
				return nil, errors.New("invalid API credential")
			}
		}
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if runtime.GOOS == "darwin" {
		executable, err := os.Executable()
		if err != nil {
			return nil, errors.New("credential helper unavailable")
		}
		helper := filepath.Join(filepath.Dir(executable), "relay-credentials")
		input := map[string]any{"v": 1, "operation": operation, "reference": reference}
		if operation == "save" {
			input["secret"] = secret
		}
		raw, _ := json.Marshal(input)
		command := exec.CommandContext(ctx, helper)
		command.Stdin = bytes.NewReader(raw)
		command.Stderr = io.Discard
		var output rotationBoundedOutput
		command.Stdout = &output
		if err := command.Run(); err != nil || !json.Valid(output.Bytes()) {
			return nil, errors.New("Keychain unavailable or locked; unlock it and check this credential's status")
		}
		return json.RawMessage(output.Bytes()), nil
	}
	if runtime.GOOS != "linux" {
		return nil, errors.New("secure credential storage unsupported on this host")
	}
	// Query presence without activating or installing a desktop service.
	probe := exec.CommandContext(ctx, "/usr/bin/gdbus", "call", "--session", "--dest", "org.freedesktop.DBus",
		"--object-path", "/org/freedesktop/DBus", "--method", "org.freedesktop.DBus.NameHasOwner", "org.freedesktop.secrets")
	probe.Stderr = io.Discard
	presence, err := probe.Output()
	if err != nil || string(bytes.TrimSpace(presence)) != "(true,)" {
		return nil, errors.New("an unlocked encrypted Secret Service is required on this host")
	}
	attributes := []string{"relay-service", "dev.relay.terminal.capsule", "relay-ref", reference}
	invoke := func(args []string, input []byte) ([]byte, error) {
		command := exec.CommandContext(ctx, "/usr/bin/secret-tool", args...)
		command.Stdin = bytes.NewReader(input)
		command.Stderr = io.Discard
		var output rotationBoundedOutput
		command.Stdout = &output
		err := command.Run()
		return output.Bytes(), err
	}
	status := "saved"
	if operation == "status" {
		data, err := invoke(append([]string{"lookup"}, attributes...), nil)
		if err != nil || len(bytes.TrimSpace(data)) == 0 {
			status = "missing_or_locked"
		}
	} else if operation == "save" {
		existing, _ := invoke(append([]string{"lookup"}, attributes...), nil)
		if len(bytes.TrimSpace(existing)) > 0 {
			return nil, errors.New("credential reference exists; use a new reference")
		}
		if _, err := invoke(append([]string{"store", "--label=Relay Anthropic API"}, attributes...), []byte(secret)); err != nil {
			return nil, errors.New("secure save outcome unavailable; check this credential's status before retrying")
		}
		data, err := invoke(append([]string{"lookup"}, attributes...), nil)
		if err != nil || strings.TrimSpace(string(data)) != secret {
			return nil, errors.New("secure save not confirmed; check this credential's status before retrying")
		}
	} else {
		if _, err := invoke(append([]string{"clear"}, attributes...), nil); err != nil {
			return nil, errors.New("secure delete outcome unavailable; check this credential's status")
		}
		status = "deleted"
	}
	raw, _ := json.Marshal(map[string]any{"v": 1, "status": status, "reference": reference, "storage": "linux_secret_service"})
	return json.RawMessage(raw), nil
}
