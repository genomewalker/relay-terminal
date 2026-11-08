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
const communicationLinkRelinkNeeded = "linked conversation changed in another process or pane root; relink needed: save the pair again"

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
	// The pane is the partner: an agent restarted in the same pane keeps its
	// links when the kernel shows the same pane root (the pane's worker and
	// shell incarnation), the same provider and the same account directory, as
	// recorded at the last use. Moving the pane to another account needs a relink. A changed root is a pane
	// recovery or another terminal and is not followed.
	savedRoot, savedRootStart := communicationEndpointRoot(saved.Endpoint)
	liveRoot, liveRootStart := communicationEndpointRoot(live.Endpoint)
	sameRoot := savedRoot > 0 && savedRootStart != "" && savedRoot == liveRoot && savedRootStart == liveRootStart &&
		saved.Account != "" && saved.Account == live.Account
	if saved.SessionID != live.SessionID && !sameProcess && !sameRoot {
		return saved, false, errors.New(communicationLinkRelinkNeeded)
	}
	// Same conversation (perhaps resumed in a new process) or the same process
	// in a new conversation: keep the pin current so a later /clear follows.
	if saved.SessionID == live.SessionID && saved.PID == live.PID && saved.Start == live.Start && (sameRoot || liveRoot == 0) &&
		(live.Account == "" || saved.Account == live.Account) {
		return saved, false, nil
	}
	updated := saved
	updated.SessionID, updated.PID, updated.Start, updated.Endpoint = live.SessionID, live.PID, live.Start, live.Endpoint
	if live.Account != "" {
		updated.Account = live.Account
	}
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
		if observed.Account == "" {
			observed.Account = communicationAgentAccount(observed.PID, observed.Provider)
		}
		updated, moved, err := communicationLinkFollow(saved, observed)
		if err != nil {
			return link, false, err
		}
		if !moved {
			continue
		}
		members[i], changed = updated, true
		kind := communicationFollowKind(saved.SessionID != updated.SessionID, saved.PID != updated.PID || saved.Start != updated.Start)
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
	return communicationAppendRepinFile(root, "link-"+linkID+".repins.jsonl", record)
}

func communicationAppendRepinFile(root, name string, record map[string]any) error {
	line, err := json.Marshal(record)
	if err != nil {
		return err
	}
	file, err := os.OpenFile(filepath.Join(root, name), os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0600)
	if err != nil {
		return err
	}
	defer file.Close()
	if _, err := file.Write(append(line, '\n')); err != nil {
		return fmt.Errorf("record link repin: %w", err)
	}
	return nil
}

// communicationAgentAccount is the account directory of one exact agent
// process, or "" when it cannot be read (then no restart is followed).
var communicationAgentAccount = func(pid int, provider string) string {
	if pid <= 1 {
		return ""
	}
	root, err := agentConfigRoot(pid, provider)
	if err != nil {
		return ""
	}
	return root
}

// communicationEndpointRoot is the pane root a native observation recorded:
// the root process and its kernel start. Zero when absent.
func communicationEndpointRoot(endpoint map[string]any) (int, string) {
	if endpoint == nil {
		return 0, ""
	}
	pid := 0
	switch value := endpoint["rootPID"].(type) {
	case float64:
		if value == float64(int(value)) {
			pid = int(value)
		}
	case int:
		pid = value
	case int64:
		pid = int(value)
	}
	start, _ := endpoint["rootStart"].(string)
	return pid, start
}

// communicationFollowKind names a recorded change: a new conversation in the
// same process (/clear), a restarted agent under the same pane root, or only
// a refreshed process pin for the same conversation.
func communicationFollowKind(conversationChanged, processChanged bool) string {
	switch {
	case conversationChanged && processChanged:
		return "restart_followed"
	case conversationChanged:
		return "conversation_followed"
	}
	return "process_refreshed"
}
