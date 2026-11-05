package appupdate

import (
	"errors"
	"sort"
	"strings"
)

func list(m map[string]any, k string) ([]any, error) {
	a, ok := m[k].([]any)
	if !ok {
		return nil, errors.New("missing array: " + k)
	}
	return a, nil
}
func asMap(v any) (map[string]any, error) {
	m, ok := v.(map[string]any)
	if !ok {
		return nil, errors.New("object required")
	}
	return m, nil
}
func ids(panes []any) ([]string, error) {
	out := []string{}
	for _, v := range panes {
		p, e := asMap(v)
		if e != nil {
			return nil, e
		}
		id, ok := p["id"].(string)
		if !ok || id == "" {
			return nil, errors.New("pane id required")
		}
		out = append(out, strings.ToLower(id))
	}
	sort.Strings(out)
	return out, nil
}
func PaneIDs(state map[string]any) ([]string, error) {
	sessions, e := list(state, "sessions")
	if e != nil {
		return nil, e
	}
	panes := []any{}
	for _, v := range sessions {
		s, e := asMap(v)
		if e != nil {
			return nil, e
		}
		tabs, e := list(s, "tabs")
		if e != nil {
			return nil, e
		}
		for _, v := range tabs {
			t, e := asMap(v)
			if e != nil {
				return nil, e
			}
			p, e := list(t, "panes")
			if e != nil {
				return nil, e
			}
			panes = append(panes, p...)
		}
	}
	return ids(panes)
}
func WorkspaceIDs(state map[string]any) ([]string, error) {
	p, e := list(state, "panes")
	if e != nil {
		return nil, e
	}
	out, e := ids(p)
	if e != nil {
		return nil, e
	}
	if len(out) == 0 {
		return nil, errors.New("empty workspace")
	}
	for i := 1; i < len(out); i++ {
		if out[i] == out[i-1] {
			return nil, errors.New("duplicate pane identity")
		}
	}
	return out, nil
}
func LiveFocus(state map[string]any) (map[string]any, error) {
	pane, _ := state["selectedPaneID"].(string)
	var tab any
	matches := 0
	sessions, e := list(state, "sessions")
	if e != nil {
		return nil, e
	}
	for _, v := range sessions {
		s, e := asMap(v)
		if e != nil {
			return nil, e
		}
		tabs, e := list(s, "tabs")
		if e != nil {
			return nil, e
		}
		for _, v := range tabs {
			t, e := asMap(v)
			if e != nil {
				return nil, e
			}
			ps, e := list(t, "panes")
			if e != nil {
				return nil, e
			}
			for _, v := range ps {
				p, e := asMap(v)
				if e != nil {
					return nil, e
				}
				id, _ := p["id"].(string)
				if strings.EqualFold(id, pane) && pane != "" {
					matches++
					tab = t["id"]
					break
				}
			}
		}
	}
	if matches > 1 {
		return nil, errors.New("selected pane belongs to multiple tabs")
	}
	var p any
	if pane != "" {
		p = pane
	}
	return map[string]any{"activePaneID": p, "selectedTabID": tab}, nil
}
func NormalizedFocus(value map[string]any) map[string]any {
	out := map[string]any{}
	for _, k := range []string{"selectedTabID", "activePaneID"} {
		s, _ := value[k].(string)
		if s == "" {
			out[k] = nil
		} else {
			out[k] = strings.ToLower(s)
		}
	}
	return out
}
func alternating(v []any) (map[string]any, error) {
	if len(v)%2 != 0 {
		return nil, errors.New("odd alternating dictionary")
	}
	m := map[string]any{}
	for i := 0; i < len(v); i += 2 {
		k, ok := v[i].(string)
		if !ok {
			return nil, errors.New("dictionary key is not text")
		}
		if _, ok := m[k]; ok {
			return nil, errors.New("duplicate alternating dictionary key")
		}
		m[k] = v[i+1]
	}
	return m, nil
}
func Layout(value map[string]any) (map[string]any, error) {
	m, e := object(jsonData(value))
	if e != nil {
		return nil, e
	}
	delete(m, "activePaneID")
	delete(m, "selectedTabID")
	if a, ok := m["sessionNames"].([]any); ok {
		v, e := alternating(a)
		if e != nil {
			return nil, e
		}
		m["sessionNames"] = v
	}
	if tabs, ok := m["tabs"].([]any); ok {
		for _, v := range tabs {
			t, e := asMap(v)
			if e != nil {
				return nil, e
			}
			if a, ok := t["splitRatios"].([]any); ok {
				v, e := alternating(a)
				if e != nil {
					return nil, e
				}
				t["splitRatios"] = v
			}
		}
	}
	return m, nil
}
func auditArray(m map[string]any) ([]any, error) {
	v, ok := m["audit"]
	if !ok {
		return []any{}, nil
	}
	a, ok := v.([]any)
	if !ok {
		return nil, errors.New("audit is not an array")
	}
	return a, nil
}
func AuditContinuity(before, after any) error {
	if before == nil {
		if after != nil {
			return errors.New("caller registry appeared")
		}
		return nil
	}
	b, e := asMap(before)
	if e != nil {
		return e
	}
	a, e := asMap(after)
	if e != nil {
		return e
	}
	clean := func(v map[string]any) map[string]any {
		r := map[string]any{}
		for k, x := range v {
			if k != "audit" {
				r[k] = x
			}
		}
		return r
	}
	if !equal(clean(b), clean(a)) {
		return errors.New("caller registry changed")
	}
	old, e := auditArray(b)
	if e != nil {
		return e
	}
	now, e := auditArray(a)
	if e != nil {
		return e
	}
	if len(now) >= len(old) && equal(old, now[:len(old)]) {
		return nil
	}
	if len(now) != 2000 {
		return errors.New("audit changed without bounded rotation")
	}
	n := len(old)
	if len(now) < n {
		n = len(now)
	}
	for ; n > 0; n-- {
		if equal(old[len(old)-n:], now[:n]) {
			return nil
		}
	}
	return errors.New("no ordered audit continuity")
}
