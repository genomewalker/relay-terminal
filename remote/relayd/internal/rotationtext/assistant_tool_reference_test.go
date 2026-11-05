package rotationtext

import (
	"bufio"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"strings"
	"testing"
)

// The corpus contains every call made by the original capacity/native wrapper
// property tests, captured while all six original test methods passed. These
// fixed oracle answers preserve the original random seeds and input domains.
func TestAssistantToolsCanonicalReference(t *testing.T) {
	file, err := os.Open("testdata/assistant-tool-reference.jsonl.gz")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	z, err := gzip.NewReader(file)
	if err != nil {
		t.Fatal(err)
	}
	defer z.Close()
	digest := sha256.New()
	scan := bufio.NewScanner(io.TeeReader(io.LimitReader(z, 16<<20), digest))
	scan.Buffer(make([]byte, 4096), 1<<20)
	count, accepted := 0, 0
	coverage := map[string]int{}
	for scan.Scan() {
		var row struct {
			Test     string          `json:"test"`
			Name     string          `json:"name"`
			Input    json.RawMessage `json:"input"`
			Accepted bool            `json:"accepted"`
			Error    string          `json:"error"`
		}
		if err := json.Unmarshal(scan.Bytes(), &row); err != nil {
			t.Fatal(err)
		}
		args := parseJSON([]byte(row.Input))
		got := goOutcome(func() any { validateAssistantInput(row.Name, args); return nil })
		_, ok := got["ok"]
		if ok != row.Accepted || !ok && got["draft_error"] != row.Error {
			t.Fatalf("canonical tool schema case %d (%s/%s): %s", count, row.Test, row.Name, compact(got))
		}
		if ok {
			accepted++
			input := args.(obj)
			if strings.HasPrefix(row.Name, "native_") {
				for _, key := range []string{"identity", "action_id", "capabilities", "source", "approved"} {
					if _, supplied := input[key]; supplied {
						t.Fatal("native authority escaped schema", key)
					}
				}
			}
			if row.Name == "set_capacity_pause" && (!keysEqual(input, "pane_id", "paused") || !isBool(input["paused"])) {
				t.Fatal("capacity pause accepted outside canonical domain")
			}
			if row.Name == "request_capacity_action" && (!hasKeys(input, "pane_id", "action") || !keysWithin(input, "pane_id", "action", "target_account") || !strIn(input["action"], "manual_refresh", "manual_move")) {
				t.Fatal("capacity action accepted outside canonical domain")
			}
		}
		coverage[row.Test]++
		count++
	}
	if err := scan.Err(); err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(digest.Sum(nil)) != "167c10a564e85dc0db1ea5b941b2caa60c5eefeef8a0cfd5419ff3431795d321" {
		t.Fatal("canonical tool corpus changed")
	}
	if count != 14147 || accepted == 0 || accepted == count || coverage["test_fixed_seed_model_proposal_properties"] != 10000 || coverage["test_native_wrapper_fixed_seed_schema_properties"] != 4096 {
		t.Fatal("canonical tool corpus coverage", count, accepted, coverage)
	}
	t.Logf("canonical tool corpus cases=%d accepted=%d capacity-seed=1631 capacity=10000 native-seed=0x4e4154495645 native=4096", count, accepted)
}

func FuzzAssistantToolAuthority(f *testing.F) {
	for _, seed := range []string{
		`{"name":"native_snapshot","input":{"pane_id":"0e426bf7-58ab-4e0b-a521-b2400a8989aa"}}`,
		`{"name":"native_action","input":{"pane_id":"p","action_json":"{}"}}`,
		`{"name":"native_resume","input":{"pane_id":"p","provider":"codex","account":"work"}}`,
		`{"name":"set_capacity_pause","input":{"pane_id":"p","paused":false}}`,
		`{"name":"native_snapshot","input":{"pane_id":"p","identity":"forged"}}`,
		`{"name":"native_snapshot","input":{"pane_id":"p","waitMillis":true}}`,
		`{`,
	} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 65536 {
			return
		}
		var input struct {
			Name  string          `json:"name"`
			Input json.RawMessage `json:"input"`
		}
		if json.Unmarshal(data, &input) != nil {
			return
		}
		// Exercise the actual production validator. A successful call must be
		// stable on round trip and cannot accept any caller authority or omit a
		// declared required field, even if the production check is mutated.
		var args any
		if json.Unmarshal(input.Input, &args) != nil {
			return
		}
		decoded := goOutcome(func() any { return parseJSON([]byte(input.Input)) })
		canonical, parsed := decoded["ok"]
		if !parsed {
			return
		}
		result := goOutcome(func() any { validateAssistantInput(input.Name, canonical); return nil })
		if _, ok := result["ok"]; !ok {
			return
		}
		schema := assistantSchemas[input.Name]
		if schema == nil {
			t.Fatal("unknown tool admitted")
		}
		fields, ok := canonical.(obj)
		if !ok {
			t.Fatal("nonobject admitted")
		}
		for _, required := range stringsOf(schema["required"]) {
			if _, present := fields[required]; !present {
				t.Fatal("required field omitted", required)
			}
		}
		properties := schema["properties"].(obj)
		for key := range fields {
			if _, allowed := properties[key]; !allowed {
				t.Fatal("caller authority admitted", key)
			}
		}
		again := goOutcome(func() any { validateAssistantInput(input.Name, parseJSON(compact(canonical))); return nil })
		if _, ok := again["ok"]; !ok {
			t.Fatal("schema round trip refused")
		}
	})
}

// The former duplicate-backend equality check is replaced by one compiled
// backend plus byte-exact primary constants. Retain the separate public-name
// registration assertion: a valid schema alone does not publish its tool.
func TestNativeAssistantCatalogueRegistersLegacyProposals(t *testing.T) {
	for _, want := range []string{"native_snapshot", "native_receipt", "native_action", "native_image", "native_launch", "native_resume", "set_capacity_pause", "request_capacity_action"} {
		found := false
		for _, got := range assistantNames {
			if got == want {
				found = true
			}
		}
		if !found || assistantSchemas[want] == nil {
			t.Fatalf("legacy proposal is not registered: %s", want)
		}
	}
}
