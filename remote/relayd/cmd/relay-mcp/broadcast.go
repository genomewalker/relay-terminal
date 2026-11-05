package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

const (
	// broadcastLimit bounds one broadcast: auto-link's 8 agent panes less the
	// source. A larger scope is refused, never truncated.
	broadcastLimit = 7
	// broadcastBudget new broadcasts per source pane per broadcastWindow,
	// counted from saved manifests, so fresh broadcast IDs do not reset it.
	broadcastBudget = 6
	broadcastWindow = 10 * time.Minute
	// broadcastTTL is how long a broadcast_id can be retried.
	broadcastTTL = 24 * time.Hour
	// broadcastFiles bounds the manifests kept; past it new broadcasts are refused.
	broadcastFiles = 512
	// broadcastTextLimit leaves room for the envelope within relay_message_pane's 16384.
	broadcastTextLimit = 16000
	manifestLimit      = 64 << 10
)

// One pane as /api/state reports it. tab and workspace are the tab ID and
// the tab's navigator workspace ("" when ownership is unknown); grants are
// the broadcast scopes the user allowed for that tab in Relay's own menus.
type broadcastPane struct {
	tab, workspace string
	agent          bool
	grants         []string
}

type broadcastView struct {
	panes map[string]broadcastPane
	// peers maps each pane linked with the source to that link member's
	// conversation identity; "" when its links disagree.
	peers          map[string]string
	sourceIdentity string
}

// readBroadcastView parses /api/state and /api/pane-links, both untrusted.
// Anything ambiguous is refused or left ineligible: a malformed ID, a pane
// placed twice, or a source pane with more than one conversation.
func readBroadcastView(stateJSON, linksJSON []byte, source string) (broadcastView, error) {
	var state struct {
		Sessions []struct {
			Tabs []struct {
				ID          string   `json:"id"`
				WorkspaceID string   `json:"workspaceID"`
				Broadcast   []string `json:"broadcast"`
				Panes       []struct {
					ID          string `json:"id"`
					Agent       string `json:"agent"`
					ContentKind string `json:"contentKind"`
				} `json:"panes"`
			} `json:"tabs"`
		} `json:"sessions"`
	}
	type member struct {
		PaneID    string `json:"paneID"`
		HostID    string `json:"hostID"`
		Provider  string `json:"provider"`
		SessionID string `json:"sessionID"`
		PID       int64  `json:"pid"`
		Start     string `json:"start"`
	}
	var links struct {
		Links []struct {
			Members []member `json:"members"`
		} `json:"links"`
	}
	if json.Unmarshal(stateJSON, &state) != nil || json.Unmarshal(linksJSON, &links) != nil {
		return broadcastView{}, errors.New("Relay returned an unreadable workspace or link list")
	}
	view := broadcastView{panes: map[string]broadcastPane{}, peers: map[string]string{}}
	for _, session := range state.Sessions {
		for _, tab := range session.Tabs {
			tabID, workspace := strings.ToLower(tab.ID), strings.ToLower(tab.WorkspaceID)
			if !paneID.MatchString(tabID) || (workspace != "" && !paneID.MatchString(workspace)) {
				return broadcastView{}, errors.New("Relay returned a malformed tab or workspace ID")
			}
			for _, pane := range tab.Panes {
				id := strings.ToLower(pane.ID)
				if !paneID.MatchString(id) {
					return broadcastView{}, errors.New("Relay returned a malformed pane ID")
				}
				if _, twice := view.panes[id]; twice {
					return broadcastView{}, fmt.Errorf("pane %s appears more than once in the workspace", id)
				}
				view.panes[id] = broadcastPane{tab: tabID, workspace: workspace, grants: tab.Broadcast,
					agent: (pane.Agent == "claude" || pane.Agent == "codex") && (pane.ContentKind == "" || pane.ContentKind == "terminal")}
			}
		}
	}
	if _, ok := view.panes[source]; !ok {
		return broadcastView{}, errors.New("the source pane is not in the workspace")
	}
	identity := func(m member) string {
		if m.SessionID == "" || m.Provider == "" {
			return ""
		}
		return fmt.Sprintf("%s/%s/%s/%d/%s", m.HostID, m.Provider, m.SessionID, m.PID, m.Start)
	}
	sources := map[string]bool{}
	for _, link := range links.Links {
		if len(link.Members) != 2 {
			continue
		}
		for i := 0; i < 2; i++ {
			self, peer := link.Members[i], link.Members[1-i]
			a, b := strings.ToLower(self.PaneID), strings.ToLower(peer.PaneID)
			if a != source || b == source {
				continue
			}
			sources[identity(self)] = true
			id := identity(peer)
			if seen, ok := view.peers[b]; ok && seen != id {
				id = ""
			}
			view.peers[b] = id
		}
	}
	if len(sources) > 1 || sources[""] {
		return broadcastView{}, errors.New("the source pane's links name more than one conversation")
	}
	for id := range sources {
		view.sourceIdentity = id
	}
	return view, nil
}

