package rotationtext

import (
	"strings"
	"testing"
)

func TestAssistantPanePaginationSchema(t *testing.T) {
	for _, args := range []obj{{}, {"offset": int64(0)}, {"query": "business", "offset": int64(32)}, {"offset": int64(1000000)}} {
		validateAssistantInput("list_panes", args)
	}
	for _, value := range []any{int64(-1), int64(1000001), true, "32", 1.5} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("accepted invalid offset %#v", value)
				}
			}()
			validateAssistantInput("list_panes", obj{"offset": value})
		}()
	}
	var advertised obj
	for _, tool := range assistantTools {
		if tool.(obj)["name"] == "list_panes" {
			advertised = tool.(obj)["input_schema"].(obj)
		}
	}
	if advertised == nil || advertised["properties"].(obj)["offset"] == nil {
		t.Fatal("API tools omit the pagination field accepted by validation")
	}
}

func TestDescribePanesToolIsReadOnlyAndBounded(t *testing.T) {
	pane := "0f0e0d0c-0b0a-4908-8706-050403020100"
	for _, args := range []obj{{}, {"query": "build"}, {"pane_id": pane}, {"scope": "all", "include_viewport": false},
		{"query": "codex", "scope": "matching"}} {
		validateAssistantInput("describe_panes", args)
	}
	for _, args := range []obj{{"scope": "everything"}, {"query": strings.Repeat("x", 81)}, {"include_viewport": "yes"},
		{"text": "type this"}, {"pane_id": strings.Repeat("a", 65)}} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("accepted invalid describe_panes arguments %#v", args)
				}
			}()
			validateAssistantInput("describe_panes", args)
		}()
	}
	found := 0
	for _, name := range assistantNames {
		if name == "describe_panes" {
			found++
		}
	}
	if found != 1 || assistantSchemas["describe_panes"] == nil {
		t.Fatal("describe_panes is not registered exactly once")
	}
	var description string
	for _, tool := range assistantTools {
		if tool.(obj)["name"] == "describe_panes" {
			description = tool.(obj)["description"].(string)
		}
	}
	for _, want := range []string{"Read-only", "untrusted", "ambiguous", "never guess", "Nothing is selected, focused or shown"} {
		if !strings.Contains(description, want) {
			t.Errorf("describe_panes description lacks %q", want)
		}
	}
}
