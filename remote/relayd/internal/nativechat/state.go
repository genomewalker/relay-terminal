// Package nativechat owns structured conversations. Provider processes are owned
// by a host worker; views only observe that worker and submit explicit actions.
package nativechat

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

const MaxActionBytes = 128 << 10
const MaxFrameBytes = 24 << 20
const MaxItems = 256
const MaxItemBytes = 128 << 10
const MaxReceipts = 4096

type Identity struct {
	Pane     string `json:"pane"`
	Instance string `json:"instance"`
	Provider string `json:"provider"`
}

func (i Identity) Valid() bool {
	return validID(i.Pane) && validID(i.Instance) && (i.Provider == "codex" || i.Provider == "claude")
}
func validID(s string) bool {
	if len(s) == 0 || len(s) > 128 || s == "." || s == ".." {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune("-_.:", c)) {
			return false
		}
	}
	return true
}

type Item struct {
	ID        string `json:"id"`
	Role      string `json:"role"`
	Text      string `json:"text"`
	Tool      string `json:"tool,omitempty"`
	Status    string `json:"status,omitempty"`
	Sequence  uint64 `json:"sequence"`
	Truncated bool   `json:"truncated,omitempty"`
}
type Option struct {
	ID          string `json:"id"`
	Label       string `json:"label"`
	Description string `json:"description,omitempty"`
}
type Question struct {
	ID       string   `json:"id"`
	Header   string   `json:"header,omitempty"`
	Text     string   `json:"text"`
	Options  []Option `json:"options,omitempty"`
	Multiple bool     `json:"multiple,omitempty"`
	Secret   bool     `json:"secret,omitempty"`
}
type Request struct {
	ID         string          `json:"id"`
	Kind       string          `json:"kind"`
	TurnID     string          `json:"turnId"`
	Title      string          `json:"title"`
	Detail     string          `json:"detail"`
	Questions  []Question      `json:"questions,omitempty"`
	Responding bool            `json:"responding"`
	NativeID   json.RawMessage `json:"-"`
	Method     string          `json:"-"`
	ToolInput  json.RawMessage `json:"-"`
}
type Capabilities struct {
	InterruptScope string `json:"interruptScope"`
	Send           bool   `json:"send"`
	Steer          bool   `json:"steer"`
	Interrupt      bool   `json:"interrupt"`
	Respond        bool   `json:"respond"`
	// A CLI exit can prompt about provider-internal cron/scheduled work.
	// No adapter may infer an empty inventory from an empty OS child list.
	Maintenance       bool   `json:"maintenance"`
	ScheduledTasks    string `json:"scheduledTasks"`
	MaintenanceReason string `json:"maintenanceReason"`
}
type Snapshot struct {
	AccountRoot  string       `json:"accountRoot"`
	Version      int          `json:"version"`
	Identity     Identity     `json:"identity"`
	SessionID    string       `json:"sessionId"`
	TurnID       string       `json:"turnId"`
	CWD          string       `json:"cwd"`
	Model        string       `json:"model"`
	Phase        string       `json:"phase"`
	Revision     uint64       `json:"revision"`
	Items        []Item       `json:"items"`
	Requests     []Request    `json:"requests"`
	Capabilities Capabilities `json:"capabilities"`
	Failure      string       `json:"failure,omitempty"`
	TurnOutcome  string       `json:"turnOutcome,omitempty"`
	OlderBefore  uint64       `json:"olderBefore,omitempty"`
}
type Action struct {
	ID        string              `json:"id"`
	Identity  Identity            `json:"identity"`
	Kind      string              `json:"kind"`
	TurnID    string              `json:"turnId,omitempty"`
	Text      string              `json:"text,omitempty"`
	Images    []string            `json:"images,omitempty"`
	RequestID string              `json:"requestId,omitempty"`
	Decision  string              `json:"decision,omitempty"`
	Answers   map[string][]string `json:"answers,omitempty"`
}
type Receipt struct {
	ID     string `json:"id"`
	Digest string `json:"digest"`
	State  string `json:"state"`
	Detail string `json:"detail,omitempty"`
}

