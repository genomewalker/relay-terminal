package daemon

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// GuardedRotationInput sends a single, bounded request directly to the exact
// existing worker. It never uses InputV2, whose reconnect path retries writes.
// A timeout or lost acknowledgement is an unknown outcome, not a retry signal.
func (server *Server) GuardedRotationInput(paneID, operationID string, pid int, start uint64, text string) error {
	if !validSessionID.MatchString(paneID) || operationID == "" || pid <= 0 || start == 0 {
		return errors.New("invalid guarded input target")
	}
	if _, err := os.Lstat(filepath.Join(server.stateDir, "rotation-launches", paneID+".json")); err != nil {
		return errors.New("pane was not launched as a controlled rotation")
	}
	manifest, err := loadManifest(server.manifestPath(paneID))
	if err != nil || manifest.SessionID != paneID {
		return errors.New("controlled worker is unavailable")
	}
	state, err := server.workerState(manifest)
	if err != nil || state != "ready" {
		return errors.New("controlled worker identity changed")
	}
	connection, err := net.DialTimeout("unix", manifest.SocketPath, 5*time.Second)
	if err != nil {
		return errors.New("controlled worker is unreachable")
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(10 * time.Second))
	hello, err := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{Version: workerProtocolVersion,
		SessionID: paneID, WorkerToken: manifest.Token, GuardedInput: true,
		GuardedOperationID: operationID, GuardedAgentPID: pid, GuardedProcessStart: start,
		GuardedText: text})
	if err != nil {
		return errors.New("guarded input is invalid")
	}
	if err := protocol.NewWriter(connection).Write(hello); err != nil {
		return errors.New("guarded input outcome is unknown")
	}
	response, err := protocol.ReadFrame(connection)
	if err != nil || response.Type != protocol.Status {
		return errors.New("guarded input outcome is unknown")
	}
	var status protocol.StatusPayload
	if protocol.DecodeJSON(response, &status) != nil || status.WorkerPID != manifest.WorkerPID {
		return errors.New("guarded input acknowledgement is unverified")
	}
	if status.State != "accepted" {
		return errors.New("guarded input refused")
	}
	return nil
}
