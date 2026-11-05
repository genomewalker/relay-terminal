package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Exhaustive bounded check of relay_broadcast_message against the real
// runBroadcast, planBroadcast, recheck and manifest code, with an in-memory
// store and fake Relay documents (trusted: memStore, mWorld's JSON).
//
// World: source pane P0 and panes P1, P2 in tabs T0/T1; both tabs may be
// owned by workspace W. Steps are environment events (move a pane, replace
// P2's conversation, unlink P1, revoke a grant, change ownership, fail the
// next delivery) and broadcast calls (tab or workspace scope, two texts, one
// broadcast ID). A call may have one event injected before any of its tool
// calls; the injected event may be a second actor's identical call, which
// runs while the first holds the lock. Properties, checked at every delivery
// and after every step:
//   - manifest: every delivery goes to a recipient fixed when the ID was
//     first used, and a saved manifest never gains or changes a recipient;
//   - fresh: the recheck just before each delivery saw the recipient linked
//     with the source, holding the conversation it held at planning, in the
//     same exact scope, with the user's grant for that scope present;
//   - pinned: at the delivery itself the recipient is still linked and holds
//     that conversation (the fake relay_message_pane refuses otherwise, as
//     relayd revalidates its saved pins; trusted, not checked here).
//   - once: no message ID is admitted twice;
//   - text: only the text the ID was first used with is ever delivered;
//   - lock: a second actor's call during a broadcast sends nothing.
//
// A move or grant change after the recheck and before the send is outside
// relay-mcp's reach; such deliveries are counted and reported, not hidden.
type mWorld struct {
	Tab      [3]int // tab of each pane; P0 never moves
	Gen      [3]int // conversation generation
	Linked   [3]bool
	Grant    [2]uint8 // per tab: 1 tab, 2 workspace
	Owned    [2]bool
	FailNext bool
}

var mPanes = [3]string{
	"aaaaaaaa-0000-4000-8000-0000000000a0", "aaaaaaaa-0000-4000-8000-0000000000a1", "aaaaaaaa-0000-4000-8000-0000000000a2"}
var mTabs = [2]string{"cccccccc-0000-4000-8000-0000000000c0", "cccccccc-0000-4000-8000-0000000000c1"}

const mWorkspace = "dddddddd-0000-4000-8000-0000000000d0"
const mID = "bbbbbbbb-0000-4000-8000-0000000000b0"

func (w mWorld) state() string {
	var tabs []any
	for t := 0; t < 2; t++ {
		var panes []any
		for p := 0; p < 3; p++ {
			if w.Tab[p] == t {
				panes = append(panes, map[string]string{"id": mPanes[p], "agent": "codex", "contentKind": "terminal"})
			}
		}
		var grants []string
		if w.Grant[t]&1 != 0 {
			grants = append(grants, "tab")
		}
		if w.Grant[t]&2 != 0 {
			grants = append(grants, "workspace")
		}
		tab := map[string]any{"id": mTabs[t], "broadcast": grants, "panes": panes}
		if w.Owned[t] {
			tab["workspaceID"] = mWorkspace
		}
		tabs = append(tabs, tab)
	}
	data, _ := json.Marshal(map[string]any{"sessions": []any{map[string]any{"tabs": tabs}}})
	return string(data)
}

func (w mWorld) identity(p int) string {
	return "h/codex/conv-" + strconv.Itoa(p) + "-" + strconv.Itoa(w.Gen[p]) + "/1/s"
}

func (w mWorld) links() string {
	member := func(p int) map[string]any {
		return map[string]any{"paneID": mPanes[p], "hostID": "h", "provider": "codex", "sessionID": "conv-" + strconv.Itoa(p) + "-" + strconv.Itoa(w.Gen[p]), "pid": 1, "start": "s"}
	}
	var links []any
	for p := 1; p < 3; p++ {
		if w.Linked[p] {
			links = append(links, map[string]any{"members": []any{member(0), member(p)}})
		}
	}
	data, _ := json.Marshal(map[string]any{"links": links})
	return string(data)
}

// oracleScope is the exact scope a pane is in, computed from the world
// directly rather than through the code under test.
func (w mWorld) oracleScope(p int, scope string) string {
	if scope == "tab" {
		return "tab:" + mTabs[w.Tab[p]]
	}
	if !w.Owned[w.Tab[p]] {
		return ""
	}
	return "workspace:" + mWorkspace
}

