package peernet

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"time"
)

// Topology is an optional provider-produced sidecar, never conversation text.
// PID and start time bind each end to the exact current process incarnation.
type topologyReport struct {
	Version   int              `json:"version"`
	PID       int              `json:"pid"`
	Session   string           `json:"sessionId"`
	Start     string           `json:"procStart"`
	UpdatedMS int64            `json:"updatedMs"`
	Links     []topologyTarget `json:"links"`
}

type topologyTarget struct {
	PID     int    `json:"pid"`
	Session string `json:"sessionId"`
	Start   string `json:"procStart"`
}

type DiscoveredLink struct {
	SourcePID          int    `json:"sourcePID"`
	SourceSession      string `json:"sourceSession"`
	DestinationPID     int    `json:"destinationPID"`
	DestinationSession string `json:"destinationSession"`
	UpdatedMS          int64  `json:"updatedMs"`
}

func validateTopology(report topologyReport, source Record, live map[int]Record, now time.Time) []DiscoveredLink {
	if report.Version != 1 || report.PID != source.PID || report.Session != source.Session ||
		report.Start != source.Start || report.UpdatedMS < now.Add(-30*time.Second).UnixMilli() ||
		report.UpdatedMS > now.Add(5*time.Second).UnixMilli() || len(report.Links) > 64 {
		return nil
	}
	result := []DiscoveredLink{}
	seen := map[int]bool{}
	for _, target := range report.Links {
		peer, ok := live[target.PID]
		if !ok || peer.RelayProxy || target.PID == source.PID || seen[target.PID] ||
			target.Session != peer.Session || target.Start != peer.Start {
			continue
		}
		seen[target.PID] = true
		result = append(result, DiscoveredLink{source.PID, source.Session, peer.PID, peer.Session, report.UpdatedMS})
	}
	return result
}

func discoverTopology(home string, records []Record, now time.Time) []DiscoveredLink {
	live := make(map[int]Record, len(records))
	for _, record := range records {
		live[record.PID] = record
	}
	result := []DiscoveredLink{}
	for _, source := range records {
		if len(result) >= 1024 {
			break
		}
		data, err := readPrivate(filepath.Join(home, ".claude", "sessions", fmt.Sprintf("%d.topology.json", source.PID)), 16384)
		if err != nil {
			continue
		}
		var report topologyReport
		if json.Unmarshal(data, &report) != nil {
			continue
		}
		for _, link := range validateTopology(report, source, live, now) {
			if len(result) == 1024 {
				break
			}
			result = append(result, link)
		}
	}
	return result
}
