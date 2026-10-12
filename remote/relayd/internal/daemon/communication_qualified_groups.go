package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

type CommunicationGroupMember struct {
	NodeID string `json:"node_id"`
	PaneID string `json:"pane_id"`
}

func groupMemberKey(member CommunicationGroupMember) string {
	return member.NodeID + ":" + member.PaneID
}
func communicationGroupHasMember(group communicationGroup, node, pane string) bool {
	if group.Version == 1 {
		return node == group.NodeID && containsCommunicationPane(group.Members, pane)
	}
	for _, member := range group.MemberRefs {
		if member.NodeID == node && member.PaneID == pane {
			return true
		}
	}
	return false
}
func validQualifiedCommunicationGroup(group communicationGroup, node string) bool {
	if group.Version != 2 || group.NodeID != node || !canonicalRouteToken(node) || !canonicalRouteToken(group.ID) || !canonicalRouteToken(group.OwnerClientID) ||
		group.Revision == 0 || !validCommunicationGroupName(group.Name) || len(group.Members) != 0 || len(group.MemberRefs) < 2 || len(group.MemberRefs) > communicationMaxGroupMembers ||
		group.CreatedAt.IsZero() || group.UpdatedAt.Before(group.CreatedAt) {
		return false
	}
	previous := ""
	hasLocal := false
	for _, member := range group.MemberRefs {
		key := groupMemberKey(member)
		if !canonicalRouteToken(member.NodeID) || !canonicalRouteToken(member.PaneID) || key <= previous {
			return false
		}
		previous = key
		hasLocal = hasLocal || member.NodeID == node
	}
	return hasLocal
}

// The common reducer already verified caller ownership, CAS and revision bounds.
func communicationQualifiedGroupSet(root, node string, r CommunicationRequest, known map[string]string, previous communicationGroup, exists bool) (map[string]any, error) {
	if len(r.MemberPaneIDs) != 0 || !validCommunicationGroupName(r.GroupName) || len(r.GroupMembers) < 2 || len(r.GroupMembers) > communicationMaxGroupMembers {
		return nil, errors.New("use two to thirty-two qualified members without legacy member IDs")
	}
	members := append([]CommunicationGroupMember(nil), r.GroupMembers...)
	for i, member := range members {
		members[i] = CommunicationGroupMember{NodeID: strings.ToLower(member.NodeID), PaneID: strings.ToLower(member.PaneID)}
	}
	sort.Slice(members, func(i, j int) bool { return groupMemberKey(members[i]) < groupMemberKey(members[j]) })
	now := time.Now().UTC()
	created := previous.CreatedAt
	if !exists {
		created = now
	}
	group := communicationGroup{Version: 2, ID: strings.ToLower(r.GroupID), NodeID: node, Name: strings.TrimSpace(r.GroupName), OwnerClientID: r.ClientID,
		MemberRefs: members, Revision: previous.Revision + 1, CreatedAt: created, UpdatedAt: now}
	if !validQualifiedCommunicationGroup(group, node) {
		return nil, errors.New("invalid or duplicate qualified group member")
	}
	if r.ActorPaneID != "" && !communicationGroupHasMember(group, node, strings.ToLower(r.ActorPaneID)) {
		return nil, errors.New("caller's local pane must remain a group member")
	}
	for _, member := range members {
		if member.NodeID == node {
			if _, ok := known[member.PaneID]; !ok {
				return nil, errors.New("local group member is not in this daemon's catalogue")
			}
			continue
		}
		reviewed := false
		for _, local := range members {
			if local.NodeID != node {
				continue
			}
			link, err := readRemoteLink(root, node, remotePairID(node, local.PaneID, member.NodeID, member.PaneID))
			if errors.Is(err, os.ErrNotExist) {
				continue
			}
			if err != nil {
				return nil, err
			}
			if link.Retired {
				continue
			}
			route, _, cert, err := activePeerRoute(root, node, link.RouteID)
			if err != nil {
				return nil, err
			}
			if route.Revision == link.RouteRevision && route.PeerNodeID == member.NodeID && peerFingerprint(cert) == link.PeerCertificateSHA256 {
				reviewed = true
				break
			}
		}
		if !reviewed {
			return nil, errors.New("remote group member requires an active reviewed pair with a local member")
		}
	}
	if !exists {
		paths, err := filepath.Glob(filepath.Join(root, "group-*.json"))
		if err != nil {
			return nil, err
		}
		if len(paths) >= communicationMaxGroups {
			return nil, errors.New("communication group limit reached")
		}
	}
	if err := communicationAtomic(filepath.Join(root, "group-"+group.ID+".json"), group); err != nil {
		return nil, err
	}
	links := make([]map[string]string, 0, len(members))
	for _, member := range members {
		links = append(links, map[string]string{"from": group.ID, "to": groupMemberKey(member), "kind": "group_member"})
	}
	if err := communicationEvent(root, node, "communication_group_saved", links); err != nil {
		return nil, fmt.Errorf("qualified group saved but event append failed: %w", err)
	}
	return communicationGroupResult(group), nil
}

