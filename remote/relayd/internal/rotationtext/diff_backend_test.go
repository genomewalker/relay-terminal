package rotationtext

import (
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const fakeCLIScript = `#!/bin/sh
d=$(pwd -P)
case "$(basename "$d")" in relay-capsule-text-*) ;; *) echo "unexpected cwd" >&2; exit 9 ;; esac
input=$(cat)
sig=$( { printf '%s\n' "$@"; printf '%s' "$input"; env | grep -v -e '^PWD=' -e '^OLDPWD=' -e '^SHLVL=' -e '^_=' | LC_ALL=C sort; } | sed "s|$d|TMP|g" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-64)
draft='{"summary":"'$sig'","decisions":[],"constraints":["c"],"pending_work":[],"next_action":"n","uncertainties":[]}'
case "$MODE" in
claude-ok) printf '{"type":"result","subtype":"success","is_error":false,"structured_output":%s,"usage":{"input_tokens":12,"output_tokens":7,"service_tier":"x"}}' "$draft" ;;
claude-text) printf '{"subtype":"success","is_error":false,"result":%s}' "$(printf '%s' "$draft" | sed 's/["\\]/\\&/g; s/^/"/; s/$/"/')" ;;
claude-noresult) printf '{"subtype":"success","is_error":false}' ;;
claude-error) printf '{"subtype":"success","is_error":true,"structured_output":%s}' "$draft" ;;
claude-badfields) printf '{"subtype":"success","structured_output":{"summary":"x"}}' ;;
codex-ok) printf '%s' "$draft" ;;
garbage) printf 'not json' ;;
huge) head -c 300000 /dev/zero | tr '\0' 'a' ;;
exit1) printf '%s' "$draft"; exit 1 ;;
esac
`

const fakeHelperScript = `#!/bin/sh
input=$(cat)
case "$input" in
*'"operation":"read"'*'"reference":"e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1"'*) printf '  fake-test-key-0123456789\n' ;;
*'"reference":"e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2"'*) printf 'short' ;;
*) exit 3 ;;
esac
`

type cliFixture struct {
	dir, helper, auth, tmp string
}

func writeScript(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o700); err != nil {
		t.Fatal(err)
	}
}

