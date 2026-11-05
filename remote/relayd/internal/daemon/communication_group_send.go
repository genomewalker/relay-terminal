package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type communicationGroupNative struct {
	observe func(string) communicationMember
	send    func(string, map[string]any) (map[string]any, error)
}
type communicationPinnedConversation struct {
	Provider  string `json:"provider"`
	SessionID string `json:"session_id"`
}
type communicationFanoutTarget struct {
	Fingerprint    string                          `json:"fingerprint"`
	PaneID         string                          `json:"pane_id"`
	MessageID      string                          `json:"message_id"`
	Source         communicationPinnedConversation `json:"source_binding"`
	Target         communicationPinnedConversation `json:"target_binding"`
	PreflightError string                          `json:"preflight_error,omitempty"`
	Result         map[string]any                  `json:"result"`
}
type communicationFanoutReceipt struct {
	Version            int                         `json:"version"`
	NodeID             string                      `json:"node_id"`
	GroupID            string                      `json:"group_id"`
	GroupRevision      uint64                      `json:"group_revision"`
	MessageID          string                      `json:"message_id"`
	SourcePaneID       string                      `json:"source_pane_id"`
	SubmittingClientID string                      `json:"submitting_client_id"`
	Fingerprint        string                      `json:"fingerprint"`
	CreatedAt          time.Time                   `json:"created_at"`
	DispatchFinished   bool                        `json:"dispatch_finished"`
	Targets            []communicationFanoutTarget `json:"recipients"`
}

func currentCommunicationNodeID() string { node, _ := currentNodeIdentity(); return node }
func communicationFanoutPath(root, id string) string {
	return filepath.Join(root, "fanout-"+id+".json")
}

