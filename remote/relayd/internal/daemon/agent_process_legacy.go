package daemon

import (
	"encoding/json"
	"strconv"
	"strings"
	"time"
)

type processRootEvent struct {
	Agent    string `json:"agent"`
	Sequence uint64 `json:"relay_event_seq"`
	Recorded string `json:"relay_recorded_at"`
	Event    struct {
		RootID   string `json:"root_id"`
		Source   string `json:"source"`
		Occurred string `json:"occurred_at"`
	} `json:"event"`
}

// Older observers read the process start after exit and emitted an
// "unavailable" incarnation. Repair only prior starts from that observer.
func legacyEndedProcessRoots(roots map[string][]byte, payload []byte) []string {
	var ended processRootEvent
	if json.Unmarshal(payload, &ended) != nil || ended.Event.Source != "process-tree" {
		return nil
	}
	parts := strings.SplitN(ended.Event.RootID, ":", 3)
	if len(parts) != 3 || parts[0] != ended.Agent || parts[2] != "unavailable" {
		return nil
	}
	pid, err := strconv.Atoi(parts[1])
	if err != nil || pid <= 0 {
		return nil
	}
	prefix := parts[0] + ":" + parts[1] + ":"
	var result []string
	for rootID, data := range roots {
		if !strings.HasPrefix(rootID, prefix) {
			continue
		}
		var started processRootEvent
		if json.Unmarshal(data, &started) != nil || started.Agent != ended.Agent || started.Event.Source != "process-tree" {
			continue
		}
		if started.Sequence != 0 && ended.Sequence != 0 {
			if started.Sequence > ended.Sequence {
				continue
			}
		} else {
			startDate, startErr := time.Parse(time.RFC3339Nano, processRootTimestamp(started))
			endDate, endErr := time.Parse(time.RFC3339Nano, processRootTimestamp(ended))
			if startErr != nil || endErr != nil || startDate.After(endDate) {
				continue
			}
		}
		result = append(result, rootID)
	}
	return result
}

func processRootTimestamp(event processRootEvent) string {
	if event.Event.Occurred != "" {
		return event.Event.Occurred
	}
	return event.Recorded
}

func processRootStartedAfterEvent(startedPayload, endedPayload []byte) bool {
	var started, ended processRootEvent
	if json.Unmarshal(startedPayload, &started) != nil || json.Unmarshal(endedPayload, &ended) != nil {
		return false
	}
	if started.Sequence != 0 && ended.Sequence != 0 {
		return started.Sequence > ended.Sequence
	}
	startDate, startErr := time.Parse(time.RFC3339Nano, processRootTimestamp(started))
	endDate, endErr := time.Parse(time.RFC3339Nano, processRootTimestamp(ended))
	return startErr == nil && endErr == nil && startDate.After(endDate)
}
