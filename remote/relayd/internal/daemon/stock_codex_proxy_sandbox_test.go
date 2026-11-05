package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

const sandboxThread = "01a12f1b-7c35-7681-9f90-9ef906a1a59e"

func writeProxyRollout(t *testing.T, home, thread, sandbox string) {
	t.Helper()
	directory := filepath.Join(home, "sessions", "2026", "10", "14")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	body := `{"type":"session_meta","payload":{"id":"` + thread + `"}}` + "\n" +
		`{"type":"turn_context","payload":{"approval_policy":"never","sandbox_policy":{"type":"` + sandbox + `"}}}` + "\n"
	if err := os.WriteFile(filepath.Join(directory, "rollout-2026-10-14T00-00-00-"+thread+".jsonl"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func resumeParams(t *testing.T, data []byte) map[string]json.RawMessage {
	t.Helper()
	var frame struct {
		ID     json.RawMessage            `json:"id"`
		Method string                     `json:"method"`
		Params map[string]json.RawMessage `json:"params"`
	}
	if err := json.Unmarshal(data, &frame); err != nil || frame.Method != "thread/resume" || string(frame.ID) != "7" {
		t.Fatalf("frame identity changed: %s", data)
	}
	return frame.Params
}

func TestStockCodexProxyRestoresSavedSandboxOnUnsetResume(t *testing.T) {
	home := t.TempDir()
	writeProxyRollout(t, home, sandboxThread, "danger-full-access")
	p := &codexProxy{codexHome: home}
	for _, request := range []string{
		`{"id":7,"method":"thread/resume","params":{"threadId":"` + sandboxThread + `","model":"gpt-rosalind-5.5","cwd":"/work"}}`,
		`{"id":7,"method":"thread/resume","params":{"threadId":"` + sandboxThread + `","sandbox":null,"path":"","config":{"model_reasoning_effort":"xhigh"}}}`,
	} {
		params := resumeParams(t, p.restoreResumeSandbox([]byte(request)))
		if string(params["sandbox"]) != `"danger-full-access"` || string(params["threadId"]) != `"`+sandboxThread+`"` {
			t.Fatalf("%s: got %v", request, params)
		}
		if _, ok := params["approvalPolicy"]; ok {
			t.Fatal("approval policy was injected")
		}
		var original map[string]json.RawMessage
		_ = json.Unmarshal([]byte(request), &original)
		var originalParams map[string]json.RawMessage
		_ = json.Unmarshal(original["params"], &originalParams)
		for key, value := range originalParams {
			if key != "sandbox" && string(params[key]) != string(value) {
				t.Fatalf("%s changed: %s", key, params[key])
			}
		}
	}

	// A selection still binds the rewritten resume exactly as before.
	selection := codexProxySelection{wanted: sandboxThread, pending: map[string]uint64{}}
	rewritten := p.restoreResumeSandbox([]byte(`{"id":7,"method":"thread/resume","params":{"threadId":"` + sandboxThread + `"}}`))
	proxyRPC(t, &selection, true, string(rewritten))
	proxyRPC(t, &selection, false, `{"id":7,"result":{"thread":{"id":"`+sandboxThread+`","path":"/tmp/r.jsonl"}}}`)
	if selection.session != sandboxThread || !selection.confirmedResume {
		t.Fatalf("rewritten resume did not bind: %#v", selection)
	}
}

func TestStockCodexProxyLeavesExplicitOrUnprovenResumeUnchanged(t *testing.T) {
	home := t.TempDir()
	writeProxyRollout(t, home, sandboxThread, "danger-full-access")
	other := "01a13c87-83d1-76f3-a38a-1b2f0953416e"
	p := &codexProxy{codexHome: home}
	for _, request := range []string{
		`{"id":7,"method":"thread/resume","params":{"threadId":"` + sandboxThread + `","sandbox":"read-only"}}`,
		`{"id":7,"method":"thread/resume","params":{"threadId":"` + sandboxThread + `","config":{"sandbox_mode":"workspace-write"}}}`,
		`{"id":7,"method":"thread/resume","params":{"threadId":"` + sandboxThread + `","config":{"sandbox_workspace_write.network_access":true}}}`,
		`{"id":7,"method":"thread/resume","params":{"threadId":"` + sandboxThread + `","path":"/elsewhere/rollout.jsonl"}}`,
		`{"id":7,"method":"thread/resume","params":{"threadId":"` + sandboxThread + `","history":[]}}`,
		`{"id":7,"method":"thread/resume","params":{"threadId":"` + other + `"}}`,
		`{"id":7,"method":"thread/resume","params":{"threadId":"not-a-thread"}}`,
		`{"id":7,"method":"thread/read","params":{"threadId":"` + sandboxThread + `"}}`,
		`{"id":7,"method":"turn/start","params":{"threadId":"` + sandboxThread + `"}}`,
		`{"method":"initialized"}`,
		`not json`,
	} {
		if got := p.restoreResumeSandbox([]byte(request)); string(got) != request {
			t.Fatalf("%s: rewritten to %s", request, got)
		}
	}
	// An unknown recorded sandbox is not forwarded.
	unknown := t.TempDir()
	writeProxyRollout(t, unknown, sandboxThread, "external-sandbox")
	request := `{"id":7,"method":"thread/resume","params":{"threadId":"` + sandboxThread + `"}}`
	if got := (&codexProxy{codexHome: unknown}).restoreResumeSandbox([]byte(request)); string(got) != request {
		t.Fatalf("unknown sandbox forwarded: %s", got)
	}
	if got := (&codexProxy{}).restoreResumeSandbox([]byte(request)); string(got) != request {
		t.Fatalf("missing Codex home rewrote: %s", got)
	}
}