// State is mutated only under the worker's lock. Claim runs before a durable
// receipt is written and before provider I/O. Persist failure must roll it back.
type State struct {
	Held           bool
	ProviderBusy   bool
	View           Snapshot
	Receipts       map[string]Receipt
	Sequence       uint64
	Interrupting   string
	historyChanges []ItemUpdate
}
type ItemUpdate struct {
	Item  Item `json:"item"`
	Delta bool `json:"delta,omitempty"`
}

func NewState(identity Identity, cwd, model string) (*State, error) {
	if !identity.Valid() || !filepath.IsAbs(cwd) || strings.IndexByte(cwd, 0) >= 0 || len(cwd) > 4096 || len(model) > 256 {
		return nil, errors.New("invalid native conversation identity or configuration")
	}
	return &State{View: Snapshot{Version: 1, Identity: identity, CWD: cwd, Model: model, Phase: "starting", Items: []Item{}, Requests: []Request{}}, Receipts: map[string]Receipt{}}, nil
}
func (s *State) Snapshot() Snapshot {
	v := s.View
	v.Items = append([]Item{}, s.View.Items...)
	v.Requests = append([]Request{}, s.View.Requests...)
	scope := "turn"
	if v.Identity.Provider == "claude" {
		scope = "session"
	}
	v.Capabilities = Capabilities{
		InterruptScope: scope,
		Send:           v.Phase == "idle" && v.SessionID != "" && len(v.Requests) == 0 && !s.ProviderBusy,
		Interrupt:      (v.Phase == "running" || v.Phase == "waiting") && v.TurnID != "" && s.Interrupting != v.TurnID,
		Steer:          v.Identity.Provider == "codex" && v.Phase == "running" && v.TurnID != "" && len(v.Requests) == 0 && s.Interrupting != v.TurnID,
		Respond:        v.Phase != "exited" && v.Phase != "failed" && len(v.Requests) > 0,
		ScheduledTasks: "unknown", MaintenanceReason: "Provider scheduled-task inventory is unavailable; automatic retirement is held.",
	}
	if s.Held {
		v.Capabilities.Send = false
		v.Capabilities.Steer = false
		v.Capabilities.Interrupt = false
		v.Capabilities.Respond = false
		if v.Phase != "exited" {
			v.Phase = "held"
		}
	}
	return v
}
func (s *State) touch() { s.View.Revision++ }
func (s *State) Ready(session string) error {
	if !validID(session) {
		return errors.New("invalid provider session")
	}
	if s.View.SessionID != "" && s.View.SessionID != session {
		return errors.New("provider session changed")
	}
	s.View.SessionID = session
	if s.View.Phase == "starting" {
		s.View.Phase = "idle"
	}
	s.touch()
	return nil
}
func (s *State) Running(turn string) error {
	if !validID(turn) {
		return errors.New("invalid provider turn")
	}
	if s.View.Phase == "exited" || s.View.Phase == "failed" {
		return errors.New("provider is unavailable")
	}
	if s.View.TurnID != "" && s.View.TurnID != turn {
		return errors.New("unexpected concurrent provider turn")
	}
	s.View.TurnID = turn
	s.View.Phase = "running"
	s.View.TurnOutcome = ""
	s.touch()
	return nil
}
func (s *State) Complete(turn, status, detail string) error {
	if turn == "" || s.View.TurnID != turn {
		return errors.New("completion does not match active turn")
	}
	if status != "completed" && status != "interrupted" && status != "failed" {
		return errors.New("invalid completion status")
	}
	s.View.TurnID = ""
	s.Interrupting = ""
	s.View.TurnOutcome = status
	s.View.Phase = "idle"
	if len(s.View.Requests) > 0 {
		s.View.Phase = "waiting"
	}
	s.View.Failure = boundedDetail(detail)
	s.touch()
	return nil
}
func (s *State) Exit(detail string) {
	s.View.Phase = "exited"
	s.View.TurnID = ""
	s.View.Requests = []Request{}
	s.View.Failure = boundedDetail(detail)
	s.touch()
}
func (s *State) AddItem(item Item, delta bool) error {
	if !validID(item.ID) || (item.Role != "user" && item.Role != "assistant" && item.Role != "tool" && item.Role != "system" && item.Role != "reasoning") {
		return errors.New("invalid conversation item")
	}
	if !utf8.ValidString(item.Text) || len(item.Tool) > 512 || len(item.Status) > 64 {
		return errors.New("invalid conversation content")
	}
	for i := range s.View.Items {
		if s.View.Items[i].ID == item.ID {
			old := s.View.Items[i]
			if old.Role != item.Role {
				return errors.New("item role changed")
			}
			item.Sequence = old.Sequence
			if item.Tool == "" {
				item.Tool = old.Tool
			}
			if delta {
				item.Text = old.Text + item.Text
			}
			item.Truncated = item.Truncated || old.Truncated
			item = boundItem(item)
			record := item
			if delta {
				record.Text = item.Text[len(old.Text):]
			}
			s.View.Items[i] = item
			s.historyChanges = append(s.historyChanges, ItemUpdate{record, delta})
			s.touch()
			return nil
		}
	}
	s.Sequence++
	item.Sequence = s.Sequence
	item = boundItem(item)
	s.View.Items = append(s.View.Items, item)
	s.historyChanges = append(s.historyChanges, ItemUpdate{item, false})
	if len(s.View.Items) > MaxItems {
		s.View.Items = s.View.Items[len(s.View.Items)-MaxItems:]
		s.View.OlderBefore = s.View.Items[0].Sequence
	}
	s.touch()
	return nil
}
func boundItem(item Item) Item {
	if len(item.Text) > MaxItemBytes {
		n := MaxItemBytes
		for n > 0 && !utf8.RuneStart(item.Text[n]) {
			n--
		}
		item.Text = item.Text[:n]
		item.Truncated = true
	}
	return item
}
func (s *State) AddRequest(r Request) error {
	if !validID(r.ID) || (r.Kind != "approval" && r.Kind != "question") || len(r.Detail) > MaxItemBytes || len(r.Title) > 1024 || len(r.Questions) > 16 || len(s.View.Requests) >= 16 || !validID(r.TurnID) || s.View.SessionID == "" {
		return errors.New("invalid or unscoped provider request")
	}
	if s.View.Phase == "exited" || s.View.Phase == "failed" {
		return errors.New("provider is not accepting requests")
	}
	for _, old := range s.View.Requests {
		if old.ID == r.ID {
			return errors.New("duplicate provider request")
		}
	}
	for _, q := range r.Questions {
		if !validID(q.ID) || len(q.Text) > 16384 || len(q.Options) > 64 {
			return errors.New("invalid provider question")
		}
		seen := map[string]bool{}
		for _, o := range q.Options {
			if o.ID == "" || len(o.ID) > 4096 || len(o.Label) > 4096 || seen[o.ID] {
				return errors.New("invalid provider option")
			}
			seen[o.ID] = true
		}
	}
	encoded, _ := json.Marshal(r)
	if len(encoded) > 64<<10 {
		return errors.New("provider request is too large to display completely")
	}
	s.View.Requests = append(s.View.Requests, r)
	s.View.Phase = "waiting"
	s.touch()
	return nil
}
func (s *State) ResolveRequest(id string) {
	for i, r := range s.View.Requests {
		if r.ID == id {
			s.View.Requests = append(s.View.Requests[:i], s.View.Requests[i+1:]...)
			if len(s.View.Requests) == 0 {
				if s.View.TurnID == "" {
					s.View.Phase = "idle"
				} else {
					s.View.Phase = "running"
				}
			}
			s.touch()
			return
		}
	}
}
func (s *State) Claim(a Action) (Receipt, bool, error) {
	if !validID(a.ID) || a.Identity != s.View.Identity {
		return Receipt{}, false, errors.New("action belongs to another native conversation")
	}
	raw, err := json.Marshal(a)
	if err != nil || len(raw) > MaxActionBytes {
		return Receipt{}, false, errors.New("action exceeds size limit")
	}
	h := sha256.Sum256(raw)
	digest := hex.EncodeToString(h[:])
	if old, ok := s.Receipts[a.ID]; ok {
		if old.Digest != digest {
			return Receipt{}, false, errors.New("action ID already names different input")
		}
		return old, false, nil
	}
	if len(s.Receipts) >= MaxReceipts {
		return Receipt{}, false, errors.New("conversation action limit reached; explicitly resume in a new worker")
	}
	caps := s.Snapshot().Capabilities
	switch a.Kind {
	case "send":
		if !caps.Send || a.TurnID != "" || a.RequestID != "" || a.Decision != "" || len(a.Answers) != 0 || (strings.TrimSpace(a.Text) == "" && len(a.Images) == 0) || len(a.Text) > 65536 || !utf8.ValidString(a.Text) || strings.IndexByte(a.Text, 0) >= 0 || len(a.Images) > 4 {
			return Receipt{}, false, errors.New("conversation is not ready for this message")
		}
		for _, p := range a.Images {
			if !filepath.IsAbs(p) || len(p) > 4096 || strings.IndexByte(p, 0) >= 0 {
				return Receipt{}, false, errors.New("image must be an absolute host path")
			}
		}
		s.View.Phase = "starting"
	case "steer":
		if !caps.Steer || a.TurnID != s.View.TurnID || a.RequestID != "" || a.Decision != "" || len(a.Answers) != 0 || len(a.Images) != 0 || strings.TrimSpace(a.Text) == "" || len(a.Text) > 65536 || !utf8.ValidString(a.Text) || strings.IndexByte(a.Text, 0) >= 0 {
			return Receipt{}, false, errors.New("steering does not match an active Codex turn")
		}
	case "interrupt":
		if !caps.Interrupt || a.TurnID != s.View.TurnID || a.Text != "" || len(a.Images) != 0 || a.RequestID != "" || a.Decision != "" || len(a.Answers) != 0 {
			return Receipt{}, false, errors.New("interrupt does not match the active turn")
		}
		s.Interrupting = a.TurnID
	case "respond":
		if !caps.Respond || a.Text != "" || len(a.Images) != 0 {
			return Receipt{}, false, errors.New("response does not match the active turn")
		}
		index := -1
		for i, r := range s.View.Requests {
			if r.ID == a.RequestID {
				index = i
				break
			}
		}
		if index < 0 || s.View.Requests[index].Responding || a.TurnID != s.View.Requests[index].TurnID {
			return Receipt{}, false, errors.New("request is absent or already answered")
		}
		r := s.View.Requests[index]
		if r.Kind == "approval" {
			if (a.Decision != "allow" && a.Decision != "deny") || len(a.Answers) != 0 {
				return Receipt{}, false, errors.New("approval requires an explicit once-only decision")
			}
		} else {
			if a.Decision != "" || len(a.Answers) != len(r.Questions) {
				return Receipt{}, false, errors.New("answer every question")
			}
			for _, q := range r.Questions {
				answers, ok := a.Answers[q.ID]
				if !ok || len(answers) == 0 || len(answers) > 64 || (!q.Multiple && len(answers) != 1) {
					return Receipt{}, false, fmt.Errorf("invalid answer for %s", q.ID)
				}
				for _, answer := range answers {
					if strings.TrimSpace(answer) == "" || len(answer) > 16384 || !utf8.ValidString(answer) || strings.IndexByte(answer, 0) >= 0 {
						return Receipt{}, false, errors.New("invalid answer text")
					}
				}
			}
		}
		s.View.Requests[index].Responding = true
	default:
		return Receipt{}, false, errors.New("unsupported native action")
	}
	receipt := Receipt{ID: a.ID, Digest: digest, State: "claimed"}
	s.Receipts[a.ID] = receipt
	s.touch()
	return receipt, true, nil
}
func (s *State) RecordOutcome(id, state, detail string) error {
	r, ok := s.Receipts[id]
	if !ok {
		return errors.New("action was not claimed")
	}
	if state != "sent" && state != "uncertain" && state != "rejected" {
		return errors.New("invalid action outcome")
	}
	// A transport failure cannot authorize a retry under a new action ID.
	if r.State != "claimed" {
		return errors.New("action outcome already recorded")
	}
	if state == "uncertain" {
		s.Held = true
	}
	r.State = state
	r.Detail = boundedDetail(detail)
	s.Receipts[id] = r
	s.touch()
	return nil
}

func boundedDetail(text string) string {
	const limit = 8192
	if len(text) <= limit {
		return text
	}
	n := limit
	for n > 0 && !utf8.RuneStart(text[n]) {
		n--
	}
	return text[:n] + "\n[truncated]"
}
