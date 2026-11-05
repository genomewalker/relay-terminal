package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"unicode"
)

// oracleMikoAgentArguments is an independent reading of the relay_ask_miko /
// relay_miko_receipt argument contract, written against a generic JSON
// decode rather than validMikoAgentArguments' RawMessage path. It also
// models main.go's caller_token handling, which runs first.
func oracleMikoAgentArguments(ask bool, raw []byte) (map[string]string, bool) {
	var decoded map[string]any
	if json.Unmarshal(raw, &decoded) != nil || decoded == nil {
		return nil, false
	}
	if token, ok := decoded["caller_token"]; ok {
		value, isString := token.(string)
		if !isString || value == "" || len(value) > 200 {
			return nil, false
		}
		delete(decoded, "caller_token")
	}
	allowed := map[string]bool{"instance": true, "request_id": true}
	if ask {
		allowed["text"], allowed["pane_id"] = true, true
	}
	fields := map[string]string{}
	for key, value := range decoded {
		text, isString := value.(string)
		if !allowed[key] || !isString {
			return nil, false
		}
		fields[key] = text
	}
	isUUID := func(value string) bool {
		if len(value) != 36 {
			return false
		}
		for i, r := range value {
			switch i {
			case 8, 13, 18, 23:
				if r != '-' {
					return false
				}
			default:
				if !strings.ContainsRune("0123456789abcdefABCDEF", r) {
					return false
				}
			}
		}
		return true
	}
	instance, hasInstance := fields["instance"]
	requestID, hasRequest := fields["request_id"]
	if !hasInstance || !hasRequest || !isUUID(instance) || !isUUID(requestID) {
		return nil, false
	}
	if !ask {
		return fields, true
	}
	text, hasText := fields["text"]
	if !hasText || len(text) > 4096 || strings.IndexFunc(text, func(r rune) bool { return !unicode.IsSpace(r) }) < 0 {
		return nil, false
	}
	if context, ok := fields["pane_id"]; ok && !isUUID(context) {
		return nil, false
	}
	return fields, true
}

// callMikoAgentTool sends one tools/call through the real server.handle with
// the raw argument bytes. The server has no daemon helper, so a call that
// passes validation reaches mikoSupervisorCall and stops at "daemon backend":
// no proof is minted and nothing is sent. A refused call returns -32602
// before mikoSupervisorCall, the only place a proof is minted.
func callMikoAgentTool(ask bool, raw []byte) (any, int) {
	name := "relay_miko_receipt"
	if ask {
		name = "relay_ask_miko"
	}
	params := append(append([]byte(`{"name":"`+name+`","arguments":`), raw...), '}')
	result, code, _ := (&server{}).handle(request{Method: "tools/call", Params: params})
	return result, code
}

// embeddable reports whether raw, placed as the arguments value, stays the
// arguments value: a valid JSON value always does; invalid bytes must leave
// the whole params document invalid too (otherwise raw could close the
// arguments object and add its own "name" key, which is a different call).
func embeddable(raw []byte) bool {
	if json.Valid(raw) {
		return true
	}
	return !json.Valid(append(append([]byte(`{"name":"relay_ask_miko","arguments":`), raw...), '}'))
}

func reachedMikoSupervisorCall(result any, code int) bool {
	if code != 0 {
		return false
	}
	value, ok := result.(map[string]any)
	return ok && value["isError"] == true && strings.Contains(toolResultText(result), "daemon backend")
}

