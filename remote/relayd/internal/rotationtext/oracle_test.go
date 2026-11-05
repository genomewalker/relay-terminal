package rotationtext

import (
	"context"
	"encoding/base64"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
	"unicode/utf16"
)

// Differential cases compare against a fixed canonical primary corpus.
// The native reference bridge retains every generated input and byte assertion.

type oracleCase struct {
	Fn           string            `json:"fn"`
	Args         []string          `json:"args,omitempty"`
	Raw          *string           `json:"raw,omitempty"`
	RawB64       *string           `json:"raw_b64,omitempty"`
	Env          map[string]string `json:"env,omitempty"`
	Unset        []string          `json:"unset,omitempty"`
	API          []oracleAPI       `json:"api,omitempty"`
	ExpectKey    string            `json:"expect_key,omitempty"`
	Now          string            `json:"now,omitempty"`
	Steps        []oracleStep      `json:"steps,omitempty"`
	Execute      string            `json:"execute,omitempty"`
	Canned       []string          `json:"canned,omitempty"`
	Fixture      string            `json:"fixture,omitempty"` // legacy journal directory to start from
	name         string
	ledger       bool   // run the journal over the Go ledger instead of the memory store
	nativeSQLite bool   // arbitrary-copy storage oracle; Journal engine is trusted here
	fold         string // "", or start from a ledger folded with ReconcileLegacyWith ("empty" / "prefix")
}

type oracleAPI struct {
	Error   string `json:"error,omitempty"`
	BodyB64 string `json:"body_b64,omitempty"`
}

type oracleStep struct {
	Op      string `json:"op"`
	Request string `json:"request"`
}

func apiBody(body string) oracleAPI {
	return oracleAPI{BodyB64: base64.StdEncoding.EncodeToString([]byte(body))}
}

// goOutcome mirrors the oracle's outcome(): ok, DraftError or exception.
func goOutcome(fn func() any) (result obj) {
	defer func() {
		if value := recover(); value != nil {
			draft, exception := recoverPy(value)
			if draft != nil {
				result = obj{"draft_error": draft.code, "unavailable": draft.unavailable}
				if draft.apiUsage != nil {
					result["api_usage"] = draft.apiUsage
				}
				return
			}
			if exception.kind == "RecursionError" {
				result = obj{"exception": "RecursionError"}
				return
			}
			result = obj{"exception": true}
		}
	}()
	return obj{"ok": fn()}
}

func mustParse(text string) any { return parseJSON(text) }

func args(c oracleCase) []any {
	out := make([]any, len(c.Args))
	for i, text := range c.Args {
		out[i] = mustParse(text)
	}
	return out
}

func toAny(values ...any) []any { return values }

