package peernet

import (
	"encoding/json"
	"os"
	"path/filepath"
	"unicode"
)

type ClaudeMember struct {
	ID    string `json:"agentId"`
	Name  string `json:"name"`
	Type  string `json:"agentType"`
	Model string `json:"model,omitempty"`
}

type ClaudeTeam struct {
	Name        string         `json:"name"`
	LeadSession string         `json:"leadSessionId"`
	Members     []ClaudeMember `json:"members"`
}

func metadataText(s string, limit int) bool {
	if len(s) > limit {
		return false
	}
	for _, c := range s {
		if unicode.IsControl(c) {
			return false
		}
	}
	return true
}

// Team membership is descriptive metadata, never liveness or a messaging edge.
// Decode only whitelisted fields: team configs can also contain private prompts.
func discoverClaudeTeams(home string, records []Record) ([]ClaudeTeam, bool) {
	result := []ClaudeTeam{}
	live := map[string]int{}
	for _, r := range records {
		live[r.Session]++
	}
	dir := filepath.Join(home, ".claude", "teams")
	f, err := os.Open(dir)
	if err != nil {
		return result, false
	}
	defer f.Close()
	entries, _ := f.ReadDir(257)
	truncated := len(entries) > 256
	if truncated {
		entries = entries[:256]
	}
	for _, entry := range entries {
		if !entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
			continue
		}
		data, err := readPrivate(filepath.Join(dir, entry.Name(), "config.json"), 131072)
		if err != nil {
			continue
		}
		var team ClaudeTeam
		if json.Unmarshal(data, &team) != nil || live[team.LeadSession] != 1 ||
			!metadataText(team.Name, 128) || !identifier.MatchString(team.LeadSession) {
			continue
		}
		members := []ClaudeMember{}
		seen := map[string]bool{}
		for _, member := range team.Members {
			if member.ID == "" || seen[member.ID] || !metadataText(member.ID, 128) ||
				!metadataText(member.Name, 128) || !metadataText(member.Type, 64) || !metadataText(member.Model, 64) {
				continue
			}
			if len(members) == 16 {
				truncated = true
				break
			}
			seen[member.ID] = true
			members = append(members, member)
		}
		team.Members = members
		if len(result) == 16 {
			truncated = true
			break
		}
		result = append(result, team)
	}
	return result, truncated
}
