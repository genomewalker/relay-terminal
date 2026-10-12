package daemon

import (
	"encoding/json"
	"errors"
	"net"
	"os"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

var ErrPromptEditorUnsupported = errors.New("prompt editor is unsupported by this worker")

// CallPromptEditor only contacts an existing, verified pane worker. Probe is
// deliberately set as well: an older worker that ignores the new JSON field
// must return its read-only readiness status, never attach a terminal client.
func CallPromptEditor(pane, clientID string, request json.RawMessage) (json.RawMessage, error) {
	if !validSessionID.MatchString(pane) || len(request) > 2*promptEditorDraftLimit {
		return nil, errors.New("invalid prompt editor request")
	}
	var decoded promptEditorRequest
	if json.Unmarshal(request, &decoded) != nil {
		return nil, errors.New("invalid prompt editor request")
	}
	server := NewServer()
	manifest, err := loadManifest(server.manifestPath(pane))
	if err != nil || manifest.SessionID != pane || validateWorkerIdentity(manifest) != nil {
		return nil, errors.New("prompt editor worker unavailable")
	}
	return callVerifiedPromptEditorWorker(manifest, clientID, request)
}

func callVerifiedPromptEditorWorker(manifest workerManifest, clientID string, request json.RawMessage) (json.RawMessage, error) {
	connection, err := net.DialTimeout("unix", manifest.SocketPath, time.Second)
	if err != nil {
		return nil, err
	}
	defer connection.Close()
	uid, pid, err := PeerCredentials(connection)
	if err != nil || uid != os.Getuid() || pid != manifest.WorkerPID {
		return nil, errors.New("prompt editor worker socket changed")
	}
	if err := connection.SetDeadline(time.Now().Add(25 * time.Second)); err != nil {
		return nil, err
	}
	hello, err := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: workerProtocolVersion, SessionID: manifest.SessionID, WorkerToken: manifest.Token,
		ClientID: clientID, Probe: true, PromptEditor: request,
	})
	if err != nil {
		return nil, err
	}
	if err := protocol.NewWriter(connection).Write(hello); err != nil {
		return nil, err
	}
	response, err := protocol.ReadFrame(connection)
	if err != nil || response.Type != protocol.Status {
		return nil, errors.New("prompt editor worker response unavailable")
	}
	var status promptEditorResponse
	if protocol.DecodeJSON(response, &status) != nil {
		return nil, errors.New("invalid prompt editor worker response")
	}
	switch status.State {
	case "armed", "captured", "committed", "cancelled", "delivered", "refused", "unarmed", "unavailable", "busy", "applied", "failed":
		return json.RawMessage(response.Payload), nil
	default:
		return nil, ErrPromptEditorUnsupported
	}
}
