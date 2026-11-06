package researchworker

import (
	"bufio"
	"encoding/json"
	"os"
	"testing"
)

const fakeReaderArgument = "relay-fake-evidence-reader"

// TestMain lets this test binary act as a minimal stdio MCP evidence reader
// when Codex starts it with fakeReaderArgument. It offers read, search and a
// write tool that the plan's enabled_tools must keep from the model.
func TestMain(m *testing.M) {
	if len(os.Args) > 1 && os.Args[len(os.Args)-1] == fakeReaderArgument {
		serveFakeReader(os.Args[len(os.Args)-2])
		os.Exit(0)
	}
	if scenario := os.Getenv("FAKE_WORKER_SCENARIO"); scenario != "" {
		os.Exit(fakeWorker(scenario))
	}
	os.Exit(m.Run())
}

func serveFakeReader(logPath string) {
	log, _ := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	defer log.Close()
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1<<20), 1<<20)
	out := json.NewEncoder(os.Stdout)
	tool := func(name string) map[string]any {
		return map[string]any{"name": name, "description": "fake evidence " + name, "inputSchema": map[string]any{"type": "object", "properties": map[string]any{}}}
	}
	for scanner.Scan() {
		var message struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params struct {
				ProtocolVersion string `json:"protocolVersion"`
			} `json:"params"`
		}
		if json.Unmarshal(scanner.Bytes(), &message) == nil && log != nil {
			_, _ = log.WriteString(message.Method + "\n")
		}
		if len(message.ID) == 0 {
			continue
		}
		reply := map[string]any{"jsonrpc": "2.0", "id": message.ID}
		switch message.Method {
		case "initialize":
			reply["result"] = map[string]any{"protocolVersion": message.Params.ProtocolVersion, "capabilities": map[string]any{"tools": map[string]any{}}, "serverInfo": map[string]any{"name": "fake-evidence", "version": "0"}}
		case "tools/list":
			reply["result"] = map[string]any{"tools": []any{tool("read"), tool("search"), tool("write")}}
		case "resources/list":
			reply["result"] = map[string]any{"resources": []any{}}
		case "resources/templates/list":
			reply["result"] = map[string]any{"resourceTemplates": []any{}}
		default:
			reply["error"] = map[string]any{"code": -32601, "message": "not supported"}
		}
		_ = out.Encode(reply)
	}
}
