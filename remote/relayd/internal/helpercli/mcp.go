package helpercli

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// MCPBootstrap constructs the exact exec environment without reading credentials itself.
func MCPBootstrap(home string, data []byte, env []string) (string, []string, []string, error) {
	m, e := jsonObject(data, maxDocument)
	if e != nil {
		return "", nil, nil, e
	}
	token, ok := m["token"].(string)
	if !ok || strings.ContainsRune(token, 0) {
		return "", nil, nil, errors.New("MCP token must be a string without NUL")
	}
	p, e := required(m, "port")
	if e != nil {
		return "", nil, nil, e
	}
	var port string
	switch v := p.(type) {
	case string:
		port = v
	case json.Number:
		port = string(v)
		if strings.ContainsAny(port, ".eE") {
			n, err := strconv.ParseFloat(port, 64)
			if err != nil && !math.IsInf(n, 0) {
				return "", nil, nil, err
			}
			switch {
			case math.IsInf(n, 1):
				port = "inf"
			case math.IsInf(n, -1):
				port = "-inf"
			case n == 0 || math.Abs(n) >= 1e-4 && math.Abs(n) < 1e16:
				port = strconv.FormatFloat(n, 'f', -1, 64)
				if !strings.Contains(port, ".") {
					port += ".0"
				}
			default:
				port = strconv.FormatFloat(n, 'e', -1, 64)
			}
		}
	case bool:
		if v {
			port = "True"
		} else {
			port = "False"
		}
	case nil:
		port = "None"
	default:
		return "", nil, nil, errors.New("MCP port must be a scalar")
	}
	if strings.ContainsRune(port, 0) {
		return "", nil, nil, errors.New("MCP port contains NUL")
	}
	if home == "" {
		return "", nil, nil, errors.New("home unavailable")
	}
	out := make([]string, 0, len(env)+2)
	for _, s := range env {
		if !strings.HasPrefix(s, "RELAY_MCP_TOKEN=") && !strings.HasPrefix(s, "RELAY_MCP_PORT=") {
			out = append(out, s)
		}
	}
	out = append(out, "RELAY_MCP_TOKEN="+token, "RELAY_MCP_PORT="+port)
	return filepath.Join(home, ".local/bin/relay-mcp"), []string{"relay-mcp"}, out, nil
}
func RunMCPDesktop() error {
	home, e := os.UserHomeDir()
	if e != nil {
		return e
	}
	data, e := boundedFile(filepath.Join(home, ".relay-mcp-desktop.json"), maxDocument)
	if e != nil {
		return e
	}
	p, args, env, e := MCPBootstrap(home, data, os.Environ())
	if e != nil {
		return e
	}
	if e = syscall.Exec(p, args, env); e != nil {
		return fmt.Errorf("exec relay-mcp: %w", e)
	}
	return nil
}
