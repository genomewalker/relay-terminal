package daemon

import (
	"encoding/json"
	"errors"
)

type nativeCodexTranscriptCandidate struct {
	path, session, identity, parent, kind string
}

// Thread relationships are read only from kernel-opened transcript headers.
// Unknown metadata stays a candidate so it cannot silently resolve ambiguity.
func nativeCodexOpenTranscriptMetadata(row []byte) (string, string, string, error) {
	if len(row) > 1048576 || !rotationSourceJSONUnambiguous(row) {
		return "", "", "", errors.New("native transcript metadata invalid")
	}
	var metadata struct {
		Type    string `json:"type"`
		Payload struct {
			ID     string          `json:"id"`
			Parent string          `json:"parent_thread_id"`
			Forked string          `json:"forked_from_id"`
			Source json.RawMessage `json:"source"`
		} `json:"payload"`
	}
	if json.Unmarshal(row, &metadata) != nil || metadata.Type != "session_meta" || !validSessionID.MatchString(metadata.Payload.ID) {
		return "", "", "", errors.New("native transcript session invalid")
	}
	id := metadata.Payload.ID
	var source string
	if json.Unmarshal(metadata.Payload.Source, &source) == nil {
		if (source == "cli" || source == "vscode") && metadata.Payload.Parent == "" {
			return id, "", "root", nil
		}
		return id, "", "unknown", nil
	}
	var nested struct {
		Subagent *struct {
			ThreadSpawn *struct {
				Parent string `json:"parent_thread_id"`
				Depth  int    `json:"depth"`
			} `json:"thread_spawn"`
		} `json:"subagent"`
	}
	if json.Unmarshal(metadata.Payload.Source, &nested) != nil || nested.Subagent == nil || nested.Subagent.ThreadSpawn == nil {
		return id, "", "unknown", nil
	}
	spawn := nested.Subagent.ThreadSpawn
	if !validSessionID.MatchString(spawn.Parent) || spawn.Parent == id || spawn.Depth < 1 || spawn.Depth > 64 ||
		metadata.Payload.Parent != spawn.Parent || (metadata.Payload.Forked != "" && metadata.Payload.Forked != spawn.Parent) {
		return id, "", "unknown", nil
	}
	return id, spawn.Parent, "child", nil
}

// Multiple open files are acceptable only for one explicit main thread and its
// explicitly linked descendants. Two main threads, unknown relationships,
// missing parents, duplicate identities and cycles remain ambiguous.
func selectNativeCodexOpenTranscript(candidates map[string]nativeCodexTranscriptCandidate) (string, string, string, error) {
	unavailable := errors.New("no unique open native Codex transcript")
	if len(candidates) == 0 || len(candidates) > 64 {
		return "", "", "", unavailable
	}
	if len(candidates) == 1 {
		for _, value := range candidates {
			if value.kind == "child" {
				return "", "", "", unavailable
			}
			return value.path, value.session, value.identity, nil
		}
	}
	bySession := map[string]nativeCodexTranscriptCandidate{}
	var root nativeCodexTranscriptCandidate
	roots := 0
	for _, value := range candidates {
		if _, exists := bySession[value.session]; exists {
			return "", "", "", unavailable
		}
		bySession[value.session] = value
		if value.kind == "root" {
			root = value
			roots++
		}
	}
	if roots != 1 {
		return "", "", "", unavailable
	}
	for _, value := range candidates {
		if value.session == root.session {
			continue
		}
		seen := map[string]bool{}
		current := value
		for current.session != root.session {
			if current.kind != "child" || seen[current.session] || len(seen) >= 64 {
				return "", "", "", unavailable
			}
			seen[current.session] = true
			parent, exists := bySession[current.parent]
			if !exists {
				return "", "", "", unavailable
			}
			current = parent
		}
	}
	return root.path, root.session, root.identity, nil
}
