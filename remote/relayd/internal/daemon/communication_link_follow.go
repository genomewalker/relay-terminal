package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// A saved pair pins each member's provider conversation. Claude's /clear (and
// a /compact or /resume that starts another session) keeps the same process but
// gives the pane a new session ID, which used to break every link of that pane
// silently. A link now follows its pane through such a change when the native
// observation proves it is the same process: the same pid and the same kernel
// start time as the pin, the same provider, and one verified endpoint. A change
// of process is not followed; the pair must be saved again.
//
// The member keeps its pane, host and name. Its conversation, pid, start and
// endpoint take the live values, and the change is appended to
// link-<id>.repins.jsonl. UpdatedAt is left alone: it is the pair's review
// revision (shepherd reports check it), and following changes no review.

// communicationLinkRelinkNeeded names a conversation change the link cannot follow.
const communicationLinkRelinkNeeded = "linked conversation changed in another process; relink needed: save the pair again"

// communicationLinkFollow decides whether a saved member still names the live
// one. It returns the member to store and whether it differs from saved.
func communicationLinkFollow(saved, live communicationMember) (communicationMember, bool, error) {
	if saved.SessionID == "" {
		return saved, false, nil
	}
	if saved.Provider != live.Provider || live.SessionID == "" || live.Endpoint == nil || live.Unavailable != "" {
		return saved, false, errors.New("linked conversation changed; review the pair before sending")
	}
	sameProcess := saved.PID != 0 && saved.Start != "" && saved.PID == live.PID && saved.Start == live.Start
	if saved.SessionID != live.SessionID && !sameProcess {
		return saved, false, errors.New(communicationLinkRelinkNeeded)
	}
	// Same conversation (perhaps resumed in a new process) or the same process
	// in a new conversation: keep the pin current so a later /clear follows.
	if saved.SessionID == live.SessionID && saved.PID == live.PID && saved.Start == live.Start {
		return saved, false, nil
	}
	updated := saved
	updated.SessionID, updated.PID, updated.Start, updated.Endpoint = live.SessionID, live.PID, live.Start, live.Endpoint
	return updated, true, nil
}

// communicationLinkFollowAll applies communicationLinkFollow to every member
// observed in live (keyed by pane) and records each change. Members missing
// from live are left as saved. It returns the link to store.
func communicationLinkFollowAll(root string, link communicationLink, live map[string]communicationMember) (communicationLink, bool, error) {
	changed := false
	members := append([]communicationMember(nil), link.Members...)
	var repins []map[string]any
	for i, saved := range members {
		observed, ok := live[strings.ToLower(saved.PaneID)]
		if !ok {
			continue
		}
		updated, moved, err := communicationLinkFollow(saved, observed)
		if err != nil {
			return link, false, err
		}
		if !moved {
			continue
		}
		members[i], changed = updated, true
		kind := "process_refreshed"
		if saved.SessionID != updated.SessionID {
			kind = "conversation_followed"
		}
		repins = append(repins, map[string]any{"time": time.Now().UTC(), "link_id": link.ID, "pane_id": saved.PaneID, "kind": kind,
			"provider": updated.Provider, "old_session": saved.SessionID, "new_session": updated.SessionID,
			"old_pid": saved.PID, "new_pid": updated.PID, "old_start": saved.Start, "new_start": updated.Start})
	}
	if !changed {
		return link, false, nil
	}
	link.Members = members
	for _, repin := range repins {
		// Evidence only: a failed append never undoes a follow the checks accepted.
		_ = communicationAppendRepin(root, link.ID, repin)
	}
	return link, true, nil
}

func communicationAppendRepin(root, linkID string, record map[string]any) error {
	line, err := json.Marshal(record)
	if err != nil {
		return err
	}
	file, err := os.OpenFile(filepath.Join(root, "link-"+linkID+".repins.jsonl"), os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0600)
	if err != nil {
		return err
	}
	defer file.Close()
	if _, err := file.Write(append(line, '\n')); err != nil {
		return fmt.Errorf("record link repin: %w", err)
	}
	return nil
}
