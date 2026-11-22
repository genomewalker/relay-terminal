package daemon

import "testing"

func TestPromptOwnerFallbackAdmitsOnlyAnUnnamedLiveFrontend(t *testing.T) {
	cases := []struct {
		name     string
		evidence promptOwnerEvidence
		want     promptOwnerChoice
	}{
		{"startup dialog with no records", promptOwnerEvidence{Provider: "claude", PID: 2125132}, promptOwnerPreSession},
		{"codex startup dialog with no records", promptOwnerEvidence{Provider: "codex", PID: 4242}, promptOwnerPreSession},
		// a83d388b: both records still name the previous Claude (607606).
		{"stale records for an earlier process", promptOwnerEvidence{Provider: "claude", PID: 2125132}, promptOwnerPreSession},
		{"verified bootstrap for this process", promptOwnerEvidence{Provider: "claude", PID: 7, BootstrapVerified: true, BootstrapNamesPID: true}, promptOwnerBootstrap},
		{"bootstrap conflicts with binding session", promptOwnerEvidence{Provider: "claude", PID: 7, BootstrapVerified: true, BootstrapNamesPID: true, SessionConflict: true}, promptOwnerRefuse},
		{"codex never uses a bootstrap", promptOwnerEvidence{Provider: "codex", PID: 7, BootstrapVerified: true}, promptOwnerRefuse},
		{"incomplete verified binding for this process", promptOwnerEvidence{Provider: "claude", PID: 7, RecordNamesPID: true, StoredNamesPID: true}, promptOwnerRefuse},
		{"unverifiable stored binding for this process", promptOwnerEvidence{Provider: "codex", PID: 7, StoredNamesPID: true}, promptOwnerRefuse},
		{"unverifiable bootstrap for this process", promptOwnerEvidence{Provider: "claude", PID: 7, BootstrapNamesPID: true}, promptOwnerRefuse},
		{"no frontend", promptOwnerEvidence{Provider: "claude", PID: 0}, promptOwnerRefuse},
		{"unknown provider", promptOwnerEvidence{Provider: "shell", PID: 7}, promptOwnerRefuse},
	}
	for _, test := range cases {
		if got := promptOwnerFallback(test.evidence); got != test.want {
			t.Errorf("%s: got %d, want %d", test.name, got, test.want)
		}
	}
}
