package rotationtext

import "testing"

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
