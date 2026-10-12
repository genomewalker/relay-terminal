package peernet

import (
	"testing"
	"time"
)

func TestTopologyIncarnationFreshnessAndBounds(t *testing.T) {
	now := time.Unix(1000, 0)
	source := Record{PID: 10, Session: "a", Start: "100"}
	target := Record{PID: 20, Session: "b", Start: "200"}
	live := map[int]Record{10: source, 20: target}
	valid := topologyReport{1, 10, "a", "100", now.UnixMilli(), []topologyTarget{{20, "b", "200"}}}
	if got := validateTopology(valid, source, live, now); len(got) != 1 {
		t.Fatalf("valid: %+v", got)
	}
	for _, mutate := range []func(*topologyReport){
		func(r *topologyReport) { r.Version = 2 },
		func(r *topologyReport) { r.Start = "old" },
		func(r *topologyReport) { r.Session = "wrong" },
		func(r *topologyReport) { r.UpdatedMS -= 31000 },
		func(r *topologyReport) { r.UpdatedMS += 6000 },
		func(r *topologyReport) { r.Links = []topologyTarget{{20, "b", "old"}} },
		func(r *topologyReport) { r.Links = make([]topologyTarget, 65) },
	} {
		r := valid
		mutate(&r)
		if len(validateTopology(r, source, live, now)) != 0 {
			t.Fatalf("accepted invalid %+v", r)
		}
	}
	delete(live, 20)
	if len(validateTopology(valid, source, live, now)) != 0 {
		t.Fatal("accepted missing destination")
	}
}
