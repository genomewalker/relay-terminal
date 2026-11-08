package appupdate

import (
	"reflect"
	"testing"
)

// Go to pane's visit history (paneVisits, app 0.5.33) changes whenever the
// user switches panes; it is not layout, so a preserving update must not
// report "saved layout changed" because of it.
func TestLayoutIgnoresPaneVisitHistory(t *testing.T) {
	before := map[string]any{"tabs": []any{map[string]any{"id": "T"}}, "panes": []any{map[string]any{"id": "P"}}}
	after := map[string]any{"tabs": []any{map[string]any{"id": "T"}}, "panes": []any{map[string]any{"id": "P"}},
		"paneVisits": []any{map[string]any{"paneID": "P", "lastVisitedAt": "2026-11-08T15:00:00Z", "visitCount": jsonNumber("3"), "weight": jsonNumber("1.5")}}}
	a, err := Layout(before)
	if err != nil {
		t.Fatal(err)
	}
	b, err := Layout(after)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(a, b) {
		t.Fatalf("visit history changed the layout:\n%v\n%v", a, b)
	}
	// A real layout change is still seen.
	moved := map[string]any{"tabs": []any{map[string]any{"id": "T2"}}, "panes": []any{map[string]any{"id": "P"}}}
	if c, _ := Layout(moved); reflect.DeepEqual(a, c) {
		t.Fatal("a changed tab was not seen as a layout change")
	}
}