// This guard must be inside the recipient's durable claim critical section.
func communicationGroupDispatchGuard(root, node string, r CommunicationRequest, targetNode, targetPane string) error {
	if r.GroupID == "" {
		return nil
	}
	if !canonicalRouteToken(strings.ToLower(r.GroupID)) || r.ExpectedGroupRevision == 0 {
		return errors.New("valid group dispatch scope required")
	}
	var group communicationGroup
	if err := communicationRead(filepath.Join(root, "group-"+strings.ToLower(r.GroupID)+".json"), &group); err != nil {
		return err
	}
	if !validCommunicationGroup(group, node) || group.ID != strings.ToLower(r.GroupID) || group.Retired || group.Revision != r.ExpectedGroupRevision ||
		!communicationGroupHasMember(group, node, r.SourcePaneID) || !communicationGroupHasMember(group, targetNode, targetPane) {
		return errors.New("group changed, retired or no longer contains these recipients")
	}
	return nil
}

type communicationQualifiedTarget struct {
	Member            CommunicationGroupMember        `json:"member"`
	MessageID         string                          `json:"message_id"`
	Fingerprint       string                          `json:"fingerprint"`
	RemoteFingerprint string                          `json:"remote_fingerprint,omitempty"`
	LinkID            string                          `json:"link_id,omitempty"`
	LinkRevision      uint64                          `json:"link_revision,omitempty"`
	Source            communicationPinnedConversation `json:"source_binding"`
	Target            communicationPinnedConversation `json:"target_binding"`
	PreflightError    string                          `json:"preflight_error,omitempty"`
	Result            map[string]any                  `json:"result"`
}
type communicationQualifiedFanout struct {
	Version            int                            `json:"version"`
	NodeID             string                         `json:"node_id"`
	GroupID            string                         `json:"group_id"`
	GroupRevision      uint64                         `json:"group_revision"`
	MessageID          string                         `json:"message_id"`
	SourcePaneID       string                         `json:"source_pane_id"`
	SubmittingClientID string                         `json:"submitting_client_id"`
	Fingerprint        string                         `json:"fingerprint"`
	CreatedAt          time.Time                      `json:"created_at"`
	DispatchFinished   bool                           `json:"dispatch_finished"`
	Targets            []communicationQualifiedTarget `json:"recipients"`
}