func validCommunicationFanout(r communicationFanoutReceipt, node string) bool {
	if r.Version != 1 || r.NodeID != node || r.GroupRevision == 0 ||
		!validSessionID.MatchString(r.GroupID) || r.GroupID != strings.ToLower(r.GroupID) ||
		!validSessionID.MatchString(r.MessageID) || r.MessageID != strings.ToLower(r.MessageID) ||
		!validSessionID.MatchString(r.SourcePaneID) || r.SourcePaneID != strings.ToLower(r.SourcePaneID) ||
		!validSessionID.MatchString(r.SubmittingClientID) ||
		len(r.Targets) < 1 || len(r.Targets) >= communicationMaxGroupMembers {
		return false
	}
	fp, err := hex.DecodeString(r.Fingerprint)
	if err != nil || len(fp) != 32 {
		return false
	}
	seen := map[string]bool{}
	for _, target := range r.Targets {
		fp, err := hex.DecodeString(target.Fingerprint)
		if err != nil || len(fp) != 32 || target.Result == nil ||
			!validSessionID.MatchString(target.PaneID) || target.PaneID == r.SourcePaneID ||
			seen[target.PaneID] || target.MessageID != communicationFanoutChildID(r.GroupID, r.MessageID, r.SourcePaneID, target.PaneID) {
			return false
		}
		seen[target.PaneID] = true
	}
	return true
}
func communicationRefreshFanout(root, node string, r communicationFanoutReceipt) (communicationFanoutReceipt, error) {
	if !validCommunicationFanout(r, node) {
		return r, errors.New("invalid stored group delivery receipt")
	}
	for index, target := range r.Targets {
		var child communicationReceipt
		err := communicationRead(filepath.Join(root, "message-"+target.MessageID+".json"), &child)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return r, err
		}
		if child.Fingerprint != target.Fingerprint || child.Result == nil {
			return r, errors.New("recipient receipt fingerprint mismatch")
		}
		result := map[string]any{}
		for key, value := range child.Result {
			result[key] = value
		}
		result["replay_permitted"] = false
		result["message_id"] = target.MessageID
		result["source_pane_id"] = r.SourcePaneID
		result["pane_id"] = target.PaneID
		result["authority"] = "relayd"
		r.Targets[index].Result = result
	}
	return r, nil
}
func communicationFanoutResult(r communicationFanoutReceipt) map[string]any {
	return map[string]any{"receipt": r, "authority": "relayd", "desktop_required": false, "replay_permitted": false}
}
func communicationFanoutLocked(root string, fn func() error) error {
	if err := os.MkdirAll(root, 0700); err != nil {
		return err
	}
	if err := privateBindingObject(root, true); err != nil {
		return err
	}
	f, err := OpenPrivateFile(filepath.Join(root, "lock"), os.O_CREATE|os.O_RDWR)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := communicationLockExclusive(f); err != nil {
		return err
	}
	defer communicationUnlock(f)
	return fn()
}
func communicationPin(member communicationMember) communicationPinnedConversation {
	return communicationPinnedConversation{Provider: member.Provider, SessionID: member.SessionID}
}
func communicationPinMatches(pin communicationPinnedConversation, live communicationMember) bool {
	return pin.SessionID != "" && pin.Provider != "" && live.Unavailable == "" && live.Endpoint != nil &&
		pin.Provider == live.Provider && pin.SessionID == live.SessionID
}
func communicationFanoutChildFingerprint(source, target, id, text string) string {
	body, _ := json.Marshal(struct{ Source, Target, Message, Text string }{source, target, id, text})
	hash := sha256.Sum256(body)
	return hex.EncodeToString(hash[:])
}
func communicationFanoutChildID(group, message, source, target string) string {
	hash := sha256.Sum256([]byte(group + "\n" + message + "\n" + source + "\n" + target))
	return hex.EncodeToString(hash[:])
}
func communicationNativeOutcome(native map[string]any, err error) map[string]any {
	result := map[string]any{"status": "outcome_unknown", "replay_permitted": false}
	if err != nil {
		result["error"] = communicationBoundedString(err.Error(), 2048)
		return result
	}
	for _, key := range []string{"status", "transport", "command_id", "provider_turn_id", "acknowledgement", "error", "reason",
		"held_expected", "recipient_mode", "sender_mode"} {
		if text, ok := native[key].(string); ok && len(text) <= 2048 && text != "" {
			result[key] = text
		}
	}
	if accepted, ok := native["accepted"].(bool); ok {
		result["accepted"] = accepted
	}
	return result
}
func communicationBoundedString(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

// A parent claim reserves every recipient before any native invocation.
// Retrying its ID returns that receipt, including unknown outcomes; it never
// resumes dispatch. Native I/O occurs outside the metadata flock. Caller pause,
// group revision and reviewed conversations are checked before each child claim.
func communicationGroupSend(root, node string, r CommunicationRequest, hooks communicationGroupNative) (map[string]any, error) {
	qualified, err := communicationUseQualifiedFanout(root, node, r)
	if err != nil {
		return nil, err
	}
	if qualified {
		return communicationQualifiedGroupSend(root, node, r, hooks)
	}
	return communicationLocalGroupSend(root, node, r, hooks)
}
func communicationLocalGroupSend(root, node string, r CommunicationRequest, hooks communicationGroupNative) (map[string]any, error) {
	r.GroupID, r.SourcePaneID, r.MessageID = strings.ToLower(r.GroupID), strings.ToLower(r.SourcePaneID), strings.ToLower(r.MessageID)
	if node == "" || !validSessionID.MatchString(r.GroupID) || !validSessionID.MatchString(r.SourcePaneID) ||
		!validSessionID.MatchString(r.MessageID) || len(r.Text) == 0 || len(r.Text) > 16384 || strings.TrimSpace(r.Text) == "" {
		return nil, errors.New("valid group, sender, message identity and 1-16384 bytes of text required")
	}
	body, _ := json.Marshal(struct {
		Group, Source, Message, Text string
		Revision                     uint64
	}{
		r.GroupID, r.SourcePaneID, r.MessageID, r.Text, r.ExpectedGroupRevision})
	hash := sha256.Sum256(body)
	fingerprint := hex.EncodeToString(hash[:])
	parentPath := communicationFanoutPath(root, r.MessageID)
	var parent communicationFanoutReceipt
	existing := false
	err := communicationFanoutLocked(root, func() error {
		identity, err := communicationAuthorize(root, r)
		if err != nil {
			return err
		}
		r.ClientID = identity
		if err := communicationRead(parentPath, &parent); err == nil {
			if !validCommunicationFanout(parent, node) || parent.GroupID != r.GroupID || parent.SourcePaneID != r.SourcePaneID || parent.MessageID != r.MessageID || parent.Fingerprint != fingerprint || parent.SubmittingClientID != identity {
				return errors.New("group message identity conflicts with an earlier request")
			}
			parent, err = communicationRefreshFanout(root, node, parent)
			if err != nil {
				return err
			}
			existing = true
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		var group communicationGroup
		if err := communicationRead(filepath.Join(root, "group-"+r.GroupID+".json"), &group); err != nil {
			return err
		}
		if !validCommunicationGroup(group, node) || group.ID != r.GroupID || group.Retired ||
			group.Revision != r.ExpectedGroupRevision || !containsCommunicationPane(group.Members, r.SourcePaneID) {
			return errors.New("group is retired, changed or does not contain the sender")
		}
		parent = communicationFanoutReceipt{Version: 1, NodeID: node, GroupID: r.GroupID, GroupRevision: group.Revision,
			MessageID: r.MessageID, SourcePaneID: r.SourcePaneID, SubmittingClientID: identity, Fingerprint: fingerprint, CreatedAt: time.Now().UTC()}
		for _, target := range group.Members {
			if target == r.SourcePaneID {
				continue
			}
			entry := communicationFanoutTarget{PaneID: target, MessageID: communicationFanoutChildID(r.GroupID, r.MessageID, r.SourcePaneID, target),
				Result: map[string]any{"status": "outcome_unknown", "replay_permitted": false}}
			entry.Fingerprint = communicationFanoutChildFingerprint(r.SourcePaneID, target, entry.MessageID, r.Text)
			id, _, err := communicationPair(r.SourcePaneID, target)
			var link communicationLink
			if err != nil || communicationRead(filepath.Join(root, "link-"+id+".json"), &link) != nil || link.NodeID != node {
				entry.PreflightError = "review the native communication pair before sending to this recipient"
			} else {
				for _, member := range link.Members {
					if member.PaneID == r.SourcePaneID {
						entry.Source = communicationPin(member)
					}
					if member.PaneID == target {
						entry.Target = communicationPin(member)
					}
				}
				if entry.Source.SessionID == "" || entry.Target.SessionID == "" || link.Transport == "unavailable" {
					entry.PreflightError = "reviewed pair has no verified native conversations"
				}
			}
			parent.Targets = append(parent.Targets, entry)
		}
		if err := communicationAtomic(parentPath, parent); err != nil {
			return err
		}
		return communicationEvent(root, node, "group_message_claimed", []map[string]string{{"from": r.GroupID, "to": r.MessageID, "kind": "group_message"}})
	})
	if err != nil {
		return nil, err
	}
	if existing {
		return communicationFanoutResult(parent), nil
	}
	for index, entry := range parent.Targets {
		var source, target communicationMember
		if entry.PreflightError == "" {
			source, target = hooks.observe(r.SourcePaneID), hooks.observe(entry.PaneID)
		}
		childPath := filepath.Join(root, "message-"+entry.MessageID+".json")
		childHash := entry.Fingerprint
		deliver := false
		err = communicationFanoutLocked(root, func() error {
			if err := communicationRead(parentPath, &parent); err != nil {
				return err
			}
			if !validCommunicationFanout(parent, node) {
				return errors.New("invalid stored group delivery receipt")
			}
			reason := entry.PreflightError
			identity, authErr := communicationAuthorize(root, r)
			if authErr != nil {
				reason = authErr.Error()
			} else if identity != parent.SubmittingClientID {
				reason = "submitting caller identity changed"
			}
			var group communicationGroup
			if readErr := communicationRead(filepath.Join(root, "group-"+r.GroupID+".json"), &group); readErr != nil ||
				!validCommunicationGroup(group, node) || group.ID != r.GroupID || group.Retired || group.Revision != parent.GroupRevision {
				reason = "group membership changed or was retired"
			}
			if reason == "" && (!communicationPinMatches(entry.Source, source) || !communicationPinMatches(entry.Target, target)) {
				reason = "reviewed native conversation changed or is unavailable"
			}
			var child communicationReceipt
			if readErr := communicationRead(childPath, &child); readErr == nil {
				if child.Fingerprint != childHash {
					return errors.New("recipient message identity conflict")
				}
				result := map[string]any{}
				for key, value := range child.Result {
					result[key] = value
				}
				result["replay_permitted"] = false
				parent.Targets[index].Result = result
				return communicationAtomic(parentPath, parent)
			} else if !errors.Is(readErr, os.ErrNotExist) {
				return readErr
			}
			result := map[string]any{"status": "outcome_unknown", "replay_permitted": false, "message_id": entry.MessageID,
				"source_pane_id": r.SourcePaneID, "pane_id": entry.PaneID, "group_id": r.GroupID, "group_message_id": r.MessageID,
				"submitting_client_id": parent.SubmittingClientID, "source_authentication": "claimed_pane_label", "authority": "relayd", "desktop_required": false}
			if reason != "" {
				result["status"] = "blocked"
				result["error"] = communicationBoundedString(reason, 2048)
			}
			child = communicationReceipt{Version: 1, Fingerprint: childHash, CreatedAt: time.Now().UTC(), Result: result}
			if err := communicationAtomic(childPath, child); err != nil {
				return err
			}
			parent.Targets[index].Result = result
			if err := communicationAtomic(parentPath, parent); err != nil {
				return err
			}
			if err := communicationEvent(root, node, "group_recipient_claimed", []map[string]string{{"from": r.MessageID, "to": entry.MessageID, "kind": "recipient"}}); err != nil {
				return err
			}
			deliver = reason == ""
			return nil
		})
		if err != nil {
			return communicationFanoutResult(parent), err
		}
		if !deliver {
			continue
		}
		packet := map[string]any{"operation": "send", "expected": target.Endpoint, "messageID": entry.MessageID,
			"targetPaneID": entry.PaneID, "text": r.Text, "submittingClientID": parent.SubmittingClientID,
			"source": map[string]any{"hostID": node, "paneID": r.SourcePaneID, "sessionID": source.SessionID}}
		native, sendErr := hooks.send(entry.PaneID, packet)
		outcome := communicationNativeOutcome(native, sendErr)
		err = communicationFanoutLocked(root, func() error {
			var child communicationReceipt
			if err := communicationRead(childPath, &child); err != nil {
				return err
			}
			for key, value := range outcome {
				child.Result[key] = value
			}
			if err := communicationAtomic(childPath, child); err != nil {
				return err
			}
			if err := communicationRead(parentPath, &parent); err != nil {
				return err
			}
			if !validCommunicationFanout(parent, node) {
				return errors.New("invalid stored group delivery receipt")
			}
			parent.Targets[index].Result = child.Result
			if err := communicationAtomic(parentPath, parent); err != nil {
				return err
			}
			return communicationEvent(root, node, "group_recipient_outcome", []map[string]string{{"from": entry.MessageID, "to": child.Result["status"].(string), "kind": "status"}})
		})
		if err != nil {
			return communicationFanoutResult(parent), err
		}
	}
	err = communicationFanoutLocked(root, func() error {
		if err := communicationRead(parentPath, &parent); err != nil {
			return err
		}
		parent.DispatchFinished = true
		return communicationAtomic(parentPath, parent)
	})
	return communicationFanoutResult(parent), err
}
