package remotemcpbridge

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"reflect"
	"sort"
	"testing"
)

const sourcePane = "5a30d83a-5222-48f3-93c7-42fa687d901b"
const targetPane = "1652a003-70e9-4614-addb-68564fa8383b"
const foreignPane = "9ef1b226-5993-48ff-8f6a-2a93f3c7ce3b"
const requestID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

type reference struct {
	Name, Method, Path, Token string
	Caller                    *string
	Payload, State, Result    any
	Status                    int
	Responses                 map[string][]any
	Forwarded                 []any
	Receipts, FinalReceipts   []string `json:"-"`
}

func readReferences(t *testing.T, name string) []map[string]any {
	t.Helper()
	raw, e := os.ReadFile("testdata/" + name)
	if e != nil {
		t.Fatal(e)
	}
	var rows []map[string]any
	if e = json.Unmarshal(raw, &rows); e != nil {
		t.Fatal(e)
	}
	return rows
}
func baseState() any {
	return map[string]any{"sessions": []any{map[string]any{"id": "session", "tabs": []any{map[string]any{"id": "tab", "panes": []any{map[string]any{"id": sourcePane, "host": "dandy-07", "contentKind": "terminal"}, map[string]any{"id": targetPane, "host": "dandy-07", "contentKind": "editor"}}}}}}, "selectedPaneID": sourcePane}
}
func request(b *Bridge, method, path string, payload any, token, caller string) (int, any) {
	raw := []byte{}
	if payload != nil {
		raw = encode(payload)
	}
	r := httptest.NewRequest(method, path, bytes.NewReader(raw))
	r.Header.Set("x-relay-token", token)
	r.Header.Set("X-Relay-Caller-Token", caller)
	status, out := b.Handle(r)
	var v any
	_ = json.Unmarshal(out, &v)
	return status, v
}
func receiptKeys(b *Bridge) []string {
	keys := []string{}
	for k := range b.receipts {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
func TestCanonicalReferences(t *testing.T) {
	for _, file := range []string{"bridge-original-10.json", "bridge-expanded-reference.json"} {
		rows := readReferences(t, file)
		for _, row := range rows {
			t.Run(row["name"].(string), func(t *testing.T) {
				forwarded := []any{}
				expanded := file == "bridge-expanded-reference.json"
				state := baseState()
				if expanded {
					state = row["state"]
				}
				d := func(_ context.Context, m, p string, raw []byte, caller string) (int, []byte, error) {
					var body any
					if len(raw) > 0 {
						if e := json.Unmarshal(raw, &body); e != nil {
							t.Fatal(e)
						}
					}
					isScope := p == "/api/state" || p == "/api/workspace/context" && reflect.DeepEqual(body, map[string]any{"tab_id": "tab"})
					if expanded || !isScope {
						forwarded = append(forwarded, map[string]any{"method": m, "path": p, "body": body, "caller": caller})
					}
					if p == "/api/state" {
						return 200, encode(state), nil
					}
					if responses, ok := row["responses"].(map[string]any); ok {
						if values, ok := responses[p].([]any); ok {
							return int(values[0].(float64)), encode(values[1]), nil
						}
					}
					return 200, []byte(`{"status":"fixture_only"}`), nil
				}
				b := New("dandy-07", "fixture", d)
				if initial, ok := row["receipts"].([]any); ok && expanded {
					for _, id := range initial {
						b.receipts[id.(string)] = true
					}
				}
				caller := "fixture_client"
				if c, ok := row["caller"].(string); ok {
					caller = c
				}
				token := "fixture"
				if s, ok := row["token"].(string); ok {
					token = s
				}
				status, result := request(b, row["method"].(string), row["path"].(string), row["payload"], token, caller)
				if status != int(row["status"].(float64)) {
					t.Fatalf("canonical status: got %d want %v result %v", status, row["status"], result)
				}
				if !reflect.DeepEqual(forwarded, row["forwarded"]) {
					t.Fatalf("canonical forward: got %v want %v", forwarded, row["forwarded"])
				}
				if expanded && !reflect.DeepEqual(result, row["result"]) {
					t.Fatalf("canonical result: got %v want %v", result, row["result"])
				}
				expected := row["receipts"]
				if expanded {
					expected = row["final_receipts"]
				}
				actual := []any{}
				for _, k := range receiptKeys(b) {
					actual = append(actual, k)
				}
				if !reflect.DeepEqual(actual, expected) {
					t.Fatalf("canonical receipts: %v vs %v", actual, expected)
				}
			})
		}
	}
}
func TestReferenceDigests(t *testing.T) {
	for name, want := range referenceDigests {
		raw, e := os.ReadFile("testdata/" + name)
		if e != nil {
			t.Fatal(e)
		}
		sum := sha256.Sum256(raw)
		if hex.EncodeToString(sum[:]) != want {
			t.Fatal(fmt.Sprint("primary reference changed: ", name))
		}
	}
}