func qualifiedChildID(group, message, node, source string, target CommunicationGroupMember) string {
	digest := sha256.Sum256([]byte("qualified-group-v2\n" + group + "\n" + message + "\n" + node + ":" + source + "\n" + groupMemberKey(target)))
	return hex.EncodeToString(digest[:])
}
func qualifiedParentFingerprint(node, caller string, r CommunicationRequest) string {
	data, _ := json.Marshal(struct {
		Node, Caller, Group, Source, Message, Text string
		Revision                                   uint64
	}{node, caller, r.GroupID, r.SourcePaneID, r.MessageID, r.Text, r.ExpectedGroupRevision})
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}
func validQualifiedFanout(receipt communicationQualifiedFanout, node string) bool {
	if receipt.Version != 2 || receipt.NodeID != node || !canonicalRouteToken(node) || !canonicalRouteToken(receipt.GroupID) || !canonicalRouteToken(receipt.MessageID) ||
		!canonicalRouteToken(receipt.SourcePaneID) || !canonicalRouteToken(receipt.SubmittingClientID) || receipt.GroupRevision == 0 || !remoteDigest(receipt.Fingerprint) ||
		receipt.CreatedAt.IsZero() || len(receipt.Targets) < 1 || len(receipt.Targets) >= communicationMaxGroupMembers {
		return false
	}
	seen := map[string]bool{}
	for _, target := range receipt.Targets {
		key := groupMemberKey(target.Member)
		if !canonicalRouteToken(target.Member.NodeID) || !canonicalRouteToken(target.Member.PaneID) || seen[key] ||
			(target.Member.NodeID == node && target.Member.PaneID == receipt.SourcePaneID) ||
			target.MessageID != qualifiedChildID(receipt.GroupID, receipt.MessageID, node, receipt.SourcePaneID, target.Member) || !remoteDigest(target.Fingerprint) || target.Result == nil {
			return false
		}
		if target.Member.NodeID != node && target.PreflightError == "" && (!remoteDigest(target.RemoteFingerprint) || !remoteDigest(target.LinkID) || target.LinkRevision == 0 || !validRemoteConversation(target.Source) || !validRemoteConversation(target.Target)) {
			return false
		}
		seen[key] = true
	}
	return true
}
func qualifiedFanoutResult(receipt communicationQualifiedFanout) map[string]any {
	return map[string]any{"receipt": receipt, "authority": "relayd", "desktop_required": false, "replay_permitted": false}
}
func qualifiedTargetResult(receipt communicationQualifiedFanout, target communicationQualifiedTarget, result map[string]any) map[string]any {
	value := communicationNativeOutcome(result, nil)
	value["message_id"], value["source_node_id"], value["source_pane_id"] = target.MessageID, receipt.NodeID, receipt.SourcePaneID
	value["target_node_id"], value["pane_id"], value["submitting_client_id"] = target.Member.NodeID, target.Member.PaneID, receipt.SubmittingClientID
	value["authority"], value["desktop_required"], value["replay_permitted"] = "relayd", false, false
	value["source_authentication"] = "claimed_pane_label"
	return value
}

