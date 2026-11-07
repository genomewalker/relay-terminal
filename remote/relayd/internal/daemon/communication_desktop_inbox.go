package daemon

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// A Claude desktop session reads the replies delivered to it here. Each entry is
// written only after a delivery was accepted, and records the registration it was
// delivered under. Reads return only entries of the session's current
// registration, so replies addressed to an earlier registration never reach a
// different one.
const (
	desktopInboxLimit    = 50
	desktopInboxTextMax  = 16384
	desktopInboxReadMax  = 20
	desktopInboxFileMax  = 1 << 20
	desktopInboxStatusOK = "accepted"
)

type desktopInboxEntry struct {
	MessageID   string    `json:"message_id"`
	SourceNode  string    `json:"source_node_id"`
	SourcePane  string    `json:"source_pane_id"`
	Text        string    `json:"text"`
	AccountRoot string    `json:"account_root"`
	ReceivedAt  time.Time `json:"received_at"`
}

type desktopInbox struct {
	Version   int                 `json:"version"`
	SessionID string              `json:"session_id"`
	Entries   []desktopInboxEntry `json:"entries"`
}

func desktopInboxPath(root, session string) string {
	return filepath.Join(root, "desktop-inbox-"+session+".json")
}

// deliveredToDesktop reports whether a native delivery was accepted or written.
func deliveredToDesktop(result map[string]any) bool {
	status, _ := result["status"].(string)
	return status == desktopInboxStatusOK || status == "written_to_socket"
}

// appendDesktopInbox records one delivered reply for a registered desktop session.
// A repeated message ID is never recorded twice; the list is bounded.
func appendDesktopInbox(root, session string, entry desktopInboxEntry) error {
	session = strings.ToLower(session)
	if !validSessionID.MatchString(session) || len(entry.Text) == 0 || len(entry.Text) > desktopInboxTextMax {
		return errors.New("invalid desktop inbox entry")
	}
	return communicationFanoutLocked(root, func() error {
		var inbox desktopInbox
		if err := communicationRead(desktopInboxPath(root, session), &inbox); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		inbox.Version, inbox.SessionID = 1, session
		for _, existing := range inbox.Entries {
			if existing.MessageID == entry.MessageID {
				return nil
			}
		}
		inbox.Entries = append(inbox.Entries, entry)
		if len(inbox.Entries) > desktopInboxLimit {
			inbox.Entries = inbox.Entries[len(inbox.Entries)-desktopInboxLimit:]
		}
		data, err := json.Marshal(inbox)
		if err != nil || len(data) > desktopInboxFileMax {
			return errors.New("desktop inbox exceeds limit")
		}
		return communicationAtomic(desktopInboxPath(root, session), inbox)
	})
}

// communicationDesktopInboxRead returns the replies for the verified desktop
// session, from its current registration only.
func communicationDesktopInboxRead(root string, r CommunicationRequest) (map[string]any, error) {
	session := strings.ToLower(r.SourcePaneID)
	if !r.actorVerified || !strings.EqualFold(r.ActorPaneID, r.SourcePaneID) || !nativeClaudeSessionID.MatchString(session) {
		return nil, errors.New("reading the desktop inbox needs the verified desktop session")
	}
	endpoint, err := readClaudeSessionEndpoint(root, session)
	if err != nil {
		return nil, errors.New("this Claude session is not registered as a desktop session")
	}
	var inbox desktopInbox
	if err := communicationRead(desktopInboxPath(root, session), &inbox); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return map[string]any{"messages": []desktopInboxEntry{}, "authority": "relayd"}, nil
		}
		return nil, err
	}
	messages := []desktopInboxEntry{}
	for _, entry := range inbox.Entries {
		if entry.AccountRoot == endpoint.AccountRoot {
			messages = append(messages, entry)
		}
	}
	if len(messages) > desktopInboxReadMax {
		messages = messages[len(messages)-desktopInboxReadMax:]
	}
	return map[string]any{"messages": messages, "authority": "relayd", "desktop_required": false}, nil
}
