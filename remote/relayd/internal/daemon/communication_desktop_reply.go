package daemon

import (
	"errors"
	"path/filepath"
	"strings"
)

// communicationSendToDesktop routes a pane's message to a Claude desktop session
// over the saved route link that pins that pane and that session. It only
// applies when the target is not a pane on this daemon and the sender is a
// kernel-verified pane. linked is false when no such pinned pair exists, and the
// caller keeps its normal path.
func communicationSendToDesktop(root, node string, r CommunicationRequest, hooks communicationGroupNative) (map[string]any, bool, error) {
	source := strings.ToLower(r.SourcePaneID)
	target := strings.ToLower(r.PaneID)
	if !r.actorVerified || !strings.EqualFold(r.ActorPaneID, r.SourcePaneID) || !nativeClaudeSessionID.MatchString(target) ||
		communicationPaneExists(target) {
		return nil, false, nil
	}
	paths, err := filepath.Glob(filepath.Join(root, "remote-link-*.json"))
	if err != nil {
		return nil, false, err
	}
	var matches []CommunicationRemoteLink
	for _, path := range paths {
		var link CommunicationRemoteLink
		if communicationRead(path, &link) != nil || link.Retired || link.NodeID != node || link.Version != 1 {
			continue
		}
		if strings.EqualFold(link.LocalPaneID, source) && strings.EqualFold(link.PeerPaneID, target) &&
			link.PeerConversation.Provider == "claude" && strings.EqualFold(link.PeerConversation.SessionID, target) {
			matches = append(matches, link)
		}
	}
	if len(matches) == 0 {
		return nil, false, nil
	}
	if len(matches) > 1 {
		return nil, true, errors.New("several saved route links pair this pane with that desktop session")
	}
	r.Operation, r.LinkID = "remote_send", matches[0].ID
	r.ExpectedRemoteLinkRevision = matches[0].Revision
	result, err := communicationSendRemote(root, node, r, hooks)
	return result, true, err
}
