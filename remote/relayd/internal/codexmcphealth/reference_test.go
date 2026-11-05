package codexmcphealth

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"testing"
)

func TestCanonicalHealthMain(t *testing.T) {
	raw, e := os.ReadFile("testdata/health-reference.json")
	if e != nil {
		t.Fatal(e)
	}
	if fmt.Sprintf("%x", sha256.Sum256(raw)) != healthReferenceSHA {
		t.Fatal("canonical health reference changed")
	}
	var rows []struct {
		Name      string
		Overrides map[string]map[string]any
		Mask      int
		Error     any
		Calls     []struct {
			Method string
			Params any
		}
		Closed bool
		Result any
	}
	if e = json.Unmarshal(raw, &rows); e != nil {
		t.Fatal(e)
	}
	if len(rows) != 264 {
		t.Fatal("primary reference bound changed")
	}
	for _, row := range rows {
		t.Run(row.Name, func(t *testing.T) {
			r := newRuntime()
			r.responses = row.Overrides
			mask := row.Mask
			r.o.Refresh = mask&1 != 0
			r.o.InspectLoaded = mask&2 != 0
			r.owns = mask&4 == 0
			if mask&8 != 0 {
				r.loaded = append(r.loaded, "other")
			}
			if mask&16 != 0 {
				r.thread["status"] = map[string]any{"type": "active"}
			}
			if mask&32 != 0 {
				r.thread["id"] = "different"
			}
			if mask&64 != 0 {
				r.thread["cwd"] = "/foreign"
			}
			if mask&128 != 0 {
				r.loaded = []any{}
			}
			got, e := Inspect(context.Background(), r.o, r)
			if (e != nil) != (row.Error != nil) {
				t.Fatalf("canonical error parity: %v want %v", e, row.Error)
			}
			methods := []string{}
			for _, c := range row.Calls {
				methods = append(methods, c.Method)
			}
			actual := append([]string{}, r.calls...)
			if !reflect.DeepEqual(actual, methods) || r.closed != row.Closed {
				t.Fatalf("canonical calls/close: got %v %v want %v %v", actual, r.closed, methods, row.Closed)
			}
			out, _ := json.Marshal(got)
			var result any
			_ = json.Unmarshal(out, &result)
			if !reflect.DeepEqual(result, row.Result) {
				t.Fatalf("canonical result %v want %v", result, row.Result)
			}
		})
	}
}
