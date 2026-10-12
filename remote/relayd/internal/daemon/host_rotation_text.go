package daemon

import (
	"bytes"
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
)

// Canonical resource: Sources/Relay/Resources/Rotation/text_backend.py.
// The parity test prevents a release from bundling a different security policy.
//
//go:embed host_rotation_text.py
var hostRotationText []byte

func hostRotationTextService(ctx context.Context, workerDirectory, operation string, request any) (json.RawMessage, error) {
	switch operation {
	case "status", "configure", "submit", "abandon":
	default:
		return nil, errors.New("unsupported text service operation")
	}
	root := filepath.Join(workerDirectory, "rotation-text")
	if operation == "status" {
		if _, err := os.Lstat(root); errors.Is(err, os.ErrNotExist) {
			return json.RawMessage(`{"v":1,"status":"not_configured","enabled":false}`), nil
		}
	}
	if err := privateBindingObject(workerDirectory, true); err != nil {
		return nil, errors.New("text service state directory unavailable")
	}
	data, err := json.Marshal(request)
	if err != nil || len(data) > 262144 {
		return nil, errors.New("invalid text service request")
	}
	python, err := hostRotationTextPython(ctx)
	if err != nil {
		return nil, errors.New("text service Python unavailable")
	}
	result, err := hostRotationTextCommand(ctx, python, []string{"-I", "-S", "-c", string(hostRotationText),
		"--state-dir", root, "--operation", operation}, data)
	if err != nil {
		// Raw command/provider diagnostics must not cross the RPC boundary.
		return nil, errors.New("text service outcome unavailable; inspect operation status")
	}
	if !json.Valid(result) {
		return nil, errors.New("invalid text service response")
	}
	return result, nil
}

func hostRotationTextPython(ctx context.Context) (string, error) {
	// Some Linux hosts still map python3 to 3.6 while a supported interpreter
	// is installed alongside it. Never silently use that old network runtime.
	candidates := []string{}
	seen := map[string]bool{}
	for _, name := range []string{"python3.14", "python3.13", "python3.12", "python3.11", "python3"} {
		if path, err := exec.LookPath(name); err == nil {
			candidates = append(candidates, path)
		}
		// GUI-launched workers can have only /usr/bin:/bin in PATH.
		for _, dir := range []string{"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"} {
			path := filepath.Join(dir, name)
			if info, err := os.Stat(path); err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0111 != 0 {
				candidates = append(candidates, path)
			}
		}
	}
	for _, path := range candidates {
		if seen[path] {
			continue
		}
		seen[path] = true
		probe, cancel := context.WithTimeout(ctx, 2*time.Second)
		output, err := hostRotationCommand(probe, path,
			[]string{"-I", "-S", "-c", "import sys,ssl,sqlite3; print('supported' if sys.version_info >= (3,11) and hasattr(ssl,'TLSVersion') else 'unsupported')"}, nil)
		cancel()
		if err == nil && string(output) == "supported\n" {
			return path, nil
		}
		if ctx.Err() != nil {
			break
		}
	}
	return "", errors.New("Python 3.11 or newer with TLS and SQLite is required")
}

// A draft may own a CLI child. Let the journaled adapter stop and reap that
// child on cancellation before the bounded fallback kills the adapter.
func hostRotationTextCommand(ctx context.Context, binary string, args []string, input []byte) ([]byte, error) {
	command := exec.CommandContext(ctx, binary, args...)
	command.Cancel = func() error { return command.Process.Signal(syscall.SIGTERM) }
	command.WaitDelay = 3 * time.Second
	command.Stdin = bytes.NewReader(input)
	// Only this trusted sibling path may resolve a Mac vault credential.
	if executable, err := os.Executable(); err == nil {
		helper := filepath.Join(filepath.Dir(executable), "relay-credentials")
		environment := []string{}
		for _, entry := range os.Environ() {
			if !bytes.HasPrefix([]byte(entry), []byte("RELAY_CREDENTIAL_HELPER=")) {
				environment = append(environment, entry)
			}
		}
		command.Env = append(environment, "RELAY_CREDENTIAL_HELPER="+helper)
	}
	var output rotationBoundedOutput
	command.Stdout = &output
	command.Stderr = io.Discard
	if err := command.Run(); err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}
