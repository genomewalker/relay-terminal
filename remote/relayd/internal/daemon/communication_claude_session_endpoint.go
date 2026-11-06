package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/relay-terminal/relayd/internal/nativemsg"
)

// communicationClaudeSessionEndpoint registers a Claude desktop session as a
// communication endpoint in the pane namespace. Its ID is the session's own
// UUID, so pane links, remote links, receipts and conversation pins work
// unchanged; delivery and sender proof use the session's registry record
// instead of a pane worker. Typed (Work) links never admit it: their endpoint
// kinds stay pane and work.
type communicationClaudeSessionEndpoint struct {
	Version     int       `json:"version"`
	ID          string    `json:"id"`
	AccountRoot string    `json:"account_root"`
	SessionID   string    `json:"session_id"`
	Retired     bool      `json:"retired"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
}

func (e communicationClaudeSessionEndpoint) target() nativemsg.ClaudeSessionTarget {
	return nativemsg.ClaudeSessionTarget{AccountRoot: e.AccountRoot, SessionID: e.SessionID}
}

func validClaudeSessionEndpoint(e communicationClaudeSessionEndpoint, id string) bool {
	return e.Version == 1 && e.ID == id && strings.ToLower(e.SessionID) == id && validSessionID.MatchString(id) &&
		e.target().Valid() && !e.CreatedAt.IsZero() && !e.UpdatedAt.Before(e.CreatedAt)
}

func claudeSessionEndpointPath(root, id string) string {
	return filepath.Join(root, "claude-session-endpoint-"+id+".json")
}

// readClaudeSessionEndpoint returns the active registration for id, or an
// os.ErrNotExist error when there is none.
func readClaudeSessionEndpoint(root, id string) (communicationClaudeSessionEndpoint, error) {
	var e communicationClaudeSessionEndpoint
	id = strings.ToLower(id)
	if !validSessionID.MatchString(id) {
		return e, os.ErrNotExist
	}
	if err := communicationRead(claudeSessionEndpointPath(root, id), &e); err != nil {
		return communicationClaudeSessionEndpoint{}, err
	}
	if !validClaudeSessionEndpoint(e, id) {
		return communicationClaudeSessionEndpoint{}, errors.New("invalid Claude session endpoint record")
	}
	if e.Retired {
		return communicationClaudeSessionEndpoint{}, os.ErrNotExist
	}
	return e, nil
}

// communicationPaneExists reports whether a pane worker publishes id.
var communicationPaneExists = func(id string) bool {
	server := NewServer()
	for _, path := range []string{server.manifestPath(id), filepath.Join(server.stateDir, id+".json")} {
		if _, err := os.Lstat(path); err == nil || !errors.Is(err, os.ErrNotExist) {
			return true
		}
	}
	return false
}

// communicationNativeTarget is the native target an endpoint ID names: a
// registered Claude desktop session, else the pane. An ID that is both is
// refused rather than chosen.
func communicationNativeTarget(root, id string) (nativemsg.Target, bool, error) {
	pane := nativemsg.Target{Kind: "pane", PaneID: id}
	e, err := readClaudeSessionEndpoint(root, id)
	if errors.Is(err, os.ErrNotExist) {
		return pane, false, nil
	}
	if err != nil {
		return nativemsg.Target{}, false, err
	}
	if communicationPaneExists(strings.ToLower(id)) {
		return nativemsg.Target{}, false, errors.New("endpoint ID names both a pane and a Claude session")
	}
	target := e.target()
	return nativemsg.Target{Kind: "claude_session", Claude: &target}, true, nil
}

// communicationClaudeSessionRun is the native adapter for a registered Claude
// session; tests replace it.
var communicationClaudeSessionRun = func(ctx context.Context, host nativemsg.Host, target nativemsg.Target, request []byte) map[string]any {
	result, err := nativemsg.RunTarget(ctx, host, target, request, nil)
	if err != nil {
		return map[string]any{"status": "unavailable", "error": err.Error(), "replay_permitted": false}
	}
	return result
}

// communicationClaudeSessionOperation registers, retires or lists Claude
// desktop session endpoints. It runs as an owner route operation: under the
// communication lock, without a provider credential or caller pane.
func communicationClaudeSessionOperation(root string, r CommunicationRequest, now func() time.Time) (map[string]any, error) {
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return nil, errors.New("owner administration required")
	}
	if r.Operation == "route_claude_session_list" {
		paths, err := filepath.Glob(filepath.Join(root, "claude-session-endpoint-*.json"))
		if err != nil {
			return nil, err
		}
		endpoints := []communicationClaudeSessionEndpoint{}
		for _, path := range paths {
			id := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(path), "claude-session-endpoint-"), ".json")
			if e, err := readClaudeSessionEndpoint(root, id); err == nil {
				endpoints = append(endpoints, e)
			}
		}
		return map[string]any{"claude_sessions": endpoints, "authority": "relayd"}, nil
	}
	id := strings.ToLower(r.TargetSessionID)
	if !validSessionID.MatchString(id) {
		return nil, errors.New("valid Claude session ID required")
	}
	path := claudeSessionEndpointPath(root, id)
	switch r.Operation {
	case "route_claude_session_retire":
		e, err := readClaudeSessionEndpoint(root, id)
		if err != nil {
			return nil, err
		}
		e.Retired, e.UpdatedAt = true, now().UTC()
		if err := communicationAtomic(path, e); err != nil {
			return nil, err
		}
		return map[string]any{"claude_session": e, "status": "retired", "authority": "relayd"}, nil
	case "route_claude_session_set":
	default:
		return nil, errors.New("unsupported Claude session operation")
	}
	target := nativemsg.ClaudeSessionTarget{AccountRoot: r.ClaudeAccountRoot, SessionID: id}
	if !target.Valid() {
		return nil, errors.New("absolute Claude account directory and session ID required")
	}
	if communicationPaneExists(id) {
		return nil, errors.New("a pane already uses this ID")
	}
	if existing, err := readClaudeSessionEndpoint(root, id); err == nil {
		if existing.AccountRoot != target.AccountRoot {
			return nil, errors.New("Claude session already registered under another account directory")
		}
		return map[string]any{"claude_session": existing, "status": "unchanged", "authority": "relayd"}, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	// Register only a session that is live and publishes a usable inbox now.
	request, _ := json.Marshal(map[string]any{"operation": "discover"})
	ctx, cancel := context.WithTimeout(context.Background(), communicationAdapterTimeout)
	defer cancel()
	found := communicationClaudeSessionRun(ctx, communicationNativeHost(), nativemsg.Target{Kind: "claude_session", Claude: &target}, request)
	endpoint, ok := found["endpoint"].(map[string]any)
	if !ok || endpoint["sessionID"] != id || endpoint["transport"] != "native_peer_socket" {
		reason, _ := found["error"].(string)
		return nil, errors.New("Claude session is not live with a usable inbox: " + communicationBoundedString(reason, 200))
	}
	stamp := now().UTC()
	e := communicationClaudeSessionEndpoint{Version: 1, ID: id, AccountRoot: target.AccountRoot, SessionID: id, CreatedAt: stamp, UpdatedAt: stamp}
	if err := communicationAtomic(path, e); err != nil {
		return nil, err
	}
	return map[string]any{"claude_session": e, "status": "registered", "authority": "relayd"}, nil
}

// ReadCommunicationActorOrClaudeSession observes the caller's pane, else the
// registered Claude desktop session that owns it. A desktop session without
// a registration has no actor and keeps the unattributed path.
func ReadCommunicationActorOrClaudeSession(clientPID int) (CommunicationActor, error) {
	return readCommunicationActorOrClaudeSession(communicationRoot(), clientPID, ReadCommunicationActor, ReadClaudeSessionActor)
}

func readCommunicationActorOrClaudeSession(root string, clientPID int, readPane func(int) (CommunicationActor, error), readSession func(int) (ClaudeSessionActor, error)) (CommunicationActor, error) {
	actor, paneErr := readPane(clientPID)
	if paneErr == nil {
		return actor, nil
	}
	session, err := readSession(clientPID)
	if err != nil {
		return CommunicationActor{}, paneErr
	}
	id := strings.ToLower(session.SessionID)
	e, err := readClaudeSessionEndpoint(root, id)
	if err != nil || e.AccountRoot != session.AccountRoot {
		return CommunicationActor{}, paneErr
	}
	if communicationPaneExists(id) {
		return CommunicationActor{}, errors.New("endpoint ID names both a pane and a Claude session")
	}
	return CommunicationActor{Version: 1, PaneID: id, ClientPID: session.ClientPID, ClientStart: session.ClientStart, Source: claudeDesktopSessionSource}, nil
}
