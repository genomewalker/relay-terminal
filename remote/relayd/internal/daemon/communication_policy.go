package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// Imported once from the desktop's hashed credential store. Subsequent pause
// changes belong to this daemon; a later desktop snapshot cannot overwrite them.
type communicationCaller struct {
	ID        string  `json:"id"`
	Label     string  `json:"label"`
	Thread    *string `json:"thread,omitempty"`
	TokenHash string  `json:"tokenHash"`
	Paused    bool    `json:"paused"`
}
type communicationPolicy struct {
	Callers      []communicationCaller `json:"callers"`
	LegacyPaused bool                  `json:"legacyPaused"`
}

func communicationPolicyPath(root string) string { return filepath.Join(root, "caller-policy.json") }

func communicationValidatePolicy(p communicationPolicy) error {
	if len(p.Callers) > 128 {
		return errors.New("caller policy exceeds limit")
	}
	ids, hashes := map[string]bool{}, map[string]bool{}
	for _, c := range p.Callers {
		id := strings.ToLower(c.ID)
		hash, err := hex.DecodeString(c.TokenHash)
		if !validSessionID.MatchString(id) || c.Label == "" || len(c.Label) > 120 ||
			(c.Thread != nil && len(*c.Thread) > 100) || err != nil || len(hash) != 32 ||
			c.TokenHash != strings.ToLower(c.TokenHash) || ids[id] || hashes[c.TokenHash] {
			return errors.New("invalid caller policy")
		}
		ids[id], hashes[c.TokenHash] = true, true
	}
	return nil
}

func communicationAuthorize(root string, r CommunicationRequest) (string, error) {
	// Server routes are configured only through owner-authenticated host RPC/CLI.
	// A provider credential never grants transport administration.
	if strings.HasPrefix(r.Operation, "route_") && (r.ClientToken != "" || r.ActorPaneID != "") {
		return "", errors.New("owner administration required")
	}
	mutation := r.Operation == "send" || r.Operation == "attest" || r.Operation == "sign" || r.Operation == "link" || r.Operation == "unlink" || r.Operation == "group_set" || r.Operation == "group_retire" || r.Operation == "group_send" || r.Operation == "route_set" || r.Operation == "route_retire" || r.Operation == "route_identity_create" || r.Operation == "route_binding_set"
	mutation = mutation || r.Operation == "route_identity_rotate"
	mutation = mutation || r.Operation == "route_link_set" || r.Operation == "route_link_retire" || r.Operation == "remote_receive" || r.Operation == "remote_send"
	mutation = mutation || r.Operation == "assistant_send" || r.Operation == "question_bind" || r.Operation == "question_unbind" || r.Operation == "question_notices" || r.Operation == "question_notice_send" || r.Operation == "question_notice_ack"
	if r.ActorPaneID != "" && (!validSessionID.MatchString(strings.ToLower(r.ActorPaneID)) ||
		(mutation && !strings.EqualFold(r.SourcePaneID, r.ActorPaneID))) {
		return "", errors.New("sender must be this client's own pane")
	}
	// Provider clients must use a registered credential for mutations. Owner
	// administration uses the authenticated host transport, never a provider token.
	if mutation && r.ActorPaneID != "" && r.ClientToken == "" {
		return "", errors.New("registered caller credential required")
	}
	var policy communicationPolicy
	if err := communicationRead(communicationPolicyPath(root), &policy); err != nil {
		if errors.Is(err, os.ErrNotExist) && !mutation && r.ClientToken == "" {
			return "legacy-unattributed", nil
		}
		return "", errors.New("daemon caller policy unavailable")
	}
	if err := communicationValidatePolicy(policy); err != nil {
		return "", err
	}
	if r.ClientToken == "" {
		if mutation && policy.LegacyPaused {
			return "", errors.New("caller is paused")
		}
		return "legacy-unattributed", nil
	}
	if len(r.ClientToken) > 200 {
		return "", errors.New("invalid caller credential")
	}
	hash := sha256.Sum256([]byte(r.ClientToken))
	for _, c := range policy.Callers {
		if c.TokenHash == hex.EncodeToString(hash[:]) {
			if mutation && c.Paused {
				return "", errors.New("caller is paused")
			}
			return strings.ToLower(c.ID), nil
		}
	}
	return "", errors.New("unknown caller credential")
}

