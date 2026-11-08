package daemon

import (
	"errors"
	"slices"
	"time"
)

// A cross-host link pins the conversation at each end. Claude's /clear keeps
// the pane's process but starts a new session; the link follows it.
//
// Each host follows only its own member, from kernel observation, under the
// rule communicationLinkFollow applies to same-host pairs: the same pid, kernel
// start time and provider. The previous conversation goes to LocalFollowedFrom.
// Revisions, route, certificate and callers never change, so neither side has
// to wait for the other.
//
// The peer learns the change from the next message: it carries the sender's
// LocalFollowedFrom as source_followed_from, inside the fingerprint (and so
// inside the host-channel statement). The receiver moves its PeerConversation
// to the message's source conversation only when its current PeerConversation
// is in that list. It cannot observe the peer's process; it relies on the
// pinned peer relayd's statement, the same trust the peer's kernel_verified
// sender label already rests on.
//
// Until the peer names the new conversation, a message to an earlier one in
// LocalFollowedFrom is still accepted (the peer has not heard of the change).
// When the peer names the current conversation, the list is cleared.

// remoteFollowLimit bounds LocalFollowedFrom. More unconfirmed changes than this
// and the peer may need the pair saved again.
const remoteFollowLimit = 16

func validFollowedFrom(list []communicationPinnedConversation, current communicationPinnedConversation) bool {
	if len(list) > remoteFollowLimit {
		return false
	}
	for _, pin := range list {
		if !validRemoteConversation(pin) || pin.Provider != current.Provider || pin == current {
			return false
		}
	}
	return true
}

// remoteLinkFollowLocal follows the link's local member to the live
// observation. It returns the link to store and whether it changed.
func remoteLinkFollowLocal(link CommunicationRemoteLink, live communicationMember) (CommunicationRemoteLink, bool, error) {
	saved := communicationMember{PaneID: link.LocalPaneID, Provider: link.LocalConversation.Provider, SessionID: link.LocalConversation.SessionID,
		PID: link.LocalPID, Start: link.LocalStart}
	updated, moved, err := communicationLinkFollow(saved, live)
	if err != nil {
		if err.Error() == communicationLinkRelinkNeeded {
			return link, false, err
		}
		return link, false, errors.New("reviewed local conversation changed or is unavailable")
	}
	if !moved {
		return link, false, nil
	}
	next := communicationPinnedConversation{Provider: updated.Provider, SessionID: updated.SessionID}
	if !validRemoteConversation(next) {
		return link, false, errors.New("reviewed local conversation changed or is unavailable")
	}
	if next != link.LocalConversation {
		history := append(slices.Clone(link.LocalFollowedFrom), link.LocalConversation)
		history = slices.DeleteFunc(history, func(pin communicationPinnedConversation) bool { return pin == next })
		if len(history) > remoteFollowLimit {
			history = history[len(history)-remoteFollowLimit:]
		}
		link.LocalFollowedFrom = history
	}
	link.LocalConversation, link.LocalPID, link.LocalStart = next, updated.PID, updated.Start
	return link, true, nil
}

// remoteAcceptsTarget reports whether a message addressed to target reaches
// this link's local member: the current conversation, or an earlier one the
// peer has not yet heard was followed.
func remoteAcceptsTarget(link CommunicationRemoteLink, target communicationPinnedConversation) bool {
	return target == link.LocalConversation || slices.Contains(link.LocalFollowedFrom, target)
}

// remoteAcceptsSource reports whether a message's source conversation is the
// pinned peer conversation, or follows it in the same peer process.
func remoteAcceptsSource(link CommunicationRemoteLink, message communicationRemoteMessage) bool {
	return message.SourceConversation == link.PeerConversation || slices.Contains(link.PeerFollowedFrom, message.SourceConversation) ||
		(message.SourceConversation.Provider == link.PeerConversation.Provider && slices.Contains(message.SourceFollowedFrom, link.PeerConversation))
}

// remoteLinkLearnFromMessage applies what an accepted message tells this host:
// the peer's current conversation, and whether the peer already names ours.
func remoteLinkLearnFromMessage(link CommunicationRemoteLink, message communicationRemoteMessage) (CommunicationRemoteLink, []map[string]any) {
	var audit []map[string]any
	// A late message from an earlier peer conversation never moves the pin back.
	if message.SourceConversation != link.PeerConversation && !slices.Contains(link.PeerFollowedFrom, message.SourceConversation) {
		history := append(slices.Clone(link.PeerFollowedFrom), link.PeerConversation)
		if len(history) > remoteFollowLimit {
			history = history[len(history)-remoteFollowLimit:]
		}
		link.PeerFollowedFrom = history
		audit = append(audit, map[string]any{"time": time.Now().UTC(), "link_id": link.ID, "kind": "peer_conversation_followed",
			"pane_id": link.PeerPaneID, "provider": message.SourceConversation.Provider,
			"old_session": link.PeerConversation.SessionID, "new_session": message.SourceConversation.SessionID})
		link.PeerConversation = message.SourceConversation
	}
	if message.TargetConversation == link.LocalConversation && len(link.LocalFollowedFrom) > 0 {
		link.LocalFollowedFrom = nil
	}
	return link, audit
}

func remoteFollowAudit(link CommunicationRemoteLink, before CommunicationRemoteLink) map[string]any {
	kind := "process_refreshed"
	if before.LocalConversation != link.LocalConversation {
		kind = "conversation_followed"
	}
	return map[string]any{"time": time.Now().UTC(), "link_id": link.ID, "kind": kind, "pane_id": link.LocalPaneID,
		"provider": link.LocalConversation.Provider, "old_session": before.LocalConversation.SessionID, "new_session": link.LocalConversation.SessionID,
		"old_pid": before.LocalPID, "new_pid": link.LocalPID, "old_start": before.LocalStart, "new_start": link.LocalStart}
}

func remoteAppendRepins(root, linkID string, records ...map[string]any) {
	for _, record := range records {
		// Evidence only: a failed append never undoes a follow the checks accepted.
		_ = communicationAppendRepinFile(root, "remote-link-"+linkID+".repins.jsonl", record)
	}
}
