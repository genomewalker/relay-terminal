package daemon

import (
	"encoding/json"
	"math"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// maxFocusRoutes bounds a Focus frame: one pane has an interactive route and
// at most a few event-only routes.
const maxFocusRoutes = 4

// ParseFocusRoutes reads a Focus payload {"routes":[...]}. An empty list is
// valid and clears focus. Any route that is not a session ID rejects the frame.
func ParseFocusRoutes(payload []byte) ([]string, bool) {
	var focus struct {
		Routes []string `json:"routes"`
	}
	if json.Unmarshal(payload, &focus) != nil || len(focus.Routes) > maxFocusRoutes {
		return nil, false
	}
	for _, route := range focus.Routes {
		if !validSessionID.MatchString(route) {
			return nil, false
		}
	}
	return focus.Routes, true
}

// ParsePathQuality reads relayd node's Quality payload. Values must be finite,
// non-negative and below an hour; anything else rejects the frame.
func ParsePathQuality(payload []byte, now time.Time) (protocol.PathQuality, bool) {
	var q struct {
		Last     float64 `json:"rtt_last_ms"`
		Min      float64 `json:"rtt_min_ms"`
		Smoothed float64 `json:"rtt_smoothed_ms"`
		Samples  uint64  `json:"rtt_samples"`
		Lost     uint64  `json:"rtt_lost"`
	}
	if json.Unmarshal(payload, &q) != nil || q.Samples == 0 {
		return protocol.PathQuality{}, false
	}
	ms := func(v float64) (time.Duration, bool) {
		if math.IsNaN(v) || v < 0 || v > float64(time.Hour/time.Millisecond) {
			return 0, false
		}
		return time.Duration(v * float64(time.Millisecond)), true
	}
	last, ok1 := ms(q.Last)
	min, ok2 := ms(q.Min)
	smoothed, ok3 := ms(q.Smoothed)
	if !ok1 || !ok2 || !ok3 {
		return protocol.PathQuality{}, false
	}
	return protocol.PathQuality{LastRTT: last, MinRTT: min, SmoothedRTT: smoothed,
		Samples: q.Samples, Lost: q.Lost, At: now}, true
}
