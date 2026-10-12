package federation

import (
	"strings"
	"testing"
)

func TestReceiptTransitions(t *testing.T) {
	base := Receipt{1, Key{"realm", "field", "session", "message"}, strings.Repeat("a", 64), "record", Persisted}
	states := []State{Persisted, Claimed, Processing, Succeeded, Failed, Expired, Indeterminate}
	for i, a := range states {
		for j, b := range states {
			old, next := base, base
			old.State, next.State = a, b
			allowed := a == b || (i < 3 && j > i)
			if (Advance(old, next) == nil) != allowed {
				t.Errorf("%s -> %s", a, b)
			}
		}
	}
	for _, mutate := range []func(*Receipt){
		func(r *Receipt) { r.Version = 2 }, func(r *Receipt) { r.Key.Realm = "other" },
		func(r *Receipt) { r.RecordID = "different" }, func(r *Receipt) { r.PayloadSHA256 = strings.Repeat("b", 64) },
		func(r *Receipt) { r.State = "transport-delivered" }, func(r *Receipt) { r.Key.Message = "bad\n" },
		func(r *Receipt) { r.Key.SenderSession = "" }, func(r *Receipt) { r.PayloadSHA256 = "abcd" },
	} {
		next := base
		mutate(&next)
		if Advance(base, next) == nil {
			t.Fatal("accepted invalid/conflicting receipt")
		}
	}
}
