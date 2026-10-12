package daemon

import "testing"

func TestNativeFrontendProcessesNormalizesOnlyVerifiedCodexLauncher(t *testing.T) {
	original := map[int]string{10: "codex", 11: "codex", 12: "claude", 13: "codex"}
	normalized := nativeFrontendProcesses(original, func(pid int, _ map[int]string) int {
		if pid == 10 {
			return 11
		}
		if pid == 12 {
			return 13
		}
		return 0
	})
	if normalized[10] != "" || normalized[11] != "codex" || normalized[12] != "claude" || normalized[13] != "codex" {
		t.Fatal(normalized)
	}
	if original[10] != "codex" {
		t.Fatal("candidate inventory was mutated")
	}
}

func TestNativeFrontendProcessesRejectsMissingOrOtherProviderChild(t *testing.T) {
	processes := map[int]string{10: "codex", 12: "claude"}
	for _, child := range []int{0, 1, 10, 11, 12} {
		normalized := nativeFrontendProcesses(processes, func(int, map[int]string) int { return child })
		if normalized[10] != "codex" || normalized[12] != "claude" {
			t.Fatal("unverified launcher changed frontend", child, normalized)
		}
	}
}