// runGo evaluates one case with the port, under the same environment.
func runGo(t *testing.T, c oracleCase) obj {
	t.Helper()
	saved := map[string]*string{}
	remember := func(name string) {
		if _, ok := saved[name]; ok {
			return
		}
		if value, ok := os.LookupEnv(name); ok {
			saved[name] = &value
		} else {
			saved[name] = nil
		}
	}
	for name, value := range c.Env {
		remember(name)
		os.Setenv(name, value)
	}
	for _, name := range c.Unset {
		remember(name)
		os.Unsetenv(name)
	}
	defer func() {
		for name, value := range saved {
			if value == nil {
				os.Unsetenv(name)
			} else {
				os.Setenv(name, *value)
			}
		}
	}()
	calls := []any{}
	responses := append([]oracleAPI(nil), c.API...)
	apiPostHook = func(body []byte, key string, timeout time.Duration) []byte {
		calls = append(calls, obj{"body": string(body), "key_ok": key == c.ExpectKey, "timeout": int64(timeout / time.Second)})
		if len(responses) == 0 {
			fail("request_outcome_unknown")
		}
		response := responses[0]
		responses = responses[1:]
		if response.Error != "" {
			fail(response.Error)
		}
		raw, _ := base64.StdEncoding.DecodeString(response.BodyB64)
		return raw
	}
	defer func() { apiPostHook = nil }()
	ctx := context.Background()
	a := args(c)
	var result obj
	switch c.Fn {
	case "parse_json":
		var raw any
		if c.RawB64 != nil {
			decoded, _ := base64.StdEncoding.DecodeString(*c.RawB64)
			raw = decoded
		} else {
			raw = *c.Raw
		}
		result = goOutcome(func() any { return parseJSON(raw) })
	case "compact":
		result = goOutcome(func() any { return compact(a[0]) })
	case "validate_draft":
		result = goOutcome(func() any { return validateDraft(a[0]) })
	case "usage_fields":
		result = goOutcome(func() any { return usageFields(a[0]) })
	case "redact_evidence":
		result = goOutcome(func() any { text, count := redactEvidence(a[0].(string)); return toAny(text, int64(count)) })
	case "redact_assistant_payload":
		result = goOutcome(func() any { return redactAssistantPayload(a[0], a[1].(string), 1) })
	case "redact_assistant_messages":
		result = goOutcome(func() any { return redactAssistantMessages(a[0].([]any), a[1].(string)) })
	case "validate_health_calls":
		result = goOutcome(func() any { return validateHealthCalls(a[0], a[1].([]any), a[2].(bool)) })
	case "validate_health_messages":
		result = goOutcome(func() any { return validateHealthMessages(a[0], a[1], a[2].([]any)) })
	case "valid_health_panes":
		result = goOutcome(func() any { return validHealthPanes(a[0], a[1], a[2]) })
	case "validate_health_assessment":
		result = goOutcome(func() any { return validateHealthAssessment(a[0], a[1].([]any)) })
	case "validate_assistant_input":
		result = goOutcome(func() any { validateAssistantInput(a[0].(string), a[1]); return nil })
	case "validate_assistant_blocks":
		result = goOutcome(func() any { return validateAssistantBlocks(a[0], 16) })
	case "validate_assistant_messages":
		result = goOutcome(func() any { return int64(validateAssistantMessages(a[0])) })
	case "valid_assistant_binding":
		result = goOutcome(func() any { return validAssistantBinding(a[0]) })
	case "valid_assistant_evidence":
		result = goOutcome(func() any { value, used := validAssistantEvidence(a[0]); return toAny(value, int64(used)) })
	case "validated_settings":
		result = goOutcome(func() any { return validatedSettings(a[0]) })
	case "validated_account":
		result = goOutcome(func() any { return validatedAccount(a[0]) })
	case "assistant_health_reserve":
		result = goOutcome(func() any { return normInt(assistantHealthReserve(bigOf(a[0]))) })
	case "valid_operation_id":
		result = goOutcome(func() any { validOperationID(a[0]); return nil })
	case "draft":
		result = goOutcome(func() any { return draft(ctx, a[0]) })
	case "journal":
		result = goOutcome(func() any { return runGoJournal(t, ctx, c) })
	case "sqlite_dump":
		result = goOutcome(func() any {
			if c.nativeSQLite {
				return sqliteReferenceDump(t, c.Fixture)
			}
			return goSQLiteDump(t, c.Fixture)
		})
	default:
		t.Fatalf("no Go dispatch for %s", c.Fn)
	}
	result["api_calls"] = calls
	return result
}