// scopeID names the exact tab or workspace a pane is in for scope; "" when
// the pane is absent or its workspace is unknown.
func (v broadcastView) scopeID(id, scope string) string {
	p, ok := v.panes[id]
	switch {
	case !ok:
		return ""
	case scope == "tab":
		return "tab:" + p.tab
	case p.workspace == "":
		return ""
	}
	return "workspace:" + p.workspace
}

func (v broadcastView) allowed(source, scope string) bool {
	for _, grant := range v.panes[source].grants {
		if grant == scope {
			return true
		}
	}
	return false
}

type broadcastRecipient struct {
	PaneID    string `json:"pane_id"`
	Identity  string `json:"identity"`
	MessageID string `json:"message_id"`
	// State is pending, sent, failed (retry resends the same message ID) or
	// held (the scope, link or conversation changed; never sent by this ID).
	State  string          `json:"state"`
	Detail json.RawMessage `json:"detail,omitempty"`
}

// broadcastManifest is written before the first send. A retry of the same
// broadcast_id reads it and never replans: no recipient is ever added.
type broadcastManifest struct {
	Version        int                  `json:"version"`
	ID             string               `json:"id"`
	Source         string               `json:"source"`
	SourceIdentity string               `json:"source_identity"`
	Scope          string               `json:"scope"`
	ScopeID        string               `json:"scope_id"`
	Digest         string               `json:"digest"`
	Created        time.Time            `json:"created"`
	Expires        time.Time            `json:"expires"`
	Recipients     []broadcastRecipient `json:"recipients"`
	Skipped        map[string]string    `json:"skipped"`
}

// planBroadcast chooses the Claude/Codex terminal panes in the source's exact
// tab or navigator workspace that have a saved link with the source, in a
// scope where the user allowed broadcast.
func planBroadcast(stateJSON, linksJSON []byte, source, scope, broadcastID string) (broadcastManifest, error) {
	source = strings.ToLower(source)
	if !paneID.MatchString(source) || !paneID.MatchString(broadcastID) || (scope != "tab" && scope != "workspace") {
		return broadcastManifest{}, errors.New("an exact source pane, broadcast ID and scope tab or workspace are required")
	}
	view, err := readBroadcastView(stateJSON, linksJSON, source)
	if err != nil {
		return broadcastManifest{}, err
	}
	scopeID := view.scopeID(source, scope)
	if scopeID == "" {
		return broadcastManifest{}, errors.New("the source tab's workspace is unknown, so a workspace broadcast is refused")
	}
	if !view.allowed(source, scope) {
		return broadcastManifest{}, fmt.Errorf("broadcast is not allowed in this %s; only the user can allow it, from the %s's menu in Relay", scope, scope)
	}
	m := broadcastManifest{Version: 1, ID: strings.ToLower(broadcastID), Source: source, SourceIdentity: view.sourceIdentity,
		Scope: scope, ScopeID: scopeID, Recipients: []broadcastRecipient{}, Skipped: map[string]string{}}
	for id, pane := range view.panes {
		if id == source || !pane.agent || view.scopeID(id, scope) != scopeID {
			continue
		}
		identity, linked := view.peers[id]
		switch {
		case !linked:
			m.Skipped[id] = "not linked with the source pane"
		case identity == "":
			m.Skipped[id] = "its links name no single conversation"
		default:
			m.Recipients = append(m.Recipients, broadcastRecipient{PaneID: id, Identity: identity, MessageID: broadcastMessageID(m.ID, id), State: "pending"})
		}
	}
	sort.Slice(m.Recipients, func(i, j int) bool { return m.Recipients[i].PaneID < m.Recipients[j].PaneID })
	if len(m.Recipients) > broadcastLimit {
		return broadcastManifest{}, fmt.Errorf("%d linked recipients; one broadcast reaches at most %d", len(m.Recipients), broadcastLimit)
	}
	return m, nil
}

