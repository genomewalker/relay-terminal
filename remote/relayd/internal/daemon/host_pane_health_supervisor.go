package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// The controller runs in Go (host_pane_health_controller.go) and probes panes
// natively (host_pane_health_maintenance.go, a port of the canonical
// agent_maintenance.py kept beside it as the test oracle). The host
// supervisor supplies code, never a model response.

const hostPaneHealthCapability = "host_pane_health_controller_v1"

type hostPaneHealthControllerRequest struct {
	Version      int             `json:"v"`
	Operation    string          `json:"operation"`
	OperationID  string          `json:"operation_id"`
	Action       string          `json:"action"`
	HostID       string          `json:"host_id,omitempty"`
	OwnerID      string          `json:"owner_id,omitempty"`
	Enabled      *bool           `json:"enabled,omitempty"`
	HaikuEnabled *bool           `json:"haiku_enabled,omitempty"`
	Panes        []string        `json:"panes,omitempty"`
	Generation   *uint64         `json:"generation,omitempty"`
	Facts        json.RawMessage `json:"facts,omitempty"`
	ActionID     string          `json:"action_id,omitempty"`
	Result       json.RawMessage `json:"result,omitempty"`
}

func validHostPaneHealthControllerRequest(data []byte) (hostPaneHealthControllerRequest, error) {
	var request hostPaneHealthControllerRequest
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if len(data) > 262144 || !rotationSourceJSONUnambiguous(data) || decoder.Decode(&request) != nil ||
		request.Version != 1 || request.Operation != "pane_health_controller" || !validPromptEditorID(request.OperationID) {
		return request, errors.New("invalid host health controller request")
	}
	if request.Action != "desktop_facts" && (request.Generation != nil || len(request.Facts) != 0) ||
		request.Action != "complete_action" && (request.ActionID != "" || len(request.Result) != 0) {
		return request, errors.New("unexpected host health action fields")
	}
	switch request.Action {
	case "status", "check":
		if request.HostID != "" || request.OwnerID != "" || request.Enabled != nil || request.HaikuEnabled != nil || request.Panes != nil {
			return request, errors.New("invalid host health controller read/check")
		}
	case "configure":
		pane := regexp.MustCompile(`^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$`)
		if !regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,128}$`).MatchString(request.HostID) || !pane.MatchString(request.OwnerID) ||
			request.Enabled == nil || request.HaikuEnabled == nil || len(request.Panes) < 1 || len(request.Panes) > 128 {
			return request, errors.New("invalid host health controller configuration")
		}
		seen := map[string]bool{}
		for _, id := range request.Panes {
			if !pane.MatchString(id) || seen[id] {
				return request, errors.New("invalid or duplicate host health pane")
			}
			seen[id] = true
		}
	case "desktop_facts", "complete_action":
		if !regexp.MustCompile(`^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$`).MatchString(request.OwnerID) ||
			request.HostID != "" || request.Enabled != nil || request.HaikuEnabled != nil || request.Panes != nil {
			return request, errors.New("invalid scoped native health result")
		}
		if request.Action == "desktop_facts" {
			var facts []json.RawMessage
			if request.Generation == nil || json.Unmarshal(request.Facts, &facts) != nil || len(facts) < 1 || len(facts) > 64 {
				return request, errors.New("invalid desktop native facts")
			}
		} else if !validPromptEditorID(request.ActionID) || len(request.Result) == 0 || len(request.Result) > 16384 || !json.Valid(request.Result) {
			return request, errors.New("invalid native health action receipt")
		}
	default:
		return request, errors.New("unsupported host health controller action")
	}
	return request, nil
}

// The node helper forwards this domain to the durable supervisor. It does not
// own a timer or stop monitoring when its GUI/SSH stream disconnects.
func NodeHostAccountsHandler(socket string) func(context.Context, []byte) ([]byte, error) {
	return func(ctx context.Context, data []byte) ([]byte, error) {
		var envelope struct {
			RequestID string `json:"request_id"`
			Operation string `json:"operation"`
			Forward   *struct {
				Request json.RawMessage `json:"request"`
			} `json:"host_accounts"`
		}
		if json.Unmarshal(data, &envelope) != nil || envelope.Forward == nil {
			return HandleNodeHostAccountsRequest(ctx, data)
		}
		var operation struct {
			Operation string `json:"operation"`
		}
		if json.Unmarshal(envelope.Forward.Request, &operation) != nil || operation.Operation != "pane_health_controller" {
			return HandleNodeHostAccountsRequest(ctx, data)
		}
		decoder := json.NewDecoder(bytes.NewReader(data))
		decoder.DisallowUnknownFields()
		if len(data) > 262144 || !rotationSourceJSONUnambiguous(data) || decoder.Decode(&envelope) != nil ||
			!validSessionID.MatchString(envelope.RequestID) || envelope.Operation != "host_accounts" {
			return nil, errors.New("invalid host health controller envelope")
		}
		if _, err := validHostPaneHealthControllerRequest(envelope.Forward.Request); err != nil {
			return nil, err
		}
		result, err := hostPaneHealthControllerRPC(ctx, socket, envelope.Forward.Request)
		response := map[string]any{"request_id": envelope.RequestID, "result": result}
		if err != nil {
			response["error"] = err.Error()
		}
		return json.Marshal(response)
	}
}

func hostPaneHealthControllerRPC(ctx context.Context, socket string, data []byte) (json.RawMessage, error) {
	dialer := net.Dialer{Timeout: 3 * time.Second}
	connection, err := dialer.DialContext(ctx, "unix", socket)
	if err != nil {
		return nil, errors.New("host health supervisor unavailable")
	}
	defer connection.Close()
	stopCancellation := context.AfterFunc(ctx, func() { _ = connection.Close() })
	defer stopCancellation()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := RequirePeerUID(connection, os.Getuid()); err != nil {
		return nil, err
	}
	deadline := time.Now().Add(30 * time.Second)
	if at, ok := ctx.Deadline(); ok && at.Before(deadline) {
		deadline = at
	}
	_ = connection.SetDeadline(deadline)
	writer := protocol.NewWriter(connection)
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: workerProtocolVersion, SessionID: "host-health-controller", Probe: true, HostHealthController: true,
	})
	if writer.Write(hello) != nil {
		return nil, errors.New("host health handshake unavailable")
	}
	ready, err := protocol.ReadFrame(connection)
	var status protocol.StatusPayload
	if err != nil || ready.Type != protocol.Status || protocol.DecodeJSON(ready, &status) != nil ||
		status.State != "ready" || !containsHostPaneHealthCapability(status.Capabilities) {
		return nil, errors.New("the running supervisor does not support host pane health")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if writer.Write(protocol.Frame{Type: protocol.HostRequest, Payload: data}) != nil {
		return nil, errors.New("host health request outcome unavailable")
	}
	reply, err := protocol.ReadFrame(connection)
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if err != nil || reply.Type != protocol.HostResponse || len(reply.Payload) > 2<<20 || !json.Valid(reply.Payload) {
		return nil, errors.New("host health response unavailable; read its status before retrying")
	}
	return json.RawMessage(reply.Payload), nil
}

// RequestHostPaneHealthController is the same bounded native RPC used by the
// node bridge. It permits status/configuration/check operations, never input.
func RequestHostPaneHealthController(ctx context.Context, socket string, data []byte) (json.RawMessage, error) {
	if _, err := validHostPaneHealthControllerRequest(data); err != nil {
		return nil, err
	}
	return hostPaneHealthControllerRPC(ctx, socket, data)
}

func containsHostPaneHealthCapability(capabilities []string) bool {
	for _, capability := range capabilities {
		if capability == hostPaneHealthCapability {
			return true
		}
	}
	return false
}

type hostPaneHealthSupervisor struct {
	root, executable string
	wake             chan struct{}
	command          func(context.Context, string, any) (json.RawMessage, error)
	lifetime         context.Context
}

func newHostPaneHealthSupervisor(root, executable string) *hostPaneHealthSupervisor {
	s := &hostPaneHealthSupervisor{root: root, executable: executable, wake: make(chan struct{}, 1), lifetime: context.Background()}
	s.command = s.execute
	return s
}

func (s *hostPaneHealthSupervisor) notify() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

func (s *hostPaneHealthSupervisor) run(ctx context.Context) {
	var timer = time.NewTimer(0)
	defer timer.Stop()
	var deadline <-chan time.Time = timer.C
	for {
		select {
		case <-ctx.Done():
			return
		case <-s.wake:
		case <-deadline:
		}
		call, cancel := context.WithTimeout(ctx, 10*time.Minute)
		result, err := s.command(call, "tick", map[string]any{})
		cancel()
		if ctx.Err() != nil {
			return
		}
		seconds := 120
		var status struct {
			Next int `json:"next_check_seconds"`
		}
		if err == nil && json.Unmarshal(result, &status) == nil {
			seconds = status.Next
		}
		if seconds < 0 {
			deadline = nil
			continue
		}
		if seconds < 5 {
			seconds = 120
		}
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		timer.Reset(time.Duration(seconds) * time.Second)
		deadline = timer.C
	}
}

func (s *hostPaneHealthSupervisor) execute(ctx context.Context, operation string, request any) (json.RawMessage, error) {
	if err := os.MkdirAll(s.root, 0700); err != nil {
		return nil, errors.New("host health worker state unavailable")
	}
	if err := privateBindingObject(s.root, true); err != nil {
		return nil, errors.New("host health worker state is not private")
	}
	arguments, err := pyFromGo(request)
	if err != nil {
		return nil, errors.New("bounded host health request required")
	}
	var backend paneHealthBackend = paneHealthNoBackend{}
	switch operation {
	case "tick", "desktop_facts", "complete_action":
		// Probes run in Go; health validation and the Haiku journal run in
		// rotationtext, whose journal opens on first use.
		native := newPaneHealthNativeBackend(ctx, s.root, s.executable)
		defer native.Close()
		backend = native
	case "configure", "check", "status":
	default:
		return nil, errors.New("unsupported host health controller operation")
	}
	// The former adapter stopped when relayd (its parent) went away; the
	// in-process controller stops at the same checkpoints on cancellation.
	alive := func() bool { return ctx.Err() == nil && s.lifetime.Err() == nil }
	controller := runPaneHealthController(filepath.Join(s.root, "pane-health-controller"), backend, paneHealthTimeNow,
		alive, operation, arguments)
	output := pyCompact(controller)
	if len(output) > 2<<20 {
		return nil, errors.New("host health state unavailable")
	}
	var result map[string]json.RawMessage
	if json.Unmarshal(output, &result) != nil {
		return nil, errors.New("invalid host health state")
	}
	result["supervisor_pid"], _ = json.Marshal(os.Getpid())
	if start, err := processStartTime(os.Getpid()); err == nil {
		result["supervisor_start_time"], _ = json.Marshal(start)
	}
	return json.Marshal(result)
}

func (s *hostPaneHealthSupervisor) serve(connection net.Conn) {
	// A client disconnect never owns the actor's lifetime. Server shutdown
	// does cancel in-flight adapter processes and incomplete RPC reads.
	stopCancellation := context.AfterFunc(s.lifetime, func() { _ = connection.Close() })
	defer stopCancellation()
	_ = connection.SetDeadline(time.Now().Add(30 * time.Second))
	writer := protocol.NewWriter(connection)
	ready, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "ready", SupervisorPID: os.Getpid(),
		Capabilities: []string{hostPaneHealthCapability}})
	if writer.Write(ready) != nil {
		return
	}
	frame, err := protocol.ReadFrame(connection)
	if err != nil || frame.Type != protocol.HostRequest {
		return
	}
	request, err := validHostPaneHealthControllerRequest(frame.Payload)
	if err != nil {
		return
	}
	arguments := map[string]any{"operation_id": request.OperationID}
	if request.Action == "configure" {
		arguments = map[string]any{"v": 1, "operation": "configure", "operation_id": request.OperationID, "host_id": request.HostID,
			"owner_id": request.OwnerID, "enabled": *request.Enabled, "haiku_enabled": *request.HaikuEnabled, "panes": request.Panes}
	}
	if request.Action == "desktop_facts" {
		arguments = map[string]any{"operation_id": request.OperationID, "owner_id": request.OwnerID,
			"generation": *request.Generation, "facts": request.Facts}
	}
	if request.Action == "complete_action" {
		arguments = map[string]any{"operation_id": request.OperationID, "owner_id": request.OwnerID,
			"action_id": request.ActionID, "result": request.Result}
	}
	ctx, cancel := context.WithTimeout(s.lifetime, 25*time.Second)
	defer cancel()
	result, err := s.command(ctx, request.Action, arguments)
	if err != nil {
		result, _ = json.Marshal(map[string]any{"v": 1, "status": "failed", "code": "host_health_state_unavailable"})
	}
	var wake struct {
		Wake bool `json:"wake_controller"`
	}
	if err == nil && json.Unmarshal(result, &wake) == nil && wake.Wake {
		s.notify()
	}
	_ = writer.Write(protocol.Frame{Type: protocol.HostResponse, Payload: result})
}
