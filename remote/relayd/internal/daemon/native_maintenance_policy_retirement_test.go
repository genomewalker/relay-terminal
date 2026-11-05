package daemon

import (
	"strings"
	"testing"
)

// Enumerates the actual constructor's local/remote, host, namespace and
// permission-policy boundary. It is not a model of provider admission.
func TestNativeMaintenancePolicyBoundedEnumeration(t *testing.T) {
	explored := 0
	approvals := []string{"never", "on-request", "on-failure", "untrusted", "unknown"}
	sandboxes := []string{"danger-full-access", "workspace-write", "read-only", "unknown"}
	for ai, approval := range approvals {
		for si, sandbox := range sandboxes {
			for _, remote := range []bool{false, true} {
				for _, linux := range []bool{false, true} {
					for _, ns := range []string{"0", "1"} {
						for rootsCase := 0; rootsCase < 4; rootsCase++ {
							for flagCase := 0; flagCase < 4; flagCase++ {
								explored++
								ctx := mrContext()
								ctx.Set("approval_policy", approval)
								policy := pyObj("type", sandbox)
								ctx.Set("sandbox_policy", policy)
								switch rootsCase {
								case 1:
									policy.Set("writable_roots", pyListOf("/exact root"))
								case 2:
									policy.Set("writable_roots", pyListOf("relative"))
								case 3:
									roots := pyListOf()
									for n := 0; n < 17; n++ {
										roots.items = append(roots.items, "/root")
									}
									policy.Set("writable_roots", roots)
								}
								switch flagCase {
								case 1:
									policy.Set("network_access", true)
								case 2:
									policy.Set("network_access", false)
								case 3:
									policy.Set("network_access", int64(0))
								}
								extended := rootsCase != 0 || flagCase != 0
								allowed := ai < 4 && si < 3 && !(remote && linux && ns == "0" && sandbox != "danger-full-access")
								if sandbox != "workspace-write" && extended {
									allowed = false
								}
								if sandbox == "workspace-write" && (remote && extended || rootsCase == 2 || rootsCase == 3 || flagCase == 3) {
									allowed = false
								}
								var command string
								e := phRaised(t, func() {
									command = phCodexResumeWithNamespaces([]string{"codex"}, "session-123", ctx, []string{"/exact/relayd", "agent", "codex"}, "", linux, remote, func() string { return ns })
								})
								if (e == nil) != allowed {
									t.Fatalf("state %d a=%q s=%q remote=%v linux=%v ns=%s roots=%d flag=%d: %v", explored, approval, sandbox, remote, linux, ns, rootsCase, flagCase, e)
								}
								if !allowed {
									continue
								}
								words := phShlexSplit(command)
								mrEq(t, words[:3], []string{"/exact/relayd", "agent", "codex"})
								mrEq(t, words[len(words)-2:], []string{"resume", "session-123"})
								mrHas(t, words, "--ask-for-approval", !remote)
								mrHas(t, words, "--sandbox", !remote)
								if !remote {
									mrHas(t, words, approval, true)
									mrHas(t, words, sandbox, true)
									if rootsCase == 1 {
										mrHas(t, words, "/exact root", true)
									}
									if flagCase == 1 {
										mrHas(t, words, "sandbox_workspace_write.network_access=true", true)
									}
									if flagCase == 2 {
										mrHas(t, words, "sandbox_workspace_write.network_access=false", true)
									}
								}
							}
						}
					}
				}
			}
		}
	}
	mrEq(t, explored, 2560)
	t.Logf("%d actual policy states explored; constructor output/hold checked after each", explored)
}

func FuzzNativeMaintenanceLocalPolicy(f *testing.F) {
	for _, seed := range []string{`{"approval_policy":"never","sandbox_policy":{"type":"danger-full-access"},"cwd":"/work"}`, `{"approval_policy":"on-request","sandbox_policy":{"type":"workspace-write","writable_roots":["/exact root"],"network_access":false},"cwd":"/work"}`, `{"approval_policy":"never","sandbox_policy":{"type":"workspace-write","network_access":0},"cwd":"/work"}`, `{"approval_policy":"never","sandbox_policy":{"type":"workspace-write","writable_roots":["relative"]},"cwd":"/work"}`, `{"approval_policy":"never","sandbox_policy":{"type":"danger-full-access"},"cwd":"/literal/$(not-run)"}`} {
		f.Add(seed, false)
		f.Add(seed, true)
	}
	f.Fuzz(func(t *testing.T, raw string, remote bool) {
		if len(raw) > 16<<10 {
			return
		}
		ctx, err := pyDecode([]byte(raw))
		if err != nil {
			return
		}
		var command string
		if phRaised(t, func() {
			command = phCodexResumeWithNamespaces([]string{"codex"}, "exact-session", ctx, []string{"/exact/relayd", "agent", "codex"}, "", false, remote, func() string { return "1" })
		}) != nil {
			return
		}
		if len(command) > 8192 || phHasControl(command) {
			t.Fatal("unbounded or control-bearing command")
		}
		words := phShlexSplit(command)
		mrEq(t, words[:3], []string{"/exact/relayd", "agent", "codex"})
		mrEq(t, words[len(words)-2:], []string{"resume", "exact-session"})
		mrHas(t, words, "--ask-for-approval", !remote)
		mrHas(t, words, "--sandbox", !remote)
		directory := phGet(ctx, "cwd", nil)
		path, ok := directory.(string)
		if !ok || !strings.HasPrefix(path, "/") {
			t.Fatal("unsafe working directory accepted")
		}
		mrHas(t, words, path, true)
		if remote {
			for _, word := range words {
				if strings.HasPrefix(word, "sandbox_workspace_write.") {
					t.Fatal("remote policy silently replaced")
				}
			}
		}
	})
}
