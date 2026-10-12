package daemon

import (
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const communicationMaxGroups = 256
const communicationMaxGroupMembers = 32

type communicationGroup struct {
	Version       int                        `json:"version"`
	ID            string                     `json:"id"`
	NodeID        string                     `json:"node_id"`
	Name          string                     `json:"name"`
	OwnerClientID string                     `json:"owner_client_id"`
	Members       []string                   `json:"member_pane_ids"`
	MemberRefs    []CommunicationGroupMember `json:"members,omitempty"`
	Revision      uint64                     `json:"revision"`
	Retired       bool                       `json:"retired"`
	CreatedAt     time.Time                  `json:"created_at"`
	UpdatedAt     time.Time                  `json:"updated_at"`
}

func validCommunicationGroup(group communicationGroup, nodeID string) bool {
	if group.Version == 2 {
		return validQualifiedCommunicationGroup(group, nodeID)
	}
	if group.Version != 1 || group.NodeID != nodeID || !validSessionID.MatchString(group.ID) ||
		!validSessionID.MatchString(group.OwnerClientID) || group.OwnerClientID != strings.ToLower(group.OwnerClientID) || group.ID != strings.ToLower(group.ID) || group.Revision == 0 ||
		len(group.Members) < 2 || len(group.Members) > communicationMaxGroupMembers ||
		!validCommunicationGroupName(group.Name) {
		return false
	}
	seen := map[string]bool{}
	for _, pane := range group.Members {
		if !validSessionID.MatchString(pane) || pane != strings.ToLower(pane) || seen[pane] {
			return false
		}
		seen[pane] = true
	}
	return true
}
func validCommunicationGroupName(name string) bool {
	if !utf8.ValidString(name) || len(name) > 120 || strings.TrimSpace(name) == "" {
		return false
	}
	for _, c := range name {
		if unicode.IsControl(c) {
			return false
		}
	}
	return true
}
func communicationGroupResult(group communicationGroup) map[string]any {
	return map[string]any{"group": group, "authority": "relayd", "desktop_required": false}
}

// Caller authorization and the daemon's communication flock precede this
// reducer. Group metadata neither resolves native sockets nor delivers input.
func communicationGroupOperation(root, nodeID string, r CommunicationRequest, known map[string]string) (map[string]any, error) {
	if nodeID == "" {
		return nil, errors.New("daemon node identity unavailable")
	}
	if r.Operation == "group_receipt" {
		if !validSessionID.MatchString(r.MessageID) {
			return nil, errors.New("valid group message identity required")
		}
		var receipt communicationFanoutReceipt
		if err := communicationRead(communicationFanoutPath(root, strings.ToLower(r.MessageID)), &receipt); err != nil {
			return nil, err
		}
		if receipt.NodeID != nodeID || receipt.GroupID != strings.ToLower(r.GroupID) {
			return nil, errors.New("group receipt scope mismatch")
		}
		receipt, err := communicationRefreshFanout(root, nodeID, receipt)
		if err != nil {
			return nil, err
		}
		return communicationFanoutResult(receipt), nil
	}
	if r.Operation == "group_list" {
		paths, err := filepath.Glob(filepath.Join(root, "group-*.json"))
		if err != nil {
			return nil, err
		}
		if len(paths) > communicationMaxGroups {
			return nil, errors.New("group catalogue exceeds limit")
		}
		groups := []communicationGroup{}
		for _, path := range paths {
			var group communicationGroup
			if err := communicationRead(path, &group); err != nil {
				return nil, err
			}
			if !validCommunicationGroup(group, nodeID) || filepath.Base(path) != "group-"+group.ID+".json" {
				return nil, errors.New("invalid stored communication group")
			}
			groups = append(groups, group)
		}
		return map[string]any{"groups": groups, "authority": "relayd", "desktop_required": false}, nil
	}
	id := strings.ToLower(r.GroupID)
	if !validSessionID.MatchString(id) {
		return nil, errors.New("valid group identity required")
	}
	path := filepath.Join(root, "group-"+id+".json")
	var previous communicationGroup
	readErr := communicationRead(path, &previous)
	exists := readErr == nil
	if readErr != nil && !errors.Is(readErr, os.ErrNotExist) {
		return nil, readErr
	}
	if exists && (!validCommunicationGroup(previous, nodeID) || previous.ID != id) {
		return nil, errors.New("invalid stored communication group")
	}
	switch r.Operation {
	case "group_get":
		if !exists {
			return nil, errors.New("communication group not found")
		}
		return communicationGroupResult(previous), nil
	case "group_set", "group_retire":
		if !validSessionID.MatchString(r.ClientID) || r.ClientID != strings.ToLower(r.ClientID) {
			return nil, errors.New("authenticated group owner required")
		}
		if exists && previous.OwnerClientID != r.ClientID {
			return nil, errors.New("communication group belongs to another caller")
		}
		if (!exists && r.ExpectedGroupRevision != 0) || (exists && r.ExpectedGroupRevision != previous.Revision) {
			return nil, errors.New("communication group revision conflict")
		}
		if exists && previous.Revision == math.MaxUint64 {
			return nil, errors.New("communication group revision exhausted")
		}
	default:
		return nil, errors.New("unknown communication group operation")
	}
	if r.Operation == "group_retire" {
		if !exists {
			return nil, errors.New("communication group not found")
		}
		if r.ActorPaneID != "" && !communicationGroupHasMember(previous, nodeID, strings.ToLower(r.ActorPaneID)) {
			return nil, errors.New("caller pane is not a group member")
		}
		previous.Retired = true
		previous.Revision++
		previous.UpdatedAt = time.Now().UTC()
		if err := communicationAtomic(path, previous); err != nil {
			return nil, err
		}
		if err := communicationEvent(root, nodeID, "communication_group_retired", []map[string]string{{"from": id, "to": "retired", "kind": "group"}}); err != nil {
			return nil, err
		}
		return communicationGroupResult(previous), nil
	}
	if r.GroupMembers != nil {
		return communicationQualifiedGroupSet(root, nodeID, r, known, previous, exists)
	}
	if !validCommunicationGroupName(r.GroupName) || len(r.MemberPaneIDs) < 2 || len(r.MemberPaneIDs) > communicationMaxGroupMembers {
		return nil, errors.New("valid group name and two to thirty-two members required")
	}
	members := make([]string, len(r.MemberPaneIDs))
	seen := map[string]bool{}
	for i, pane := range r.MemberPaneIDs {
		pane = strings.ToLower(pane)
		if !validSessionID.MatchString(pane) || seen[pane] {
			return nil, errors.New("invalid or duplicate group member")
		}
		if _, ok := known[pane]; !ok {
			return nil, errors.New("group member is not in this daemon's catalogue; remote membership requires a server route")
		}
		seen[pane], members[i] = true, pane
	}
	if r.ActorPaneID != "" && !seen[strings.ToLower(r.ActorPaneID)] {
		return nil, errors.New("caller pane must remain a group member")
	}
	sort.Strings(members)
	if !exists {
		paths, err := filepath.Glob(filepath.Join(root, "group-*.json"))
		if err != nil {
			return nil, err
		}
		if len(paths) >= communicationMaxGroups {
			return nil, errors.New("communication group limit reached")
		}
	}
	now := time.Now().UTC()
	created := now
	if exists {
		created = previous.CreatedAt
	}
	group := communicationGroup{Version: 1, ID: id, NodeID: nodeID, Name: strings.TrimSpace(r.GroupName),
		OwnerClientID: r.ClientID, Members: members, Revision: previous.Revision + 1, CreatedAt: created, UpdatedAt: now}
	if err := communicationAtomic(path, group); err != nil {
		return nil, err
	}
	links := make([]map[string]string, 0, len(members))
	for _, pane := range members {
		links = append(links, map[string]string{"from": id, "to": pane, "kind": "group_member"})
	}
	if err := communicationEvent(root, nodeID, "communication_group_saved", links); err != nil {
		return nil, fmt.Errorf("group saved but event receipt failed: %w", err)
	}
	return communicationGroupResult(group), nil
}
func containsCommunicationPane(members []string, pane string) bool {
	for _, candidate := range members {
		if candidate == pane {
			return true
		}
	}
	return false
}
