package daemon

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

const workspaceStateSchema = 1

type workspaceLease struct {
	clientID string
	expires  time.Time
}

type workspaceStateRecord struct {
	Schema      int             `json:"schema"`
	WorkspaceID string          `json:"workspace_id"`
	Revision    uint64          `json:"revision"`
	UpdatedAt   time.Time       `json:"updated_at"`
	State       json.RawMessage `json:"state"`
}

type workspaceStateRequest struct {
	Operation string          `json:"operation"`
	ClientID  string          `json:"client_id"`
	State     json.RawMessage `json:"state,omitempty"`
}

type workspaceStateResponse struct {
	OK          bool            `json:"ok"`
	Message     string          `json:"message,omitempty"`
	Schema      int             `json:"schema"`
	WorkspaceID string          `json:"workspace_id"`
	Revision    uint64          `json:"revision,omitempty"`
	State       json.RawMessage `json:"state,omitempty"`
}

func (server *Server) workspaceStateDirectory() string {
	return filepath.Join(filepath.Dir(server.stateDir), "workspaces")
}

func (server *Server) workspaceStatePath(workspaceID string) string {
	return filepath.Join(server.workspaceStateDirectory(), workspaceID+".json")
}

func (server *Server) handleWorkspaceState(workspaceID string, payload []byte) protocol.Frame {
	response := workspaceStateResponse{Schema: workspaceStateSchema, WorkspaceID: workspaceID}
	var request workspaceStateRequest
	if json.Unmarshal(payload, &request) != nil || request.ClientID == "" {
		response.Message = "invalid workspace state request"
		return workspaceResponseFrame(response)
	}
	server.mu.Lock()
	defer server.mu.Unlock()
	if server.workspaceLeases == nil {
		server.workspaceLeases = make(map[string]workspaceLease)
	}
	now := time.Now().UTC()
	switch request.Operation {
	case "get":
		record, err := server.loadWorkspaceState(workspaceID)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				response.OK = true
				return workspaceResponseFrame(response)
			}
			response.Message = err.Error()
			return workspaceResponseFrame(response)
		}
		response.OK, response.Revision, response.State = true, record.Revision, record.State
	case "put":
		lease := server.workspaceLeases[workspaceID]
		if lease.clientID != "" && lease.clientID != request.ClientID && lease.expires.After(now) {
			response.Message = "workspace is controlled by another client"
			return workspaceResponseFrame(response)
		}
		if len(request.State) == 0 || len(request.State) > 1<<20 || !json.Valid(request.State) {
			response.Message = "invalid or oversized workspace state"
			return workspaceResponseFrame(response)
		}
		revision := uint64(1)
		if current, err := server.loadWorkspaceState(workspaceID); err == nil {
			if jsonEqual(current.State, request.State) {
				server.workspaceLeases[workspaceID] = workspaceLease{
					clientID: request.ClientID, expires: now.Add(15 * time.Second),
				}
				response.OK, response.Revision, response.State = true, current.Revision, current.State
				return workspaceResponseFrame(response)
			}
			revision = current.Revision + 1
		}
		record := workspaceStateRecord{
			Schema: workspaceStateSchema, WorkspaceID: workspaceID, Revision: revision,
			UpdatedAt: now, State: append(json.RawMessage(nil), request.State...),
		}
		if err := server.storeWorkspaceState(record); err != nil {
			response.Message = err.Error()
			return workspaceResponseFrame(response)
		}
		server.workspaceLeases[workspaceID] = workspaceLease{clientID: request.ClientID, expires: now.Add(15 * time.Second)}
		response.OK, response.Revision, response.State = true, revision, record.State
	case "release":
		lease := server.workspaceLeases[workspaceID]
		if lease.clientID == request.ClientID {
			delete(server.workspaceLeases, workspaceID)
		}
		response.OK = true
	default:
		response.Message = "unsupported workspace state operation"
	}
	return workspaceResponseFrame(response)
}

func jsonEqual(first, second json.RawMessage) bool {
	var left any
	var right any
	return json.Unmarshal(first, &left) == nil && json.Unmarshal(second, &right) == nil &&
		reflect.DeepEqual(left, right)
}

func workspaceResponseFrame(response workspaceStateResponse) protocol.Frame {
	payload, _ := json.Marshal(response)
	return protocol.Frame{Type: protocol.WorkspaceState, Payload: payload}
}

func (server *Server) loadWorkspaceState(workspaceID string) (workspaceStateRecord, error) {
	data, err := os.ReadFile(server.workspaceStatePath(workspaceID))
	if err != nil {
		return workspaceStateRecord{}, err
	}
	var record workspaceStateRecord
	if json.Unmarshal(data, &record) != nil || record.Schema != workspaceStateSchema || record.WorkspaceID != workspaceID {
		return workspaceStateRecord{}, errors.New("invalid workspace state")
	}
	return record, nil
}

func (server *Server) storeWorkspaceState(record workspaceStateRecord) error {
	directory := server.workspaceStateDirectory()
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	data, err := json.Marshal(record)
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(directory, ".workspace-*.json")
	if err != nil {
		return err
	}
	path := temporary.Name()
	remove := true
	defer func() {
		_ = temporary.Close()
		if remove {
			_ = os.Remove(path)
		}
	}()
	if err := temporary.Chmod(0o600); err != nil {
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		return err
	}
	if err := temporary.Sync(); err != nil {
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(path, server.workspaceStatePath(record.WorkspaceID)); err != nil {
		return err
	}
	remove = false
	return nil
}
