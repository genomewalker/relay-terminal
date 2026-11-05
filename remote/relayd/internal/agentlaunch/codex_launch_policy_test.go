package agentlaunch

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func launchDefaults(t *testing.T, home, text string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(home, "relay-launch-defaults.json"), []byte(text), 0600); err != nil {
		t.Fatal(err)
	}
}

const yoloDefaults = `{"version":1,"sandbox_mode":"danger-full-access","approval_policy":"never"}`

func TestCodexLaunchDefaultsApplyToNewAndResumedThreads(t *testing.T) {
	home := t.TempDir()
	launchDefaults(t, home, yoloDefaults)
	for _, arguments := range [][]string{nil, {"--model", "gpt-rosalind-5.5", "resume", "01a13c87-83d1-76f3-a38a-1b2f0953416e"}} {
		frontend, policy, err := ManagedCodexLaunchPolicy(home, arguments)
		if err != nil || policy.SandboxMode != "danger-full-access" || policy.ApprovalPolicy != "never" || len(frontend) != len(arguments) {
			t.Fatalf("default was not applied without changing conversation args: %q %+v %v", frontend, policy, err)
		}
	}
}

func TestCodexExplicitPermissionsOverrideDefaultsAndNeverReachRemoteFrontend(t *testing.T) {
	home := t.TempDir()
	launchDefaults(t, home, yoloDefaults)
	for _, arguments := range [][]string{
		{"--sandbox", "read-only", "--ask-for-approval", "on-request", "resume", "thread"},
		{"--sandbox=read-only", "--ask-for-approval=on-request", "resume", "thread"},
		{"-c", `sandbox_mode="read-only"`, "--config=approval_policy='on-request'", "resume", "thread"},
	} {
		frontend, policy, err := ManagedCodexLaunchPolicy(home, arguments)
		if err != nil || policy.SandboxMode != "read-only" || policy.ApprovalPolicy != "on-request" || !reflect.DeepEqual(frontend, []string{"resume", "thread"}) {
			t.Fatalf("explicit mode lost or sent to unsupported frontend: %q %+v %v", frontend, policy, err)
		}
	}
	frontend, policy, err := ManagedCodexLaunchPolicy(home, []string{"--full-auto", "-c", `model_reasoning_effort="xhigh"`})
	if err != nil || policy.SandboxMode != "workspace-write" || policy.ApprovalPolicy != "on-request" || !reflect.DeepEqual(frontend, []string{"-c", `model_reasoning_effort="xhigh"`}) {
		t.Fatalf("explicit full-auto or model config changed: %q %+v %v", frontend, policy, err)
	}
}

func TestCodexLaunchDefaultsRejectUnsafeOrMalformedPolicy(t *testing.T) {
	for _, text := range []string{`{`, yoloDefaults + `{}`, `{"version":2,"sandbox_mode":"danger-full-access","approval_policy":"never"}`, `{"version":1,"sandbox_mode":"unknown","approval_policy":"never"}`, `{"version":1,"sandbox_mode":"danger-full-access","approval_policy":"never","extra":true}`} {
		home := t.TempDir()
		launchDefaults(t, home, text)
		if _, _, err := ManagedCodexLaunchPolicy(home, nil); err == nil {
			t.Fatalf("invalid policy accepted: %s", text)
		}
	}
	home := t.TempDir()
	launchDefaults(t, home, yoloDefaults)
	path := filepath.Join(home, "relay-launch-defaults.json")
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := CodexLaunchDefaults(home); err == nil {
		t.Fatal("public policy accepted")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("missing", path); err != nil {
		t.Fatal(err)
	}
	if _, _, err := CodexLaunchDefaults(home); err == nil {
		t.Fatal("symlink policy accepted")
	}
}

func TestCodexLaunchPolicyKeepsLegacyBehaviorWithoutUserDefault(t *testing.T) {
	frontend, policy, err := ManagedCodexLaunchPolicy(t.TempDir(), []string{"--model", "fixture"})
	if err != nil || !reflect.DeepEqual(frontend, []string{"--model", "fixture"}) || policy != (CodexPermissions{}) {
		t.Fatalf("missing opt-in changed legacy launch: %q %+v %v", frontend, policy, err)
	}
}