// recheck says why one recipient may no longer receive this broadcast, or "".
func recheck(view broadcastView, m *broadcastManifest, r broadcastRecipient) string {
	pane, ok := view.panes[r.PaneID]
	switch {
	case !view.allowed(m.Source, m.Scope):
		return "broadcast is no longer allowed in this " + m.Scope
	case view.scopeID(m.Source, m.Scope) != m.ScopeID:
		return "the source pane left the " + m.Scope
	case view.sourceIdentity != m.SourceIdentity:
		return "the source pane's conversation changed"
	case !ok:
		return "the recipient pane is gone"
	case view.scopeID(r.PaneID, m.Scope) != m.ScopeID:
		return "the recipient left the " + m.Scope
	case !pane.agent:
		return "the recipient is no longer an agent terminal"
	case view.peers[r.PaneID] != r.Identity:
		return "the recipient's link or conversation changed"
	}
	return ""
}

// decodeManifest reads a manifest written by another process and accepts it
// only when every field is consistent with the broadcast it names.
func decodeManifest(data []byte, id string) (broadcastManifest, error) {
	var m broadcastManifest
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	bad := errors.New("the saved record of this broadcast is unreadable")
	if len(data) > manifestLimit || decoder.Decode(&m) != nil || decoder.Decode(&struct{}{}) != io.EOF {
		return broadcastManifest{}, bad
	}
	digest, err := hex.DecodeString(m.Digest)
	ok := m.Version == 1 && m.ID == strings.ToLower(id) && paneID.MatchString(m.ID) && m.Source == strings.ToLower(m.Source) &&
		paneID.MatchString(m.Source) && (m.Scope == "tab" || m.Scope == "workspace") &&
		strings.HasPrefix(m.ScopeID, m.Scope+":") && paneID.MatchString(strings.TrimPrefix(m.ScopeID, m.Scope+":")) &&
		err == nil && len(digest) == sha256.Size && m.Digest == strings.ToLower(m.Digest) &&
		m.Expires.After(m.Created) && !m.Expires.After(m.Created.Add(broadcastTTL)) &&
		len(m.Recipients) <= broadcastLimit && m.Skipped != nil
	for i, r := range m.Recipients {
		ok = ok && paneID.MatchString(r.PaneID) && r.PaneID == strings.ToLower(r.PaneID) && r.PaneID != m.Source &&
			(i == 0 || m.Recipients[i-1].PaneID < r.PaneID) && r.Identity != "" && r.MessageID == broadcastMessageID(m.ID, r.PaneID) &&
			(r.State == "pending" || r.State == "sent" || r.State == "failed" || r.State == "held")
	}
	if !ok {
		return broadcastManifest{}, bad
	}
	return m, nil
}

// broadcastStore keeps manifests; the lock admits one broadcast at a time
// on this host, across MCP clients and restarts.
type broadcastStore interface {
	lock() (func(), error)
	load(id string) ([]byte, error) // fs.ErrNotExist when absent
	create(id string, data []byte) error
	save(id string, data []byte) error
	all() (map[string][]byte, error)
	remove(id string) error
}

// errBroadcastBusy is the only lock failure that means another broadcast
// holds the lock; any other (ENOLCK on a network home, say) is reported as is.
var errBroadcastBusy = errors.New("another broadcast holds the lock")

// lockFailure maps a flock error: only "would block" is contention.
func lockFailure(err error) error {
	if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
		return errBroadcastBusy
	}
	return err
}

type fileBroadcastStore struct{ dir string }

func defaultBroadcastStore() broadcastStore {
	return fileBroadcastStore{filepath.Join(os.Getenv("HOME"), ".local", "share", "relay", "broadcasts")}
}

func (s fileBroadcastStore) path(id string) string {
	return filepath.Join(s.dir, strings.ToLower(id)+".json")
}

