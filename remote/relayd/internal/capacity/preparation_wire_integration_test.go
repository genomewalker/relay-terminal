package capacity

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestCapacityPreparationWireRejectsUnstableCapsule(t *testing.T) {
	for _, raw := range []string{`{}`, `null`, `{"canonical_json":null}`, `{"canonical_json":[]}`} {
		if _, err := DecodePreparation([]byte(raw)); err == nil {
			t.Fatal("PREPARATION_MISSING_OR_NULL_CAPSULE_ACCEPTED", raw)
		}
	}
	for _, raw := range []string{
		`{"canonical_json":{ "objective" : "fixture" }}`,
		`{"canonical_json":{"objective":"<capsule>"}}`,
	} {
		if _, err := DecodePreparation([]byte(raw)); err == nil {
			t.Fatal("PREPARATION_WIRE_BYTES_WOULD_CHANGE", raw)
		}
	}
	valid := preparation()
	encoded, err := json.Marshal(valid)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := DecodePreparation(encoded)
	if err != nil || !bytes.Equal(parsed.CanonicalJSON, valid.CanonicalJSON) {
		t.Fatal("PREPARATION_EXACT_CAPSULE_BYTES_LOST", err)
	}
	if err := ValidatePreparation(parsed, source(), strings.Repeat("c", 64), 3); err != nil {
		t.Fatal("PREPARATION_VALID_ATTESTATION_REJECTED", err)
	}
	var pretty bytes.Buffer
	if err := json.Indent(&pretty, valid.CanonicalJSON, "", "  "); err != nil {
		t.Fatal(err)
	}
	unstable := valid
	unstable.CanonicalJSON = pretty.Bytes()
	unstable.Capsule.SHA256 = Hash(unstable.CanonicalJSON)
	if err := ValidatePreparation(unstable, source(), strings.Repeat("c", 64), 3); err == nil {
		t.Fatal("PREPARATION_UNSTABLE_CAPSULE_AUTHORIZED")
	}
	if _, err := DecodePreparation(encoded[:len(encoded)-1]); err == nil {
		t.Fatal("PREPARATION_TRUNCATED_WIRE_ACCEPTED")
	}
}
