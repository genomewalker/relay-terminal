package rotationtext

import (
	"math/big"
	"math/rand"
	"sort"
)

// Fixture builders shared by unit and differential tests. Hashes are computed
// with the port; the differential tests let the oracle recompute them.

const (
	paneA   = "0a1b2c3d-0000-4000-8000-00000000000a"
	paneB   = "0a1b2c3d-0000-4000-8000-00000000000b"
	paneC   = "0a1b2c3d-0000-4000-8000-00000000000c"
	hostID  = "dandy-07.example"
	opID    = "0123456789abcdef0123456789abcdef"
	opID2   = "fedcba9876543210fedcba9876543210"
	opID3   = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	reqID   = "11111111111111111111111111111111"
	reqID2  = "22222222222222222222222222222222"
	acctAPI = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
	acctCLI = "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1"
	credRef = "e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1"
	fakeKey = "fake-test-key-0123456789"
)

func clone(value any) any {
	switch v := value.(type) {
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = clone(item)
		}
		return out
	case map[string]any:
		out := obj{}
		for key, item := range v {
			out[key] = clone(item)
		}
		return out
	}
	return value
}

func withEvidence(pane obj) obj {
	evidence := obj{}
	for key, value := range pane {
		if key != "evidence_id" {
			evidence[key] = value
		}
	}
	pane["evidence_id"] = sha256Hex(compact(evidence))
	return pane
}

// makePane is a verified, idle, bound agent pane; mods override fields and a
// nil override deletes the field.
func makePane(id string, mods obj) obj {
	pane := obj{"pane_id": id, "kind": "claude", "connection": "connected", "binding": "bound", "activity": "quiet",
		"identity_verified": true, "prompt_empty": true, "has_draft": false, "pending_approvals": int64(0),
		"input_idle": true, "installed_update": false, "allowed_actions": []any{"observe"},
		"session_id": "session-" + id[len(id)-1:], "process_id": int64(4242), "process_start": int64(1700000000123),
		"observed_at": int64(1700000000)}
	for key, value := range mods {
		if value == nil {
			delete(pane, key)
		} else {
			pane[key] = value
		}
	}
	return withEvidence(pane)
}

// withNull sets fields to JSON null and refreshes the evidence id.
func withNull(pane obj, keys ...string) obj {
	for _, key := range keys {
		pane[key] = nil
	}
	return withEvidence(pane)
}

func shellPane(id string) obj {
	return makePane(id, obj{"kind": "shell", "binding": "not_applicable", "session_id": nil, "allowed_actions": []any{"observe"}})
}

func snapshotOf(host string, panes []any) string {
	return sha256Hex(compact(obj{"host_id": host, "panes": panes}))
}

func defaultPanes() []any {
	return []any{
		makePane(paneA, obj{"binding": "unbound", "allowed_actions": []any{"observe", "repair_link", "attention"}}),
		withNull(makePane(paneB, obj{"activity": "working", "connection": "disconnected", "allowed_actions": []any{"observe", "reconnect"}}), "prompt_empty"),
		shellPane(paneC),
	}
}

func toolUse(id, name string, input obj) obj {
	return obj{"type": "tool_use", "id": id, "name": name, "input": input}
}

func toolResult(id string, content string) obj {
	return obj{"type": "tool_result", "tool_use_id": id, "content": content}
}

func reportFor(panes []any, health string) obj {
	items := []any{}
	for _, raw := range panes {
		pane := raw.(obj)
		state := health
		if pane["kind"] == "shell" {
			state = "healthy"
		} else if pane["connection"] != "connected" || pane["binding"] != "bound" {
			state = "attention"
		}
		items = append(items, obj{"pane_id": pane["pane_id"], "evidence_id": pane["evidence_id"], "health": state,
			"action": "observe", "reason": "Observed state is " + state + "."})
	}
	return obj{"panes": items}
}