func runGoJournal(t *testing.T, ctx context.Context, c oracleCase) any {
	now, err := time.Parse("2006-01-02T15:04:05", c.Now)
	if err != nil {
		t.Fatal(err)
	}
	canned := append([]string(nil), c.Canned...)
	requests := []any{}
	execute := func(ctx context.Context, request any) any {
		requests = append(requests, request)
		if c.Execute == "canned" {
			if len(canned) == 0 {
				raise("RuntimeError")
			}
			next := canned[0]
			canned = canned[1:]
			return mustParse(next)
		}
		return Draft(ctx, request)
	}
	var store Store = newMemoryStore()
	if c.nativeSQLite {
		root := filepath.Join(t.TempDir(), "rotation-text")
		copyFixture(t, c.Fixture, root)
		native := openSQLiteReference(t, root)
		if err := native.initialize(); err != nil {
			t.Fatal(err)
		}
		store = native
	} else if c.ledger || c.Fixture != "" {
		root := filepath.Join(t.TempDir(), "rotation-text")
		copyFixture(t, c.Fixture, root)
		if c.fold != "" {
			prepareFoldedRoot(t, root, c.fold)
		}
		ledger, err := OpenLedger(root)
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		store = ledger
	}
	journal, err := OpenJournal(store, execute, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	steps := []any{}
	for _, step := range c.Steps {
		request := mustParse(step.Request)
		fields, isMap := request.(obj)
		// The oracle indexes configure requests and calls .get() on others.
		requireFields := func(keys ...string) {
			if !isMap || !hasKeys(fields, keys...) {
				raise("KeyError")
			}
		}
		var outcome obj
		switch step.Op {
		case "configure":
			outcome = goOutcome(func() any {
				requireFields("operation_id", "settings")
				return journal.Configure(fields["operation_id"], fields["settings"], fields["expected_configuration_id"])
			})
		case "status":
			outcome = goOutcome(func() any { requireFields(); return journal.Status(fields["operation_id"]) })
		case "abandon":
			outcome = goOutcome(func() any { requireFields(); return journal.Abandon(fields["operation_id"]) })
		case "submit":
			outcome = goOutcome(func() any { return journal.Submit(ctx, request) })
		case "assess":
			outcome = goOutcome(func() any { return journal.Assess(ctx, request) })
		case "assist":
			outcome = goOutcome(func() any { return journal.Assist(ctx, request) })
		default:
			t.Fatalf("unknown journal op %s", step.Op)
		}
		steps = append(steps, outcome)
	}
	journal.Close()
	return obj{"steps": steps, "backend_requests": requests}
}

// compareOracle runs cases through both implementations and reports each
// difference with its case name.
func compareOracle(t *testing.T, cases []oracleCase) {
	t.Helper()
	expected := runOracle(t, cases)
	failures := 0
	stats := map[string]int{}
	for i, c := range cases {
		if result, ok := expected[i].(obj); ok {
			key := "ok"
			if code, ok := result["draft_error"].(string); ok {
				key = code
			} else if _, ok := result["exception"]; ok {
				key = "exception"
			}
			stats[c.Fn+":"+key]++
		}
		want := compact(expected[i])
		got := compact(finite(runGo(t, c)))
		if dump := os.Getenv("RT_ORACLE_DUMP"); dump != "" && strings.HasPrefix(c.name, dump) {
			t.Logf("%s: %s", c.name, want)
		}
		if want != got {
			failures++
			if failures <= 15 {
				t.Errorf("case %d %s (%s args=%s)\n python: %s\n     go: %s", i, c.name, c.Fn, clip(strings.Join(c.Args, " | "), 600), clip(want, 1500), clip(got, 1500))
			}
		}
	}
	if failures > 0 {
		t.Errorf("%d of %d differential cases differ", failures, len(cases))
	}
	if os.Getenv("RT_ORACLE_STATS") != "" {
		for _, key := range sortedKeys(stats) {
			t.Logf("%6d %s", stats[key], key)
		}
	}
}

// finite replaces non-finite floats with the oracle's marker objects.
func finite(value any) any {
	switch v := value.(type) {
	case float64:
		if math.IsInf(v, 1) {
			return obj{"__float__": "inf"}
		}
		if math.IsInf(v, -1) {
			return obj{"__float__": "-inf"}
		}
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = finite(item)
		}
		return out
	case map[string]any:
		out := obj{}
		for key, item := range v {
			out[key] = finite(item)
		}
		return out
	}
	return value
}

func clip(s string, n int) string {
	if len(s) > n {
		return s[:n] + "..."
	}
	return s
}

func fnCase(name, fn string, arguments ...any) oracleCase {
	texts := make([]string, len(arguments))
	for i, value := range arguments {
		if text, ok := value.(rawJSON); ok {
			texts[i] = string(text)
		} else {
			texts[i] = asciiJSON(value)
		}
	}
	return oracleCase{name: name, Fn: fn, Args: texts}
}

// asciiJSON is compact() with non-ASCII escaped, so lone surrogates survive
// the UTF-8 case file.
func asciiJSON(value any) string {
	text := compact(value)
	var out strings.Builder
	for i := 0; i < len(text); {
		r, size := decodeWTF8(text, i)
		i += size
		switch {
		case r < 0x80:
			out.WriteRune(r)
		case r > 0xffff:
			high, low := utf16.EncodeRune(r)
			fmt.Fprintf(&out, "\\u%04x\\u%04x", high, low)
		default:
			fmt.Fprintf(&out, "\\u%04x", r)
		}
	}
	return out.String()
}

// rawJSON passes an argument as literal JSON text (for duplicates, escapes).
type rawJSON string

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for key := range m {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}
