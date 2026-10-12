package peernet

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Discovery intentionally omits socket paths and authentication material.
type DiscoveredPeer struct {
	Name    string `json:"name"`
	Session string `json:"sessionId"`
	PID     int    `json:"pid"`
	Start   string `json:"procStart"`
}

type Discovery struct {
	Peers     []DiscoveredPeer `json:"peers"`
	Truncated bool             `json:"truncated"`
	Links     []DiscoveredLink `json:"links"`
	Teams     []ClaudeTeam     `json:"teams"`
}

// Discover never registers, connects to, or alters a provider session.
func Discover(home string) (Discovery, error) {
	result := Discovery{Peers: []DiscoveredPeer{}, Links: []DiscoveredLink{}}
	records := []Record{}
	dir := filepath.Join(home, ".claude", "sessions")
	f, err := os.Open(dir)
	if errors.Is(err, os.ErrNotExist) {
		return result, nil
	}
	if err != nil {
		return result, err
	}
	defer f.Close()
	entries, err := f.ReadDir(1025)
	if err != nil && !errors.Is(err, io.EOF) {
		return result, err
	}
	if len(entries) > 1024 {
		result.Truncated = true
		entries = entries[:1024]
	}
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasSuffix(name, ".json") {
			continue
		}
		pid, err := strconv.Atoi(strings.TrimSuffix(name, ".json"))
		if err != nil || pid <= 0 {
			continue
		}
		data, err := readPrivate(filepath.Join(dir, name), 16384)
		if err != nil {
			continue
		}
		var record Record
		if json.Unmarshal(data, &record) != nil {
			continue
		}
		// A mailbox is a route, not an additional agent. Link observations
		// represent it separately; never inflate the discovered agent inventory.
		if record.RelayProxy {
			continue
		}
		live, err := Resolve(home, record.Name, record.Session, pid)
		if err != nil {
			continue
		}
		result.Peers = append(result.Peers, DiscoveredPeer{live.Name, live.Session, live.PID, live.Start})
		records = append(records, live)
	}
	sort.Slice(result.Peers, func(i, j int) bool {
		if result.Peers[i].Name == result.Peers[j].Name {
			return result.Peers[i].PID < result.Peers[j].PID
		}
		return result.Peers[i].Name < result.Peers[j].Name
	})
	result.Links = discoverTopology(home, records, time.Now())
	var partial bool
	result.Teams, partial = discoverClaudeTeams(home, records)
	result.Truncated = result.Truncated || partial
	return result, nil
}