func (w mWorld) granted(scope string) bool {
	bit := uint8(1)
	if scope == "workspace" {
		bit = 2
	}
	return w.Grant[w.Tab[0]]&bit != 0 && w.oracleScope(0, scope) != ""
}

type mPlanned struct {
	scope, scopeID, text string
	identity             map[string]string
}

// mState is everything that persists between steps.
type mState struct {
	World    mWorld
	Files    string // the manifest, or ""
	Admitted string // sorted admitted message IDs
	Planned  string // ghost: what the ID was first planned with
}

const mEvents = 10

func (w *mWorld) apply(event int) {
	switch event {
	case 0:
		w.Tab[1] = 1 - w.Tab[1]
	case 1:
		w.Tab[2] = 1 - w.Tab[2]
	case 2:
		w.Gen[2] = 1 - w.Gen[2]
	case 3:
		w.Linked[1] = !w.Linked[1]
	case 4:
		w.Grant[0] ^= 1
	case 5:
		w.Grant[0] ^= 2
	case 6:
		w.Owned[0] = !w.Owned[0]
	case 7:
		w.Owned[1] = !w.Owned[1]
	case 8:
		w.FailNext = !w.FailNext
	}
}

type mCall struct{ scope, text string }

var mCalls = []mCall{{"tab", "p"}, {"workspace", "p"}, {"tab", "q"}}

const mMaxToolCalls = 8

type mStep struct {
	event, call, injectAt, injected int // call < 0: event only; injectAt < 0: none
}

func (s mStep) String() string {
	if s.call < 0 {
		return fmt.Sprintf("event %d", s.event)
	}
	if s.injectAt < 0 {
		return fmt.Sprintf("call %v", mCalls[s.call])
	}
	return fmt.Sprintf("call %v with event %d before tool call %d", mCalls[s.call], s.injected, s.injectAt)
}