func communicationUseQualifiedFanout(root, node string, r CommunicationRequest) (bool, error) {
	qualified := false
	err := communicationFanoutLocked(root, func() error {
		if _, err := communicationAuthorize(root, r); err != nil {
			return err
		}
		if !canonicalRouteToken(strings.ToLower(r.GroupID)) || !canonicalRouteToken(strings.ToLower(r.MessageID)) {
			return errors.New("valid group and message identity required")
		}
		var header struct {
			Version int `json:"version"`
		}
		if err := communicationRead(communicationFanoutPath(root, strings.ToLower(r.MessageID)), &header); err == nil {
			qualified = header.Version == 2
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if r.Operation == "group_receipt" {
			return nil
		}
		var group communicationGroup
		if err := communicationRead(filepath.Join(root, "group-"+strings.ToLower(r.GroupID)+".json"), &group); err != nil {
			return err
		}
		qualified = group.Version == 2
		return nil
	})
	return qualified, err
}

func refreshQualifiedFanout(root, node string, receipt communicationQualifiedFanout) (communicationQualifiedFanout, error) {
	if !validQualifiedFanout(receipt, node) {
		return receipt, errors.New("invalid qualified group receipt")
	}
	for i, target := range receipt.Targets {
		if target.Member.NodeID == node {
			var child communicationReceipt
			if err := communicationRead(filepath.Join(root, "message-"+target.MessageID+".json"), &child); errors.Is(err, os.ErrNotExist) {
				continue
			} else if err != nil {
				return receipt, err
			}
			if child.Fingerprint != target.Fingerprint || child.Result == nil || child.Result["submitting_client_id"] != receipt.SubmittingClientID || child.Result["source_pane_id"] != receipt.SourcePaneID || child.Result["pane_id"] != target.Member.PaneID {
				return receipt, errors.New("local group child receipt scope mismatch")
			}
			receipt.Targets[i].Result = qualifiedTargetResult(receipt, target, child.Result)
		} else {
			var child communicationRemoteOutbound
			if err := communicationRead(remoteOutboundPath(root, target.MessageID), &child); errors.Is(err, os.ErrNotExist) {
				continue
			} else if err != nil {
				return receipt, err
			}
			if !validRemoteOutbound(child, node) || child.Wire.Fingerprint != target.RemoteFingerprint || child.Wire.CallerID != receipt.SubmittingClientID || child.Wire.LinkID != target.LinkID ||
				child.Wire.SourcePaneID != receipt.SourcePaneID || child.Wire.TargetNodeID != target.Member.NodeID || child.Wire.TargetPaneID != target.Member.PaneID {
				return receipt, errors.New("remote group child receipt scope mismatch")
			}
			receipt.Targets[i].Result = qualifiedTargetResult(receipt, target, remoteOutboundResult(child))
		}
	}
	return receipt, nil
}

func communicationQualifiedGroupSend(root, node string, r CommunicationRequest, hooks communicationGroupNative) (map[string]any, error) {
	r.GroupID, r.SourcePaneID, r.MessageID = strings.ToLower(r.GroupID), strings.ToLower(r.SourcePaneID), strings.ToLower(r.MessageID)
	if !canonicalRouteToken(r.GroupID) || !canonicalRouteToken(r.SourcePaneID) || !canonicalRouteToken(r.MessageID) || !utf8.ValidString(r.Text) || len(r.Text) == 0 || len(r.Text) > 16384 || strings.TrimSpace(r.Text) == "" {
		return nil, errors.New("valid qualified group, sender, message and text required")
	}
	path := communicationFanoutPath(root, r.MessageID)
	var parent communicationQualifiedFanout
	existing := false
	err := communicationFanoutLocked(root, func() error {
		caller, err := communicationAuthorize(root, r)
		if err != nil {
			return err
		}
		r.ClientID = caller
		fingerprint := qualifiedParentFingerprint(node, caller, r)
		if err := communicationRead(path, &parent); err == nil {
			if !validQualifiedFanout(parent, node) || parent.Fingerprint != fingerprint || parent.SubmittingClientID != caller || parent.GroupID != r.GroupID || parent.SourcePaneID != r.SourcePaneID || parent.MessageID != r.MessageID {
				return errors.New("qualified group message identity conflict")
			}
			parent, err = refreshQualifiedFanout(root, node, parent)
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
		if !validQualifiedCommunicationGroup(group, node) || group.ID != r.GroupID || group.Retired || group.Revision != r.ExpectedGroupRevision || !communicationGroupHasMember(group, node, r.SourcePaneID) {
			return errors.New("qualified group changed or does not contain the sender")
		}
		parent = communicationQualifiedFanout{Version: 2, NodeID: node, GroupID: r.GroupID, GroupRevision: group.Revision, MessageID: r.MessageID,
			SourcePaneID: r.SourcePaneID, SubmittingClientID: caller, Fingerprint: fingerprint, CreatedAt: time.Now().UTC()}
		for _, member := range group.MemberRefs {
			if member.NodeID == node && member.PaneID == r.SourcePaneID {
				continue
			}
			target := communicationQualifiedTarget{Member: member, MessageID: qualifiedChildID(r.GroupID, r.MessageID, node, r.SourcePaneID, member), Result: map[string]any{"status": "outcome_unknown", "replay_permitted": false}}
			target.Fingerprint = communicationFanoutChildFingerprint(r.SourcePaneID, groupMemberKey(member), target.MessageID, r.Text)
			if member.NodeID == node {
				target.Fingerprint = communicationFanoutChildFingerprint(r.SourcePaneID, member.PaneID, target.MessageID, r.Text)
				id, _, err := communicationPair(r.SourcePaneID, member.PaneID)
				var link communicationLink
				if err != nil || communicationRead(filepath.Join(root, "link-"+id+".json"), &link) != nil || link.NodeID != node || link.Transport == "unavailable" {
					target.PreflightError = "review the local native communication pair"
				} else {
					for _, saved := range link.Members {
						if saved.PaneID == r.SourcePaneID {
							target.Source = communicationPin(saved)
						}
						if saved.PaneID == member.PaneID {
							target.Target = communicationPin(saved)
						}
					}
					if !validRemoteConversation(target.Source) || !validRemoteConversation(target.Target) {
						target.PreflightError = "local pair has no reviewed conversations"
					}
				}
			} else {
				link, err := readRemoteLink(root, node, remotePairID(node, r.SourcePaneID, member.NodeID, member.PaneID))
				if err != nil || link.Retired {
					target.PreflightError = "review this sender's remote communication pair"
				} else {
					target.LinkID, target.LinkRevision, target.Source, target.Target = link.ID, link.Revision, link.LocalConversation, link.PeerConversation
					wire := communicationRemoteMessage{Version: 1, Operation: "send", LinkID: link.ID, SourceLinkRevision: link.Revision, TargetLinkRevision: link.PeerRevision,
						SourceNodeID: node, TargetNodeID: member.NodeID, SourcePaneID: r.SourcePaneID, TargetPaneID: member.PaneID, CallerID: caller,
						SourceConversation: link.LocalConversation, TargetConversation: link.PeerConversation, MessageID: target.MessageID, Text: r.Text}
					target.RemoteFingerprint = remoteMessageFingerprint(wire)
				}
			}
			parent.Targets = append(parent.Targets, target)
		}
		if !validQualifiedFanout(parent, node) {
			return errors.New("invalid qualified fanout plan")
		}
		if err := communicationAtomic(path, parent); err != nil {
			return err
		}
		return communicationEvent(root, node, "qualified_group_fanout_claimed", []map[string]string{{"group_id": r.GroupID, "message_id": r.MessageID}})
	})
	if err != nil {
		return nil, err
	}
	if existing {
		return qualifiedFanoutResult(parent), nil
	}
	for i, target := range parent.Targets {
		var result map[string]any
		if target.Member.NodeID == node {
			result, err = dispatchQualifiedLocal(root, node, r, parent, target, hooks)
		} else if target.PreflightError != "" {
			result = map[string]any{"status": "blocked", "error": target.PreflightError}
		} else {
			child := r
			child.Operation = "remote_send"
			child.PaneID, child.PeerNodeID, child.MessageID = target.Member.PaneID, target.Member.NodeID, target.MessageID
			child.LinkID, child.ExpectedRemoteLinkRevision = target.LinkID, target.LinkRevision
			result, err = communicationSendRemote(root, node, child, hooks)
			if err != nil && result == nil {
				result = map[string]any{"status": "blocked", "error": communicationBoundedString(err.Error(), 2048)}
				err = nil
			}
		}
		if result != nil {
			updateErr := communicationFanoutLocked(root, func() error {
				var current communicationQualifiedFanout
				if readErr := communicationRead(path, &current); readErr != nil {
					return readErr
				}
				if !validQualifiedFanout(current, node) || current.Fingerprint != parent.Fingerprint {
					return errors.New("qualified fanout changed during recipient dispatch")
				}
				current.Targets[i].Result = qualifiedTargetResult(current, target, result)
				if writeErr := communicationAtomic(path, current); writeErr != nil {
					return writeErr
				}
				parent = current
				return nil
			})
			if updateErr != nil {
				return qualifiedFanoutResult(parent), updateErr
			}
		}
		if err != nil {
			return qualifiedFanoutResult(parent), err
		}
	}
	err = communicationFanoutLocked(root, func() error {
		if err := communicationRead(path, &parent); err != nil {
			return err
		}
		if !validQualifiedFanout(parent, node) {
			return errors.New("invalid completed qualified fanout")
		}
		parent.DispatchFinished = true
		if err := communicationAtomic(path, parent); err != nil {
			return err
		}
		return communicationEvent(root, node, "qualified_group_fanout_finished", []map[string]string{{"group_id": r.GroupID, "message_id": r.MessageID}})
	})
	return qualifiedFanoutResult(parent), err
}

func dispatchQualifiedLocal(root, node string, r CommunicationRequest, parent communicationQualifiedFanout, target communicationQualifiedTarget, hooks communicationGroupNative) (map[string]any, error) {
	var source, recipient communicationMember
	if target.PreflightError == "" {
		source, recipient = hooks.observe(r.SourcePaneID), hooks.observe(target.Member.PaneID)
	}
	path := filepath.Join(root, "message-"+target.MessageID+".json")
	var child communicationReceipt
	claimed := false
	err := communicationFanoutLocked(root, func() error {
		reason := target.PreflightError
		caller, authErr := communicationAuthorize(root, r)
		if authErr != nil {
			reason = authErr.Error()
		} else if caller != parent.SubmittingClientID {
			reason = "submitting caller changed"
		}
		if guardErr := communicationGroupDispatchGuard(root, node, r, node, target.Member.PaneID); guardErr != nil {
			reason = guardErr.Error()
		}
		if reason == "" && (!communicationPinMatches(target.Source, source) || !communicationPinMatches(target.Target, recipient)) {
			reason = "reviewed native conversation changed"
		}
		if err := communicationRead(path, &child); err == nil {
			if child.Fingerprint != target.Fingerprint || child.Result == nil || child.Result["submitting_client_id"] != parent.SubmittingClientID {
				return errors.New("local qualified child identity conflict")
			}
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		status := "outcome_unknown"
		if reason != "" {
			status = "blocked"
		}
		result := qualifiedTargetResult(parent, target, map[string]any{"status": status})
		if reason != "" {
			result["error"] = communicationBoundedString(reason, 2048)
		}
		child = communicationReceipt{Version: 1, Fingerprint: target.Fingerprint, CreatedAt: time.Now().UTC(), Result: result}
		if err := communicationAtomic(path, child); err != nil {
			return err
		}
		if err := communicationEvent(root, node, "qualified_local_recipient_claimed", []map[string]string{{"message_id": target.MessageID}}); err != nil {
			return err
		}
		claimed = reason == ""
		return nil
	})
	if err != nil {
		return child.Result, err
	}
	if !claimed {
		return child.Result, nil
	}
	packet := map[string]any{"operation": "send", "expected": recipient.Endpoint, "messageID": target.MessageID, "targetPaneID": target.Member.PaneID,
		"text": r.Text, "submittingClientID": parent.SubmittingClientID, "source": map[string]any{"hostID": node, "paneID": r.SourcePaneID, "sessionID": source.SessionID}}
	native, nativeErr := hooks.send(target.Member.PaneID, packet)
	outcome := communicationNativeOutcome(native, nativeErr)
	err = communicationFanoutLocked(root, func() error {
		if err := communicationRead(path, &child); err != nil {
			return err
		}
		if child.Fingerprint != target.Fingerprint {
			return errors.New("qualified local child receipt changed")
		}
		child.Result = qualifiedTargetResult(parent, target, outcome)
		if err := communicationAtomic(path, child); err != nil {
			return err
		}
		return communicationEvent(root, node, "qualified_local_recipient_outcome", []map[string]string{{"message_id": target.MessageID, "status": fmtRemoteStatus(child.Result)}})
	})
	return child.Result, err
}

func communicationQualifiedGroupReceipt(root, node string, r CommunicationRequest) (map[string]any, error) {
	r.GroupID, r.MessageID = strings.ToLower(r.GroupID), strings.ToLower(r.MessageID)
	var parent communicationQualifiedFanout
	canRecover := false
	err := communicationFanoutLocked(root, func() error {
		caller, err := communicationAuthorize(root, r)
		if err != nil {
			return err
		}
		if !canonicalRouteToken(r.MessageID) {
			return errors.New("valid group message identity required")
		}
		if err := communicationRead(communicationFanoutPath(root, r.MessageID), &parent); err != nil {
			return err
		}
		if !validQualifiedFanout(parent, node) || parent.GroupID != r.GroupID {
			return errors.New("qualified group receipt scope mismatch")
		}
		parent, err = refreshQualifiedFanout(root, node, parent)
		if err != nil {
			return err
		}
		canRecover = caller == parent.SubmittingClientID || (r.ClientToken == "" && r.ActorPaneID == "")
		return nil
	})
	if err != nil {
		return nil, err
	}
	if canRecover {
		for _, target := range parent.Targets {
			if target.Member.NodeID == node || target.PreflightError != "" || (fmtRemoteStatus(target.Result) != "outcome_unknown" && fmtRemoteStatus(target.Result) != "unknown") {
				continue
			}
			query := r
			query.Operation = "remote_receipt"
			query.MessageID = target.MessageID
			query.SourcePaneID = parent.SourcePaneID
			query.PaneID = target.Member.PaneID
			query.PeerNodeID, query.LinkID, query.Text = target.Member.NodeID, target.LinkID, ""
			// Network failures retain the prior unknown outcome. No send operation
			// or original text is ever reconstructed by receipt recovery.
			_, _ = communicationSendRemote(root, node, query, communicationGroupNative{})
		}
	}
	err = communicationFanoutLocked(root, func() error {
		if _, err := communicationAuthorize(root, r); err != nil {
			return err
		}
		if err := communicationRead(communicationFanoutPath(root, r.MessageID), &parent); err != nil {
			return err
		}
		var err error
		parent, err = refreshQualifiedFanout(root, node, parent)
		return err
	})
	return qualifiedFanoutResult(parent), err
}
