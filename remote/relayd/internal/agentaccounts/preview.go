package agentaccounts

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"path/filepath"
	"sort"
)

// MCPPreview lists what a sync would copy into an account: each main MCP
// server and the NAMES of its environment variables and headers, so the user
// can exclude servers whose secrets should stay in the main account. Values
// are never read into the preview.
type MCPPreview struct {
	Provider string             `json:"provider"`
	Label    string             `json:"label"`
	Servers  []MCPServerPreview `json:"servers"`
	// Fingerprint identifies exactly this list (names only, never values).
	// A sync given it refuses if the main configuration changed since.
	Fingerprint string `json:"fingerprint"`
}

type MCPServerPreview struct {
	Name       string   `json:"name"`
	EnvKeys    []string `json:"env_keys,omitempty"`
	HeaderKeys []string `json:"header_keys,omitempty"`
	Excluded   bool     `json:"excluded"`
}

func PreviewMCP(home string, account Account) (MCPPreview, error) {
	if account.Dir == "" {
		return MCPPreview{Provider: account.Provider, Label: account.Label, Servers: []MCPServerPreview{}},
			errors.New("the main account is the source of MCP servers")
	}
	var servers []MCPServerPreview
	if account.Provider == "claude" {
		raw, err := readJSONKey(filepath.Join(home, ".claude.json"), "mcpServers")
		if err != nil {
			return MCPPreview{}, errors.New("main Claude configuration unavailable: " + err.Error())
		}
		if servers, err = claudeServerKeys(raw); err != nil {
			return MCPPreview{}, err
		}
	} else {
		main, _, _, err := readCodexMain(filepath.Join(defaultRoot(home, "codex"), "config.toml"))
		if err != nil {
			return MCPPreview{}, err
		}
		if servers, err = codexServerKeys(main); err != nil {
			return MCPPreview{}, err
		}
	}
	return previewOf(account, servers)
}

// previewOf is the preview of servers, the main configuration's MCP servers
// as read. Sync computes it again from the bytes it syncs.
func previewOf(account Account, servers []MCPServerPreview) (MCPPreview, error) {
	preview := MCPPreview{Provider: account.Provider, Label: account.Label, Servers: []MCPServerPreview{}}
	for index := range servers {
		servers[index].Excluded = account.excludes(servers[index].Name)
	}
	sort.Slice(servers, func(i, j int) bool { return servers[i].Name < servers[j].Name })
	preview.Servers = append(preview.Servers, servers...)
	// The user's own exclusions may change after the review; the main
	// configuration's servers and key names may not.
	reviewed := make([]MCPServerPreview, len(servers))
	for index, server := range servers {
		server.Excluded = false
		reviewed[index] = server
	}
	data, err := json.Marshal(struct {
		Provider, Label, Dir string
		Servers              []MCPServerPreview
	}{account.Provider, account.Label, account.Dir, reviewed})
	if err != nil {
		return preview, err
	}
	sum := sha256.Sum256(data)
	preview.Fingerprint = hex.EncodeToString(sum[:])
	return preview, nil
}

// claudeServerKeys lists the servers of a main mcpServers value (nil: none).
func claudeServerKeys(raw json.RawMessage) ([]MCPServerPreview, error) {
	if raw == nil {
		return nil, nil
	}
	var servers map[string]struct {
		Env     map[string]json.RawMessage `json:"env"`
		Headers map[string]json.RawMessage `json:"headers"`
	}
	if json.Unmarshal(raw, &servers) != nil {
		return nil, errors.New("main Claude mcpServers is not an object")
	}
	var result []MCPServerPreview
	for name, server := range servers {
		result = append(result, MCPServerPreview{Name: name, EnvKeys: sortedKeys(server.Env), HeaderKeys: sortedKeys(server.Headers)})
	}
	return result, nil
}

// codexServerKeys lists the servers of a parsed main config.toml (nil: none).
func codexServerKeys(document *tomlDocument) ([]MCPServerPreview, error) {
	if document == nil {
		return nil, nil
	}
	servers, err := codexServers(document)
	if err != nil || servers == nil {
		return nil, err
	}
	result := make([]MCPServerPreview, 0, len(servers.keys))
	for _, name := range servers.keys {
		server := servers.table(name)
		preview := MCPServerPreview{Name: name, EnvKeys: tomlTableKeys(server.values["env"])}
		for _, headers := range []string{"http_headers", "env_http_headers"} {
			preview.HeaderKeys = append(preview.HeaderKeys, tomlTableKeys(server.values[headers])...)
		}
		preview.HeaderKeys = uniqueSorted(preview.HeaderKeys)
		result = append(result, preview)
	}
	return result, nil
}

// tomlTableKeys are the parsed keys of a table value (never value text).
func tomlTableKeys(value any) []string {
	table, ok := value.(*tomlTable)
	if !ok {
		return nil
	}
	return uniqueSorted(append([]string(nil), table.keys...))
}

func sortedKeys(values map[string]json.RawMessage) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	if len(keys) == 0 {
		return nil
	}
	return keys
}

func uniqueSorted(values []string) []string {
	if len(values) == 0 {
		return nil
	}
	sort.Strings(values)
	result := values[:0]
	for index, value := range values {
		if index == 0 || value != values[index-1] {
			result = append(result, value)
		}
	}
	return result
}