var weirdValues = []any{
	nil, true, false, int64(0), int64(1), int64(-1), int64(2), 1.0, 0.5, -0.0, "", " ", "x", "\xed\xa0\x80", []any{}, obj{},
	new(big.Int).Lsh(big.NewInt(1), 64), new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 64), big.NewInt(1)),
	int64(1 << 53), int64(1<<53 - 1), "observe", "connected", "claude", "codex", "shell", "not_applicable", "tool_use",
	"text", "tool_result", int64(10000), int64(10001), " ", "a\x00b", "repair_link", "reconnect", "bound", "unbound",
	"direct", obj{"type": "direct"}, obj{"type": "indirect"}, []any{"observe"}, paneA, "anthropic_api", "claude_account",
	"codex_account", "/abs/path", "relative", int64(200_000_000), int64(200_000_001), int64(1_000_000), int64(999_999),
	"sk-ant-abcdefghijklmnopqrstu", "user", "assistant", "low", "health_step", "\t", "ok\u0085", "İ",
}

// mutate applies one random structural change somewhere inside value.
func mutate(random *rand.Rand, value any) any {
	switch v := value.(type) {
	case map[string]any:
		if len(v) > 0 && random.Intn(3) > 0 {
			keys := make([]string, 0, len(v))
			for key := range v {
				keys = append(keys, key)
			}
			sort.Strings(keys)
			key := keys[random.Intn(len(keys))]
			switch random.Intn(5) {
			case 0:
				delete(v, key)
			case 1:
				v[key] = weirdValues[random.Intn(len(weirdValues))]
			default:
				v[key] = mutate(random, v[key])
			}
			return v
		}
		v[[]string{"extra", "caller", "is_error", "citations", "session_id", "observed_at", "billing_group", "model"}[random.Intn(8)]] =
			weirdValues[random.Intn(len(weirdValues))]
		return v
	case []any:
		if len(v) > 0 && random.Intn(4) > 0 {
			i := random.Intn(len(v))
			switch random.Intn(5) {
			case 0:
				return append(v[:i:i], v[i+1:]...)
			case 1:
				return append(v, clone(v[i]))
			case 2:
				v[i] = weirdValues[random.Intn(len(weirdValues))]
				return v
			default:
				v[i] = mutate(random, v[i])
				return v
			}
		}
		return append(v, weirdValues[random.Intn(len(weirdValues))])
	}
	if random.Intn(2) == 0 {
		return weirdValues[random.Intn(len(weirdValues))]
	}
	return value
}

// rehash recomputes pane evidence ids where possible so mutations reach the
// checks behind the hash comparison.
func rehash(value any) {
	panes, ok := value.([]any)
	if !ok {
		return
	}
	for _, raw := range panes {
		if pane, ok := raw.(obj); ok {
			func() {
				defer func() { recover() }()
				withEvidence(pane)
			}()
		}
	}
}

func safeSnapshot(host any, panes any) (id any) {
	defer func() {
		if recover() != nil {
			id = "0000000000000000000000000000000000000000000000000000000000000000"
		}
	}()
	return sha256Hex(compact(obj{"host_id": host, "panes": panes}))
}

func apiAccount(mods obj) obj {
	account := obj{"id": acctAPI, "name": "Work API", "provider": "anthropic_api", "enabled": true,
		"daily_limit_microusd": int64(5_000_000), "monthly_limit_microusd": int64(50_000_000), "max_requests_per_day": int64(100),
		"credential_ref": credRef, "billing_group": "team-a"}
	for key, value := range mods {
		if value == nil {
			delete(account, key)
		} else {
			account[key] = value
		}
	}
	return account
}

func cliAccount(mods obj) obj {
	account := obj{"id": acctCLI, "name": "Personal Claude", "provider": "claude_account", "enabled": true,
		"daily_limit_microusd": int64(0), "monthly_limit_microusd": int64(0), "max_requests_per_day": int64(20),
		"auth_directory": "/Users/example/.claude-personal", "model": "claude-haiku-5-5"}
	for key, value := range mods {
		if value == nil {
			delete(account, key)
		} else {
			account[key] = value
		}
	}
	return account
}

func enabledSettings(mods obj) obj {
	settings := obj{"enabled": true, "providers": []any{"anthropic_api"}, "daily_limit_microusd": int64(10_000_000),
		"monthly_limit_microusd": int64(100_000_000), "max_requests_per_day": int64(50)}
	for key, value := range mods {
		if value == nil {
			delete(settings, key)
		} else {
			settings[key] = value
		}
	}
	return settings
}

func validDraft() obj {
	return obj{"summary": "Ported the backend.", "decisions": []any{"Use Go."}, "constraints": []any{},
		"pending_work": []any{"Wire the store."}, "next_action": "Run the tests.", "uncertainties": []any{}}
}