// Properties, for any argument bytes:
//  1. Agreement: the tools/call path dispatches (reaches mikoSupervisorCall)
//     exactly when the independent oracle accepts; every refusal is -32602.
//  2. Bounded size: an accepted call carries a text of at most 4096 bytes
//     with a non-space character, at most 4 contract fields, and two UUIDs.
//  3. Round trip: the accepted fields, re-encoded canonically and decoded
//     again, are accepted with identical field values.
//  4. Truncation: every proper prefix of an accepted (trimmed) body is
//     refused and never dispatched.
func FuzzMikoAgentArguments(f *testing.F) {
	for _, seed := range []struct {
		ask bool
		raw string
	}{
		{true, `{"instance":"11111111-1111-4111-8111-111111111111","request_id":"22222222-2222-4222-8222-222222222222","text":"tidy my tabs"}`},
		{true, `{"instance":"11111111-1111-4111-8111-111111111111","request_id":"22222222-2222-4222-8222-222222222222","text":"x","pane_id":"cbf0ccc8-ce1e-4708-ba5c-809b60a289e6"}`},
		{true, `{"instance":"11111111-1111-4111-8111-111111111111","request_id":"22222222-2222-4222-8222-222222222222","text":"` + strings.Repeat("a", 4096) + `"}`},
		{true, `{"instance":"11111111-1111-4111-8111-111111111111","request_id":"22222222-2222-4222-8222-222222222222","text":"` + strings.Repeat("a", 4097) + `"}`},
		{true, `{"instance":"11111111-1111-4111-8111-111111111111","request_id":"22222222-2222-4222-8222-222222222222","text":"` + strings.Repeat("😀", 1024) + `"}`},
		{true, `{"instance":"11111111-1111-4111-8111-111111111111","request_id":"22222222-2222-4222-8222-222222222222","text":"` + strings.Repeat("a", 4095) + `é"}`},
		{true, `{"instance":"11111111-1111-4111-8111-111111111111","request_id":"22222222-2222-4222-8222-222222222222","text":" \t\n "}`},
		{true, `{"instance":"11111111-1111-4111-8111-111111111111","request_id":"22222222-2222-4222-8222-222222222222","text":"hi","card_id":"x"}`},
		{true, `{"instance":"11111111-1111-4111-8111-111111111111","request_id":"22222222-2222-4222-8222-22222222222","text":"hi"}`},
		{true, `{"instance":"11111111-1111-4111-8111-111111111111","request_id":"22222222-2222-4222-8222-222222222222","text":"hi","pane_id":7}`},
		{true, `{"instance":"11111111-1111-4111-8111-111111111111","request_id":"22222222-2222-4222-8222-222222222222","text":"hi","pane_id":"cbf0ccc8-ce1e-4708-ba5c-809b60a289eZ"}`},
		{true, `{"instance":"11111111-1111-4111-8111-111111111111","request_id":"22222222-2222-4222-8222-222222222222","text":null}`},
		{true, `{"instance":"11111111-1111-4111-8111-111111111111","request_id":"22222222-2222-4222-8222-222222222222","text":"hi","caller_token":"tok"}`},
		{true, `{"instance":"11111111-1111-4111-8111-111111111111","request_id":"22222222-2222-4222-8222-222222222222","text":"hi","caller_token":""}`},
		{true, `{"instance":"11111111-1111-4111-8111-111111111111","request_id":"22222222-2222-4222-8222-222222222222","text":"é́"}`},
		{true, `{"instance":"11111111-1111-4111-8111-111111111111","request_id":"22222222-2222-4222-8222-222222222222","text":"hi","text":"   "}`},
		{true, `{"instance":"11111111-1111-4111-8111-111111111111","request_id":"22222222-2222-4222-8222-2222222`},
		{true, `null`},
		{true, `[]`},
		{true, `{}`},
		{false, `{"instance":"11111111-1111-4111-8111-111111111111","request_id":"22222222-2222-4222-8222-222222222222"}`},
		{false, `{"instance":"11111111-1111-4111-8111-111111111111","request_id":"22222222-2222-4222-8222-222222222222","text":"x"}`},
		{false, `{"instance":"11111111-1111-4111-8111-111111111111","request_id":"2222222222222222222222222222222222222"}`},
	} {
		f.Add(seed.ask, []byte(seed.raw))
	}
	f.Fuzz(func(t *testing.T, ask bool, raw []byte) {
		if !embeddable(raw) {
			return // input filter, not a pass: these bytes would be a different tools/call
		}
		fields, valid := oracleMikoAgentArguments(ask, raw)
		result, code := callMikoAgentTool(ask, raw)
		dispatched := reachedMikoSupervisorCall(result, code)
		if dispatched != valid {
			t.Fatalf("oracle valid=%v but dispatched=%v (code %d) for %q", valid, dispatched, code, raw)
		}
		if !valid {
			if code != -32602 {
				t.Fatalf("refused call returned code %d, want -32602, for %q", code, raw)
			}
			return
		}
		if len(fields) > 4 || len(fields["text"]) > 4096 || !paneID.MatchString(fields["instance"]) || !paneID.MatchString(fields["request_id"]) {
			t.Fatalf("accepted out-of-bounds arguments %q", raw)
		}
		if ask && strings.TrimSpace(fields["text"]) == "" {
			t.Fatalf("accepted blank text %q", raw)
		}
		if !ask {
			if _, ok := fields["text"]; ok {
				t.Fatalf("receipt accepted text %q", raw)
			}
		}
		canonical, err := json.Marshal(fields)
		if err != nil {
			t.Fatal(err)
		}
		again, ok := oracleMikoAgentArguments(ask, canonical)
		if result, code := callMikoAgentTool(ask, canonical); !ok || !reachedMikoSupervisorCall(result, code) || len(again) != len(fields) {
			t.Fatalf("canonical round trip refused: %q", canonical)
		}
		for key, value := range fields {
			if again[key] != value {
				t.Fatalf("round trip changed %s: %q != %q", key, again[key], value)
			}
		}
		body := bytes.TrimSpace(raw)
		cuts := len(body)
		step := 1
		if cuts > 256 {
			step = cuts / 128
		}
		for k := 0; k < cuts; k += step {
			if result, code := callMikoAgentTool(ask, body[:k]); code != -32602 || reachedMikoSupervisorCall(result, code) {
				t.Fatalf("truncated body (%d of %d bytes) was not refused: code %d", k, cuts, code)
			}
		}
		if result, code := callMikoAgentTool(ask, body[:cuts-1]); code != -32602 || reachedMikoSupervisorCall(result, code) {
			t.Fatalf("body missing its last byte was not refused: code %d", code)
		}
	})
}
