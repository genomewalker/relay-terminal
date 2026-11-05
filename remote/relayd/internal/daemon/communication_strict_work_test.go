package daemon

import "testing"

func TestCommunicationWorkJSONRejectsAmbiguousFields(t *testing.T) {
	var value struct {
		Name string `json:"name"`
	}
	for _, raw := range []string{`{"name":"one","name":"two"}`, `{"name":"one","NAME":"two"}`, `{"NAME":"one"}`, `{"name":"one"} {}`, `{"name":"one","extra":1}`} {
		if err := communicationStrictWorkJSON([]byte(raw), &value); err == nil {
			t.Fatalf("accepted %s", raw)
		}
	}
	if err := communicationStrictWorkJSON([]byte(`{"name":"ok"}`), &value); err != nil || value.Name != "ok" {
		t.Fatal(value, err)
	}
}