// Called only while holding the private communication root's exclusive lock.
func communicationPolicyAdmin(root string, r CommunicationRequest) (map[string]any, error) {
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return nil, errors.New("owner administration required")
	}
	// The Relay assistant's ID is reserved: it is never imported or
	// registered as a generic caller (its authority is the app's signing key).
	if r.Policy != nil {
		for _, c := range r.Policy.Callers {
			if strings.EqualFold(c.ID, communicationAssistantCallerID) {
				return nil, errors.New("the relay-assistant identity is reserved and cannot be registered as a caller")
			}
		}
	}
	path := communicationPolicyPath(root)
	var policy communicationPolicy
	err := communicationRead(path, &policy)
	if r.Operation == "caller_policy_import" {
		if err == nil {
			return map[string]any{"status": "already_owned", "authority": "relayd"}, nil
		}
		if !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
		if r.Policy == nil {
			return nil, errors.New("caller policy required")
		}
		if err := communicationValidatePolicy(*r.Policy); err != nil {
			return nil, err
		}
		if err := communicationAtomic(path, r.Policy); err != nil {
			return nil, err
		}
		return map[string]any{"status": "imported", "authority": "relayd"}, nil
	}
	if err != nil {
		return nil, err
	}
	if err := communicationValidatePolicy(policy); err != nil {
		return nil, err
	}
	switch r.Operation {
	case "caller_register":
		if r.Policy == nil || len(r.Policy.Callers) != 1 {
			return nil, errors.New("one caller required")
		}
		caller := r.Policy.Callers[0]
		for _, saved := range policy.Callers {
			if strings.EqualFold(saved.ID, caller.ID) {
				if saved.TokenHash != caller.TokenHash {
					return nil, errors.New("caller identity conflict")
				}
				return map[string]any{"status": "already_registered", "authority": "relayd"}, nil
			}
		}
		policy.Callers = append(policy.Callers, caller)
		if err := communicationValidatePolicy(policy); err != nil {
			return nil, err
		}
		if err := communicationAtomic(path, policy); err != nil {
			return nil, err
		}
		return map[string]any{"status": "registered", "authority": "relayd"}, nil
	case "caller_set_paused":
		if r.Paused == nil {
			return nil, errors.New("pause value required")
		}
		found := r.CallerID == "legacy-unattributed"
		if found {
			policy.LegacyPaused = *r.Paused
		}
		for i := range policy.Callers {
			if strings.EqualFold(policy.Callers[i].ID, r.CallerID) {
				policy.Callers[i].Paused, found = *r.Paused, true
			}
		}
		if !found {
			return nil, errors.New("unknown caller")
		}
		if err := communicationAtomic(path, policy); err != nil {
			return nil, err
		}
		nodeID, _ := currentNodeIdentity()
		if err := communicationEvent(root, nodeID, "caller_pause_changed", []map[string]string{{"from": "caller:" + strings.ToLower(r.CallerID), "to": map[bool]string{true: "paused", false: "active"}[*r.Paused], "kind": "authorization"}}); err != nil {
			return nil, err
		}
		return map[string]any{"status": "applied", "authority": "relayd"}, nil
	case "caller_list":
		callers := []map[string]any{{"caller_id": "legacy-unattributed", "label": "Shared installation credential", "paused": policy.LegacyPaused}}
		for _, c := range policy.Callers {
			callers = append(callers, map[string]any{"caller_id": strings.ToLower(c.ID), "label": c.Label, "thread": c.Thread, "paused": c.Paused})
		}
		return map[string]any{"callers": callers, "authority": "relayd"}, nil
	default:
		return nil, errors.New("unknown caller policy operation")
	}
}
