package rotationtext

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

// TestDifferentialRedactionDepth compares deep tool-input nesting around
// Python's recursion limit, where redact_assistant_payload raises
// RecursionError and the journal records an uncertain outcome.
func TestDifferentialRedactionDepth(t *testing.T) {
	useLegacyAssistant(t)
	reply := apiResponse([]any{obj{"type": "text", "text": "ok"}}, "end_turn", nil)
	t.Setenv("ANTHROPIC_API_KEY", fakeKey)
	apiPostHook = func([]byte, string, time.Duration) []byte { return []byte(reply) }
	defer func() { apiPostHook = nil }()
	configure := asciiJSON(obj{"operation_id": opID, "settings": enabledSettings(nil)})
	for _, leaf := range []string{"string", "list", "number"} {
		low := 990
		if leaf == "string" {
			low = 987
		}
		for depth := low; depth <= low+4; depth++ {
			var value any = []any{}
			switch leaf {
			case "string":
				value = "x"
			case "number":
				value = int64(7)
			}
			for i := 0; i < depth; i++ {
				value = []any{value}
			}
			messages := []any{obj{"role": "user", "content": "q"},
				obj{"role": "assistant", "content": []any{obj{"type": "text", "text": "warm cache"},
					obj{"type": "text", "text": "t", "citations": value}}},
				obj{"role": "user", "content": "q2"}}
			assist := asciiJSON(assistRequest(opID2, reqID, messages))
			store := newMemoryStore()
			open := func() (*Journal, error) { return OpenJournal(store, nil, nil) }
			for _, step := range []struct{ op, raw string }{{"configure", configure}, {"assist", assist}} {
				want := referenceLookup(t, fmt.Sprintf("%s/%d/%s", leaf, depth, step.op), step.raw, nil, nil, nil, nil)
				got, err := RunOperation(context.Background(), open, step.op, []byte(step.raw))
				if err != nil || !bytes.Equal(got, want) {
					t.Errorf("%s leaf depth %d %s\n python: %s     go: %s", leaf, depth, step.op, clip(string(want), 400), clip(string(got), 400))
				} else if step.op == "assist" && os.Getenv("RT_ORACLE_STATS") != "" {
					t.Log(leaf, depth, strings.Contains(string(want), `"uncertain"`))
				}
			}
		}
	}
}
