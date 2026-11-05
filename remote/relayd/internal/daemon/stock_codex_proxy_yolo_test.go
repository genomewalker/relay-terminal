package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/relay-terminal/relayd/internal/agentlaunch"
)

func TestStockCodexResumeAppliesUserDefaultInsteadOfOldWorkspaceMode(t *testing.T) {
	home := t.TempDir()
	writeProxyRollout(t, home, sandboxThread, "workspace-write")
	if err := os.WriteFile(filepath.Join(home, "relay-launch-defaults.json"), []byte(`{"version":1,"sandbox_mode":"danger-full-access","approval_policy":"never"}`), 0600); err != nil { t.Fatal(err) }
	request := []byte(`{"id":7,"method":"thread/resume","params":{"threadId":"`+sandboxThread+`","model":"gpt-rosalind-5.5"}}`)
	data, err := restoreCodexResumeSandbox(request, home)
	if err != nil { t.Fatal(err) }
	params := resumeParams(t, data)
	if string(params["sandbox"]) != `"danger-full-access"` || string(params["approvalPolicy"]) != `"never"` || string(params["model"]) != `"gpt-rosalind-5.5"` {
		t.Fatalf("resumed thread did not get YOLO: %s", data)
	}
	// A launch's explicit choice beats the host default, including approvals.
	explicit := &agentlaunch.CodexPermissions{SandboxMode:"read-only", ApprovalPolicy:"on-request"}
	data, err = restoreCodexResumePermissions(request, home, explicit)
	if err != nil { t.Fatal(err) }
	params = resumeParams(t, data)
	if string(params["sandbox"]) != `"read-only"` || string(params["approvalPolicy"]) != `"on-request"` { t.Fatalf("explicit launch choice lost: %s", data) }
	// The frontend's explicit choice also survives byte-for-byte.
	request = []byte(`{"id":7,"method":"thread/resume","params":{"threadId":"`+sandboxThread+`","sandbox":"workspace-write","approvalPolicy":"on-request"}}`)
	data, err = restoreCodexResumePermissions(request, home, explicit)
	if err != nil || string(data) != string(request) { t.Fatalf("explicit frontend changed: %s %v", data,err) }
}

func TestStockCodexResumeKeepsExplicitApprovalWithUserDefault(t *testing.T) {
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, "relay-launch-defaults.json"), []byte(`{"version":1,"sandbox_mode":"danger-full-access","approval_policy":"never"}`), 0600); err != nil { t.Fatal(err) }
	request := []byte(`{"id":7,"method":"thread/resume","params":{"threadId":"`+sandboxThread+`","approvalPolicy":"on-request"}}`)
	data, err := restoreCodexResumeSandbox(request, home)
	if err != nil { t.Fatal(err) }
	params := resumeParams(t, data)
	if string(params["sandbox"]) != `"danger-full-access"` || string(params["approvalPolicy"]) != `"on-request"` { t.Fatalf("explicit approval lost: %s",data) }
}

func TestStockCodexInitialLaunchModeOverridesRemoteTUICachedDefaults(t *testing.T) {
	policy := &agentlaunch.CodexPermissions{SandboxMode:"danger-full-access",ApprovalPolicy:"never"}
	proxy := &codexProxy{codexHome:t.TempDir(),resumePermissions:policy}
	for _, method := range []string{"thread/start","thread/resume"} {
		request := []byte(`{"id":7,"method":"`+method+`","params":{"threadId":"`+sandboxThread+`","sandbox":"workspace-write","approvalPolicy":"on-request"}}`)
		data := proxy.restoreResumeSandbox(request)
		var frame struct { Params map[string]string `json:"params"` }
		if err := json.Unmarshal(data,&frame);err!=nil {t.Fatal(err)}
		if frame.Params["sandbox"]!="danger-full-access" || frame.Params["approvalPolicy"]!="never" {t.Fatalf("cached TUI defaults won: %s",data)}
		// Once the primary task is established, an explicit in-app choice wins.
		proxy.selection.session = sandboxThread
		if got:=proxy.restoreResumeSandbox(request);string(got)!=string(request){t.Fatalf("later permission choice rewritten: %s",got)}
		proxy.selection.session = ""
	}
}
