package daemon

import (
	"errors"
	"path/filepath"
	"strings"
)

// communicationDesktopRemoteLink resolves the one saved route link that pins a
// verified Claude desktop session as its local conversation and names the
// pane as its peer. The session is the sender pane. Only a kernel-verified
// actor resolves this way; a claimed sender never does. Zero or several
// matches are refused, never chosen between.
func communicationDesktopRemoteLink(root, node string, r CommunicationRequest) (string, error) {
	source := strings.ToLower(r.SourcePaneID)
	pane := strings.ToLower(r.PaneID)
	if !r.actorVerified || !strings.EqualFold(r.ActorPaneID, r.SourcePaneID) {
		return "", errors.New("a desktop session link needs the verified sender session")
	}
	if !nativeClaudeSessionID.MatchString(source) {
		return "", errors.New("a link without link_id is named only by a Claude desktop session")
	}
	paths, err := filepath.Glob(filepath.Join(root, "remote-link-*.json"))
	if err != nil {
		return "", err
	}
	matches := []string{}
	for _, path := range paths {
		var link CommunicationRemoteLink
		if communicationRead(path, &link) != nil || link.Retired || link.NodeID != node {
			continue
		}
		if strings.ToLower(link.LocalPaneID) == source && strings.ToLower(link.PeerPaneID) == pane &&
			link.LocalConversation.Provider == "claude" && strings.ToLower(link.LocalConversation.SessionID) == source &&
			remoteDigest(link.ID) {
			matches = append(matches, link.ID)
		}
	}
	switch len(matches) {
	case 0:
		return "", errors.New("no saved route link pairs this desktop session with that pane; link it first")
	case 1:
		return matches[0], nil
	default:
		return "", errors.New("several saved route links pair this desktop session with that pane")
	}
}
