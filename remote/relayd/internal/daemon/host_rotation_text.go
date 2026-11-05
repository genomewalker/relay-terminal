package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/relay-terminal/relayd/internal/rotationtext"
)

// The text service runs in process: rotationtext is the Go port of
// Sources/Relay/Resources/Rotation/text_backend.py (differential tests keep
// them equal) over the Go ledger, which imports the former
// rotation-text/operations.sqlite3 once and leaves it untouched.

func hostRotationTextService(ctx context.Context, workerDirectory, operation string, request any) (json.RawMessage, error) {
	switch operation {
	case "status", "configure", "submit", "assess", "assist", "abandon":
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
	result, err := hostRotationTextRun(ctx, root, operation, data)
	if err != nil {
		// Raw command/provider diagnostics must not cross the RPC boundary.
		return nil, errors.New("text service outcome unavailable; inspect operation status")
	}
	if !json.Valid(result) {
		return nil, errors.New("invalid text service response")
	}
	return result, nil
}

// hostRotationTextEnvironment is the inherited environment with the trusted
// credential helper; nil (inherit unchanged) when relayd cannot locate itself.
func hostRotationTextEnvironment() []string {
	// Only this trusted sibling path may resolve a Mac vault credential.
	executable, err := os.Executable()
	if err != nil {
		return nil
	}
	helper := filepath.Join(filepath.Dir(executable), "relay-credentials")
	environment := []string{}
	for _, entry := range os.Environ() {
		if !bytes.HasPrefix([]byte(entry), []byte("RELAY_CREDENTIAL_HELPER=")) {
			environment = append(environment, entry)
		}
	}
	return append(environment, "RELAY_CREDENTIAL_HELPER="+helper)
}

func init() {
	// The text co-processes saw RELAY_CREDENTIAL_HELPER from
	// hostRotationTextEnvironment: the sibling helper when relayd can locate
	// itself, otherwise the inherited value. Both text paths now read it here.
	if executable, err := os.Executable(); err == nil {
		rotationtext.CredentialHelper = filepath.Join(filepath.Dir(executable), "relay-credentials")
	}
}

// hostRotationTextRun is the former co-process's run: one operation against
// the journal, whose CLI children it stops and reaps itself on cancellation.
func hostRotationTextRun(ctx context.Context, root, operation string, data []byte) (result []byte, err error) {
	defer func() {
		if recover() != nil {
			result, err = nil, errors.New("text service failed")
		}
	}()
	return rotationtext.RunOperation(ctx, func() (*rotationtext.Journal, error) {
		return rotationtext.OpenLedgerJournal(ctx, root)
	}, operation, data)
}