func newCLIFixture(t *testing.T) cliFixture {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	f := cliFixture{dir: dir, helper: filepath.Join(dir, "relay-credentials"), auth: filepath.Join(dir, "auth"), tmp: filepath.Join(dir, "tmp")}
	for _, mode := range []string{"claude-ok", "claude-text", "claude-noresult", "claude-error", "claude-badfields", "codex-ok", "garbage", "huge", "exit1"} {
		writeScript(t, filepath.Join(dir, "cli-"+mode), "#!/bin/sh\nMODE="+mode+"\nexport MODE\n"+fakeCLIScript[len("#!/bin/sh\n"):])
	}
	writeScript(t, f.helper, fakeHelperScript)
	if err := os.Mkdir(f.auth, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(f.tmp, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(dir, "shared"), 0o755); err != nil {
		t.Fatal(err)
	}
	return f
}

func (f cliFixture) cli(mode string) string { return filepath.Join(f.dir, "cli-"+mode) }

func (f cliFixture) env() map[string]string {
	return map[string]string{"TMPDIR": f.tmp, "RELAY_CREDENTIAL_HELPER": f.helper, "ANTHROPIC_API_KEY": fakeKey,
		"DBUS_SESSION_BUS_ADDRESS": noBus}
}

// noBus keeps Linux vault lookups away from any real session keyring.
const noBus = "unix:path=/nonexistent/relay-test-bus"

var credentialUnset = []string{"ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY"}

func draftRequest(config obj) obj {
	request := obj{"v": int64(1), "operation_id": opID, "binding": obj{"session_id": "sess_1", "client": "claude", "turn_seq": int64(3)},
		"evidence": "User asked to port the backend; key sk-ant-abcdefghijklmnopqrstuv must be redacted."}
	if config != nil {
		request["config"] = config
	}
	return request
}

func apiResponse(blocks []any, stop string, mods obj) string {
	response := obj{"id": "msg_1", "type": "message", "role": "assistant", "model": apiModel, "stop_reason": stop,
		"content": blocks, "usage": obj{"input_tokens": int64(1200), "output_tokens": int64(300), "cache_read_input_tokens": int64(10)}}
	for key, value := range mods {
		if value == nil {
			delete(response, key)
		} else {
			response[key] = value
		}
	}
	return compact(response)
}

func draftText() string { return compact(validDraft()) }

func healthRequest() (obj, []any) {
	panes := defaultPanes()
	evidence := compact(obj{"panes": panes, "messages": []any{}})
	return obj{"v": int64(1), "operation_id": opID, "purpose": "pane_health",
		"binding": obj{"host_id": hostID, "snapshot_id": snapshotOf(hostID, panes)}, "evidence": evidence,
		"config": obj{"providers": []any{"anthropic_api"}}}, panes
}

func assistantRequest(messages []any) obj {
	evidence := compact(obj{"context": "Here: pane " + paneA + " token=abcdefgh1234 on " + hostID, "messages": messages})
	return obj{"v": int64(1), "operation_id": opID, "purpose": "relay_assistant",
		"binding": obj{"host_id": hostID, "operation_id": opID, "request_id": reqID}, "evidence": evidence,
		"config": obj{"providers": []any{"anthropic_api"}}}
}

func backendCase(name string, f cliFixture, request any, responses ...oracleAPI) oracleCase {
	c := fnCase(name, "draft", request)
	c.Env, c.Unset, c.ExpectKey, c.API = f.env(), credentialUnset, fakeKey, responses
	return c
}

func TestDifferentialBackends(t *testing.T) {
	useLegacyAssistant(t)
	f := newCLIFixture(t)
	random := rand.New(rand.NewSource(57))
	textBlock := func(text string) []any { return []any{obj{"type": "text", "text": text}} }
	cases := []oracleCase{
		backendCase("draft-ok", f, draftRequest(nil), apiBody(apiResponse(textBlock(draftText()), "end_turn", nil))),
		backendCase("draft-split-blocks", f, draftRequest(nil), apiBody(apiResponse([]any{obj{"type": "text", "text": draftText()[:10]},
			obj{"type": "text", "text": draftText()[10:]}}, "end_turn", nil))),
		backendCase("draft-refused", f, draftRequest(nil), apiBody(apiResponse(textBlock(draftText()), "refusal", nil))),
		backendCase("draft-model", f, draftRequest(nil), apiBody(apiResponse(textBlock(draftText()), "end_turn", obj{"model": "claude-opus-5-5"}))),
		backendCase("draft-bad-json", f, draftRequest(nil), apiBody(apiResponse(textBlock("{not json"), "end_turn", nil))),
		backendCase("draft-bad-fields", f, draftRequest(nil), apiBody(apiResponse(textBlock(`{"summary":"x"}`), "end_turn", nil))),
		backendCase("draft-no-usage-retained", f, draftRequest(nil), apiBody(apiResponse(textBlock(`{"summary":"x"}`), "end_turn", obj{"usage": obj{"input_tokens": int64(5)}}))),
		backendCase("draft-tool-block", f, draftRequest(nil), apiBody(apiResponse([]any{toolUse("t", "x", obj{})}, "end_turn", nil))),
		backendCase("draft-not-object", f, draftRequest(nil), apiBody(`[1]`)),
		backendCase("draft-invalid-body", f, draftRequest(nil), apiBody("\xff")),
		backendCase("draft-http", f, draftRequest(nil), oracleAPI{Error: "api_http_529"}),
		backendCase("draft-unknown", f, draftRequest(nil), oracleAPI{Error: "request_outcome_unknown"}),
		backendCase("draft-model-config", f, draftRequest(obj{"anthropic_model": "claude-opus-5-5"})),
		backendCase("draft-bad-config", f, draftRequest(obj{"nope": true})),
		backendCase("draft-bad-providers", f, draftRequest(obj{"providers": []any{"anthropic_api", "anthropic_api"}})),
		backendCase("draft-v-bool", f, func() obj { r := draftRequest(nil); r["v"] = true; return r }()),
		backendCase("draft-v-float", f, func() obj { r := draftRequest(nil); r["v"] = 1.0; return r }()),
		backendCase("draft-not-dict", f, []any{}),
		backendCase("claude-ok", f, draftRequest(obj{"providers": []any{"claude_account"}, "claude_path": f.cli("claude-ok")})),
		backendCase("claude-text", f, draftRequest(obj{"providers": []any{"claude_account"}, "claude_path": f.cli("claude-text"), "claude_model": "claude-sonnet-5-5"})),
		backendCase("claude-noresult", f, draftRequest(obj{"providers": []any{"claude_account"}, "claude_path": f.cli("claude-noresult")})),
		backendCase("claude-error", f, draftRequest(obj{"providers": []any{"claude_account"}, "claude_path": f.cli("claude-error")})),
		backendCase("claude-badfields", f, draftRequest(obj{"providers": []any{"claude_account"}, "claude_path": f.cli("claude-badfields")})),
		backendCase("claude-garbage", f, draftRequest(obj{"providers": []any{"claude_account"}, "claude_path": f.cli("garbage")})),
		backendCase("claude-huge", f, draftRequest(obj{"providers": []any{"claude_account"}, "claude_path": f.cli("huge")})),
		backendCase("claude-exit1", f, draftRequest(obj{"providers": []any{"claude_account"}, "claude_path": f.cli("exit1")})),
		backendCase("claude-bad-model", f, draftRequest(obj{"providers": []any{"claude_account"}, "claude_path": f.cli("claude-ok"), "claude_model": "bad model"})),
		backendCase("claude-relative", f, draftRequest(obj{"providers": []any{"claude_account"}, "claude_path": "claude"})),
		backendCase("claude-missing", f, draftRequest(obj{"providers": []any{"claude_account"}, "claude_path": f.dir + "/absent"})),
		backendCase("claude-directory", f, draftRequest(obj{"providers": []any{"claude_account"}, "claude_path": f.dir})),
		backendCase("codex-ok", f, draftRequest(obj{"providers": []any{"codex_account"}, "codex_path": f.cli("codex-ok"), "codex_model": "gpt-5.5"})),
		backendCase("codex-no-model", f, draftRequest(obj{"providers": []any{"codex_account"}, "codex_path": f.cli("codex-ok")})),
		backendCase("fallback-chain", f, draftRequest(obj{"providers": []any{"codex_account", "claude_account", "anthropic_api"},
			"codex_path": f.cli("codex-ok"), "claude_path": f.dir + "/absent"}), apiBody(apiResponse(textBlock(draftText()), "end_turn", nil))),
		backendCase("selected-claude", f, draftRequest(obj{"providers": []any{"claude_account"}, "claude_model": "claude-haiku-5-5",
			"claude_path": f.cli("claude-ok"), "selected_account": cliAccount(obj{"auth_directory": f.auth, "cli_path": f.cli("claude-ok")})})),
		backendCase("selected-api", f, draftRequest(obj{"providers": []any{"anthropic_api"}, "selected_account": apiAccount(nil)}),
			apiBody(apiResponse(textBlock(draftText()), "end_turn", nil))),
		backendCase("selected-api-short", f, draftRequest(obj{"providers": []any{"anthropic_api"},
			"selected_account": apiAccount(obj{"credential_ref": "e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2"})})),
		backendCase("selected-api-locked", f, draftRequest(obj{"providers": []any{"anthropic_api"},
			"selected_account": apiAccount(obj{"credential_ref": "e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3"})})),
		backendCase("selected-disabled", f, draftRequest(obj{"providers": []any{"anthropic_api"}, "selected_account": apiAccount(obj{"enabled": false})})),
		backendCase("selected-provider-mismatch", f, draftRequest(obj{"providers": []any{"claude_account"}, "selected_account": apiAccount(nil)})),
	}
	noKey := backendCase("draft-no-key", f, draftRequest(nil))
	noKey.Unset = append(append([]string{}, credentialUnset...), "ANTHROPIC_API_KEY")
	noKey.Env = map[string]string{"TMPDIR": f.tmp, "DBUS_SESSION_BUS_ADDRESS": noBus}
	badKey := backendCase("draft-bad-key", f, draftRequest(nil))
	badKey.Env = map[string]string{"TMPDIR": f.tmp, "ANTHROPIC_API_KEY": "has space in the key", "DBUS_SESSION_BUS_ADDRESS": noBus}
	noHelper := backendCase("selected-no-helper", f, draftRequest(obj{"providers": []any{"anthropic_api"}, "selected_account": apiAccount(nil)}))
	noHelper.Env = map[string]string{"TMPDIR": f.tmp, "RELAY_CREDENTIAL_HELPER": "relative/helper", "DBUS_SESSION_BUS_ADDRESS": noBus}
	cases = append(cases, noKey, badKey, noHelper)
	// Key length bounds (16..512) and billing group length bounds (1..64).
	for _, n := range []int{15, 16, 512, 513} {
		key := strings.Repeat("k", n)
		c := backendCase(fmt.Sprint("draft-key-length-", n), f, draftRequest(nil), apiBody(apiResponse(textBlock(draftText()), "end_turn", nil)))
		c.Env = map[string]string{"TMPDIR": f.tmp, "ANTHROPIC_API_KEY": key, "DBUS_SESSION_BUS_ADDRESS": noBus}
		c.ExpectKey = key
		cases = append(cases, c)
	}
	for _, n := range []int{64, 65} {
		cases = append(cases, backendCase(fmt.Sprint("selected-api-group-", n), f, draftRequest(obj{"providers": []any{"anthropic_api"},
			"selected_account": apiAccount(obj{"billing_group": strings.Repeat("g", n)})}), apiBody(apiResponse(textBlock(draftText()), "end_turn", nil))))
	}

	health, panes := healthRequest()
	healthBlocks := []any{obj{"type": "text", "text": "Inspecting."}, toolUse("toolu_1", "inspect_pane", obj{"pane_id": paneA})}
	healthBlocks[1].(obj)["caller"] = obj{"type": "direct"}
	cases = append(cases,
		backendCase("health-ok", f, health, apiBody(apiResponse(healthBlocks, "tool_use", nil))),
		backendCase("health-report", f, health, apiBody(apiResponse([]any{toolUse("toolu_9", "report_health", reportFor(panes, "healthy"))}, "tool_use", nil))),
		backendCase("health-end-turn", f, health, apiBody(apiResponse(healthBlocks, "end_turn", nil))),
		backendCase("health-bad-call", f, health, apiBody(apiResponse([]any{toolUse("toolu_1", "inspect_pane", obj{"pane_id": "nope"})}, "tool_use", nil))),
		backendCase("health-providers", f, func() obj {
			r := clone(health).(obj)
			r["config"] = obj{"providers": []any{"claude_account"}}
			return r
		}()),
		backendCase("health-bad-binding", f, func() obj { r := clone(health).(obj); r["binding"] = obj{"host_id": hostID}; return r }()),
		backendCase("health-bad-evidence", f, func() obj { r := clone(health).(obj); r["evidence"] = "[]"; return r }()),
	)
	messages := []any{obj{"role": "user", "content": "Why is pane A held? password=hunter2hunter2"}}
	assistant := assistantRequest(messages)
	assistantBlocks := []any{obj{"type": "text", "text": "Checking.", "citations": []any{}}, toolUse("toolu_a", "get_pane_health", obj{"pane_id": paneA})}
	cases = append(cases,
		backendCase("assistant-tool", f, assistant, apiBody(apiResponse(assistantBlocks, "tool_use", nil))),
		backendCase("assistant-answer", f, assistant, apiBody(apiResponse(textBlock("It is held for an update."), "end_turn", nil))),
		backendCase("assistant-max-tokens", f, assistant, apiBody(apiResponse(textBlock("It is"), "max_tokens", nil))),
		backendCase("assistant-mismatch", f, assistant, apiBody(apiResponse(assistantBlocks, "end_turn", nil))),
		backendCase("assistant-binding", f, func() obj {
			r := clone(assistant).(obj)
			r["binding"].(obj)["operation_id"] = opID2
			return r
		}()),
	)
	// Block limit (16) and host id length (128) boundaries.
	for _, n := range []int{16, 17} {
		blocks := []any{}
		for i := 0; i < n; i++ {
			blocks = append(blocks, obj{"type": "text", "text": fmt.Sprint("Part ", i, ".")})
		}
		cases = append(cases, backendCase(fmt.Sprint("assistant-blocks-", n), f, assistant, apiBody(apiResponse(blocks, "end_turn", nil))))
	}
	for _, n := range []int{128, 129} {
		r := clone(assistant).(obj)
		r["binding"].(obj)["host_id"] = strings.Repeat("h", n)
		cases = append(cases, backendCase(fmt.Sprint("assistant-host-length-", n), f, r, apiBody(apiResponse(textBlock("ok"), "end_turn", nil))))
	}
	// Tool budget: 7 prior calls leave tool_choice auto, 8 force none, 9 are rejected.
	for _, rounds := range []int{7, 8, 9} {
		history := append([]any{}, messages...)
		for n := 0; n < rounds; n++ {
			id := fmt.Sprint("toolu_r", n)
			history = append(history, obj{"role": "assistant", "content": []any{toolUse(id, "get_pane_health", obj{"pane_id": paneA})}},
				obj{"role": "user", "content": []any{toolResult(id, `{"hold":"update"}`)}})
		}
		cases = append(cases, backendCase(fmt.Sprint("assistant-budget-", rounds), f, assistantRequest(history),
			apiBody(apiResponse(textBlock("Held for an update."), "end_turn", nil))))
	}
	for i := 0; i < 250; i++ {
		var request obj
		var blocks []any
		stop := "tool_use"
		switch i % 3 {
		case 0:
			request, blocks, stop = draftRequest(nil), textBlock(draftText()), "end_turn"
		case 1:
			request, blocks = health, healthBlocks
		default:
			request, blocks = assistant, assistantBlocks
		}
		response := mutated(random, parseJSON(apiResponse(blocks, stop, nil)), 3)
		cases = append(cases, backendCase(fmt.Sprint("response-random-", i), f, clone(request), apiBody(asciiJSON(response))))
	}
	for i := 0; i < 250; i++ {
		var request any
		switch i % 3 {
		case 0:
			request = draftRequest(obj{"providers": []any{"anthropic_api"}})
		case 1:
			request = health
		default:
			request = assistant
		}
		cases = append(cases, backendCase(fmt.Sprint("request-random-", i), f, mutated(random, request, 2),
			apiBody(apiResponse(textBlock(draftText()), "end_turn", nil))))
	}
	compareOracle(t, cases)
}
