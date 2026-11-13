package desktoproute

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// A route whose remote session never returns used to start a remote listener
// job every 36 s for ever (11,376 jobs on dandy-07 for one route). It now
// slows to one attempt every 5 minutes after 10 minutes without a ready
// frame, and stops with needs_attention after 24 hours.
func TestRouteWaitingForAnAbsentSessionSlowsDownAndThenStops(t *testing.T) {
	home := privateTemp(t)
	path := filepath.Join(home, "route.json")
	c := configFixture()
	if e := atomicJSON(path, c); e != nil {
		t.Fatal(e)
	}
	scripts := make([]listenerScript, 400)
	for i := range scripts {
		scripts[i] = listenerScript{out: missingFrame}
	}
	h := &scriptedHost{t: t, jobs: map[string]listenerScript{}, scripts: scripts}
	clock := time.Date(2026, 11, 13, 0, 0, 0, 0, time.UTC)
	start := clock
	var delays []time.Duration
	r := &runtime{home: home, desktop: &fakeDesktop{}, host: func(string) hostAPI { return h },
		now: func() time.Time { return clock },
		wait: func(ctx context.Context, d time.Duration) error {
			delays = append(delays, d)
			clock = clock.Add(d)
			return ctx.Err()
		}}
	if e := r.listen(context.Background(), c, path); e != nil {
		t.Fatalf("listen = %v, want a clean stop", e)
	}
	if elapsed := clock.Sub(start); elapsed < routeGiveUpAfter || elapsed > routeGiveUpAfter+routeSlowDelay {
		t.Fatalf("stopped after %s", elapsed)
	}
	// About 20 quick attempts in the first 10 minutes, then one per 5 minutes.
	if n := len(h.specs); n < 250 || n > 320 {
		t.Fatalf("%d remote listener jobs in a day; 2,400 before the fix", n)
	}
	for i, d := range delays {
		if d > routeSlowDelay || (i < 5 && d != reconnectDelay(i)) {
			t.Fatalf("delay %d = %s", i, d)
		}
	}
	if last := delays[len(delays)-1]; last != routeSlowDelay {
		t.Fatalf("late delay %s, want %s", last, routeSlowDelay)
	}
	raw, e := os.ReadFile(r.status(c))
	var state RouteState
	if e != nil || json.Unmarshal(raw, &state) != nil || state.State != "needs_attention" || state.Error == "" {
		t.Fatalf("final state %s %v", raw, e)
	}
}

func TestOnlyALastingAbsenceStopsARoute(t *testing.T) {
	transport := errors.New("host transport unavailable")
	cases := []struct {
		failure error
		outage  time.Duration
		stop    bool
	}{
		{errOwnerAbsent, routeGiveUpAfter, true},
		{errLocalAbsent, routeGiveUpAfter + time.Hour, true},
		{errOwnerAbsent, routeGiveUpAfter - time.Minute, false},
		{transport, 7 * routeGiveUpAfter, false},
		{nil, routeGiveUpAfter, false},
	}
	for i, c := range cases {
		if got := routeAbandoned(c.failure, c.outage); got != c.stop {
			t.Fatalf("case %d: abandoned=%v", i, got)
		}
	}
	if routeRetryDelay(3, routeSlowAfter-time.Second) != reconnectDelay(3) || routeRetryDelay(3, routeSlowAfter) != routeSlowDelay {
		t.Fatal("retry delay does not switch at the slow threshold")
	}
}