func (s fileBroadcastStore) lock() (func(), error) {
	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(filepath.Join(s.dir, ".lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		return nil, lockFailure(err)
	}
	return func() { syscall.Flock(int(file.Fd()), syscall.LOCK_UN); file.Close() }, nil
}

func (s fileBroadcastStore) load(id string) ([]byte, error) {
	file, err := os.Open(s.path(id))
	if err != nil {
		return nil, err
	}
	defer file.Close()
	return io.ReadAll(io.LimitReader(file, manifestLimit+1))
}

// write puts data in a temporary file first, so a reader never sees half a
// manifest; create refuses an existing one.
func (s fileBroadcastStore) write(id string, data []byte, replace bool) error {
	temp, err := os.CreateTemp(s.dir, ".manifest-*")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	if _, err := temp.Write(data); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if replace {
		return os.Rename(temp.Name(), s.path(id))
	}
	return os.Link(temp.Name(), s.path(id))
}

func (s fileBroadcastStore) create(id string, data []byte) error { return s.write(id, data, false) }
func (s fileBroadcastStore) save(id string, data []byte) error   { return s.write(id, data, true) }
func (s fileBroadcastStore) remove(id string) error              { return os.Remove(s.path(id)) }

func (s fileBroadcastStore) all() (map[string][]byte, error) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return nil, err
	}
	result := map[string][]byte{}
	for _, entry := range entries {
		id, ok := strings.CutSuffix(entry.Name(), ".json")
		if !ok || !paneID.MatchString(id) {
			continue
		}
		if len(result) == broadcastFiles {
			return nil, errors.New("too many saved broadcasts on this host")
		}
		if result[id], err = s.load(id); err != nil {
			return nil, err
		}
	}
	return result, nil
}