// run applies one step and returns the next state or a violation.
func mRun(from mState, step mStep, now time.Time) (mState, string, int) {
	w := from.World
	if step.call < 0 {
		w.apply(step.event)
		return mState{w, from.Files, from.Admitted, from.Planned}, "", 0
	}
	store := newMemStore()
	if from.Files != "" {
		store.files[mID] = []byte(from.Files)
	}
	var planned *mPlanned
	if from.Planned != "" {
		planned = &mPlanned{}
		parts := strings.Split(from.Planned, "|")
		planned.scope, planned.scopeID, planned.text = parts[0], parts[1], parts[2]
		planned.identity = map[string]string{}
		for _, kv := range parts[3:] {
			if k, v, ok := strings.Cut(kv, "="); ok {
				planned.identity[k] = v
			}
		}
	}
	admitted := map[string]bool{}
	for _, id := range strings.Fields(from.Admitted) {
		admitted[id] = true
	}
	violation := ""
	fail := func(format string, args ...any) {
		if violation == "" {
			violation = fmt.Sprintf(format, args...)
		}
	}
	call := mCalls[step.call]
	store.onSave = func(id string, data []byte, created bool) {
		m, err := decodeManifest(data, id)
		if err != nil {
			fail("manifest: saved an unreadable manifest: %v", err)
			return
		}
		if created {
			if planned != nil {
				fail("manifest: created twice")
			}
			planned = &mPlanned{scope: m.Scope, scopeID: m.ScopeID, text: call.text, identity: map[string]string{}}
			for _, r := range m.Recipients {
				planned.identity[r.PaneID] = r.Identity
			}
			return
		}
		if planned == nil || len(m.Recipients) != len(planned.identity) || m.Scope != planned.scope || m.ScopeID != planned.scopeID {
			fail("manifest: a saved manifest changed its recipients or scope")
			return
		}
		for _, r := range m.Recipients {
			if planned.identity[r.PaneID] != r.Identity {
				fail("manifest: recipient %s changed", r.PaneID)
			}
		}
	}
	toolCalls, raced := 0, 0
	var readState, readLinks mWorld
	var caller broadcastCaller
	caller = func(name string, arguments map[string]any) (string, bool) {
		if toolCalls == step.injectAt {
			if step.injected == mEvents-1 {
				body, _ := runBroadcast(mPanes[0], call.scope, mID, call.text, caller, store, now)
				if !strings.Contains(body, "in progress") {
					fail("lock: a second actor's call ran during a broadcast: %s", body)
				}
			} else {
				w.apply(step.injected)
			}
		}
		toolCalls++
		switch name {
		case "relay_list_panes":
			readState = w
			return w.state(), true
		case "relay_list_pane_links":
			readLinks = w
			return w.links(), true
		case "relay_message_pane":
			target, message, text := arguments["pane_id"].(string), arguments["message_id"].(string), arguments["text"].(string)
			if w.FailNext {
				w.FailNext = false
				return "relayd unavailable", false
			}
			p := strings.Index(strings.Join(mPanes[:], " "), target) / (len(target) + 1)
			if planned != nil && (!w.Linked[p] || w.identity(p) != planned.identity[target]) {
				return "relayd: the saved pins no longer match", false
			}
			switch {
			case planned == nil || planned.identity[target] == "":
				fail("manifest: delivered to %s outside the manifest", target)
			case !readLinks.Linked[p] || readLinks.identity(p) != planned.identity[target]:
				fail("fresh: delivered to %s although the recheck saw its link or conversation changed", target)
			case readState.oracleScope(p, planned.scope) != planned.scopeID || readState.oracleScope(0, planned.scope) != planned.scopeID:
				fail("fresh: delivered to %s although the recheck saw it outside the exact scope", target)
			case !readState.granted(planned.scope):
				fail("fresh: delivered to %s although the recheck saw the user's grant removed", target)
			case admitted[message]:
				fail("once: message %s admitted twice", message)
			case message != broadcastMessageID(mID, target):
				fail("once: unexpected message ID %s", message)
			case !strings.HasSuffix(text, "\n\n"+planned.text):
				fail("text: delivered %q for an ID first used with %q", text, planned.text)
			}
			if w.oracleScope(p, planned.scope) != planned.scopeID || w.oracleScope(0, planned.scope) != planned.scopeID || !w.granted(planned.scope) {
				raced++
			}
			admitted[message] = true
			return `{"status":"accepted_by_provider"}`, true
		}
		return "unexpected", false
	}
	runBroadcast(mPanes[0], call.scope, mID, call.text, caller, store, now)
	if store.locked {
		fail("lock: left held")
	}
	next := mState{World: w, Files: string(store.files[mID])}
	var ids []string
	for id := range admitted {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	next.Admitted = strings.Join(ids, " ")
	if planned != nil {
		parts := []string{planned.scope, planned.scopeID, planned.text}
		var keys []string
		for k := range planned.identity {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			parts = append(parts, k+"="+planned.identity[k])
		}
		next.Planned = strings.Join(parts, "|")
	}
	return next, violation, raced
}

func TestBroadcastExhaustiveInterleavings(t *testing.T) {
	depth := 4
	if value, err := strconv.Atoi(os.Getenv("BROADCAST_DEPTH")); err == nil {
		depth = value
	}
	var steps []mStep
	for e := 0; e < mEvents-1; e++ {
		steps = append(steps, mStep{event: e, call: -1, injectAt: -1})
	}
	for c := range mCalls {
		steps = append(steps, mStep{call: c, injectAt: -1})
		for k := 0; k < mMaxToolCalls; k++ {
			for e := 0; e < mEvents; e++ {
				steps = append(steps, mStep{call: c, injectAt: k, injected: e})
			}
		}
	}
	now := time.Date(2026, 10, 29, 12, 0, 0, 0, time.UTC)
	start := mState{World: mWorld{Tab: [3]int{0, 0, 1}, Linked: [3]bool{false, true, true}, Grant: [2]uint8{3, 0}, Owned: [2]bool{true, true}}}
	seen := map[mState]bool{start: true}
	frontier := []mState{start}
	transitions, deliveries, raced := 0, 0, 0
	began := time.Now()
	for level := 0; level < depth && len(frontier) > 0; level++ {
		var next []mState
		for _, state := range frontier {
			for _, step := range steps {
				transitions++
				after, violation, late := mRun(state, step, now)
				raced += late
				if violation != "" {
					t.Fatalf("%s\n  by %v\n  from %+v", violation, step, state)
				}
				if after.Admitted != state.Admitted {
					deliveries++
				}
				if !seen[after] {
					seen[after] = true
					next = append(next, after)
				}
			}
		}
		frontier = next
	}
	t.Logf("broadcast model check: depth %d, %d steps per state, %d states, %d transitions, %d delivering transitions, %d deliveries after a scope or grant change in the recheck-to-send window, %s",
		depth, len(steps), len(seen), transitions, deliveries, raced, time.Since(began).Round(time.Second))
	if depth >= 4 && (len(seen) < 1000 || deliveries == 0) {
		t.Fatalf("the check explored too little to mean anything: %d states, %d delivering transitions", len(seen), deliveries)
	}
}