// broadcastMessageID derives each recipient's stable message UUID, so a
// repeated broadcast_id resends nothing new: relayd deduplicates by message ID.
func broadcastMessageID(broadcastID, target string) string {
	sum := sha256.Sum256([]byte("relay-broadcast-v1\x00" + strings.ToLower(broadcastID) + "\x00" + strings.ToLower(target)))
	b := sum[:16]
	b[6] = b[6]&0x0f | 0x80
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func resultText(result any) (string, bool) {
	table, ok := result.(map[string]any)
	if !ok {
		return "", false
	}
	content, ok := table["content"].([]any)
	if !ok || len(content) == 0 {
		return "", false
	}
	first, ok := content[0].(map[string]string)
	if !ok {
		return "", false
	}
	failed, _ := table["isError"].(bool)
	return first["text"], !failed
}

func (s *server) callTool(name string, arguments map[string]any) (string, bool) {
	params, _ := json.Marshal(map[string]any{"name": name, "arguments": arguments})
	result, code, detail := s.handle(request{JSONRPC: "2.0", ID: json.RawMessage("1"), Method: "tools/call", Params: params})
	if code != 0 {
		return detail, false
	}
	return resultText(result)
}

type broadcastCaller func(name string, arguments map[string]any) (string, bool)

// broadcast sends one relay_message_pane per recipient through the ordinary
// tool path, so each delivery keeps its own proof, grant and receipt checks.
func (s *server) broadcast(arguments map[string]json.RawMessage) (any, int, string) {
	var source, scope, id, text string
	if len(arguments) != 4 || json.Unmarshal(arguments["source_pane_id"], &source) != nil || !paneID.MatchString(source) ||
		json.Unmarshal(arguments["scope"], &scope) != nil || (scope != "tab" && scope != "workspace") ||
		json.Unmarshal(arguments["broadcast_id"], &id) != nil || !paneID.MatchString(id) ||
		json.Unmarshal(arguments["text"], &text) != nil || len(text) == 0 || len(text) > broadcastTextLimit || strings.TrimSpace(text) == "" {
		return nil, -32602, fmt.Sprintf("Exact source_pane_id, scope tab or workspace, broadcast_id UUID and 1-%d bytes of text required", broadcastTextLimit)
	}
	body, failed := runBroadcast(strings.ToLower(source), scope, strings.ToLower(id), text, s.callTool, defaultBroadcastStore(), time.Now().UTC())
	return toolText(body, failed), 0, ""
}

func jsonText(text string) json.RawMessage {
	raw, _ := json.Marshal(text)
	return raw
}

// runBroadcast plans (or, for a known broadcast_id, reloads) the manifest,
// then sends to each recipient still pending or failed after rechecking it.
// The first recipient whose scope, link or conversation changed halts the
// rest: they are held, not sent.
func runBroadcast(source, scope, id, text string, call broadcastCaller, store broadcastStore, now time.Time) (string, bool) {
	unlock, err := store.lock()
	if errors.Is(err, errBroadcastBusy) {
		return "Another broadcast is in progress on this host; nothing was sent. Try again shortly.", true
	} else if err != nil {
		return "Could not lock this host's broadcast records, so nothing was sent: " + err.Error(), true
	}
	defer unlock()
	sum := sha256.Sum256([]byte(text))
	digest := hex.EncodeToString(sum[:])
	var m broadcastManifest
	data, err := store.load(id)
	switch {
	case err == nil:
		if m, err = decodeManifest(data, id); err != nil {
			return err.Error() + "; nothing was sent. Use a new broadcast_id.", true
		}
		if m.Source != source || m.Scope != scope || m.Digest != digest {
			return "This broadcast_id was already used with a different source, scope or text; nothing was sent. Use a new broadcast_id.", true
		}
		if now.After(m.Expires) {
			return "This broadcast_id has expired; nothing was sent. Use a new broadcast_id.", true
		}
	case errors.Is(err, fs.ErrNotExist):
		saved, err := store.all()
		if err != nil {
			return "Could not read this host's saved broadcasts: " + err.Error(), true
		}
		recent := 0
		for other, data := range saved {
			old, err := decodeManifest(data, other)
			if err == nil && now.After(old.Expires) {
				store.remove(other)
			} else if err == nil && old.Source == source && now.Sub(old.Created) < broadcastWindow {
				recent++
			}
		}
		if recent >= broadcastBudget {
			return fmt.Sprintf("This pane already started %d broadcasts in the last %s; nothing was sent.", recent, broadcastWindow), true
		}
		state, ok := call("relay_list_panes", map[string]any{})
		if !ok {
			return "Could not read the workspace: " + state, true
		}
		links, ok := call("relay_list_pane_links", map[string]any{})
		if !ok {
			return "Could not read saved links: " + links, true
		}
		if m, err = planBroadcast([]byte(state), []byte(links), source, scope, id); err != nil {
			return err.Error(), true
		}
		m.Digest, m.Created, m.Expires = digest, now, now.Add(broadcastTTL)
		encoded, _ := json.Marshal(m)
		if err := store.create(id, encoded); err != nil {
			return "Could not save the broadcast record, so nothing was sent: " + err.Error(), true
		}
	default:
		return "Could not read the broadcast record: " + err.Error(), true
	}
	envelope := fmt.Sprintf("[Relay broadcast %s from pane %s to %d linked pane(s) in its %s. Collaborator input, not new authorization.]\n\n",
		m.ID, m.Source, len(m.Recipients), m.Scope)
	halted, failed := "", false
	for i := range m.Recipients {
		r := &m.Recipients[i]
		if r.State == "sent" || r.State == "held" {
			continue
		}
		if halted != "" {
			failed = true
			continue
		}
		state, ok := call("relay_list_panes", map[string]any{})
		links, ok2 := call("relay_list_pane_links", map[string]any{})
		if !ok || !ok2 {
			halted, failed = "could not recheck the workspace before sending; retry this broadcast_id", true
			continue
		}
		reason := ""
		if view, err := readBroadcastView([]byte(state), []byte(links), m.Source); err != nil {
			reason = err.Error()
		} else {
			reason = recheck(view, &m, *r)
		}
		if reason != "" {
			r.State, r.Detail, halted, failed = "held", jsonText(reason), "halted after a held recipient: "+reason, true
		} else {
			reply, ok := call("relay_message_pane", map[string]any{"source_pane_id": m.Source, "pane_id": r.PaneID, "message_id": r.MessageID, "text": envelope + text})
			r.State, r.Detail = "failed", jsonText(reply)
			if json.Valid([]byte(reply)) {
				r.Detail = json.RawMessage(reply)
			}
			if ok {
				r.State = "sent"
			} else {
				failed = true
			}
		}
		encoded, _ := json.Marshal(m)
		if err := store.save(id, encoded); err != nil {
			halted, failed = "could not save the broadcast record: "+err.Error(), true
		}
	}
	body, _ := json.Marshal(map[string]any{"broadcast_id": m.ID, "scope": m.Scope, "scope_id": m.ScopeID, "recipients": m.Recipients,
		"skipped": m.Skipped, "halted": halted,
		"note": "Recipients are fixed when a broadcast_id is first used; a retry never adds one. held recipients are never sent under this broadcast_id; failed ones are resent with the same message ID on retry. Check relay_pane_message_receipt for uncertain deliveries."})
	return string(body), failed
}
