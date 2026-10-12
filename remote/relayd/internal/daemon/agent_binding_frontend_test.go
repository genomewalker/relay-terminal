package daemon

import "testing"

func TestBindingProducerIsOriginalFrontend(t *testing.T) {
	for _, test := range []struct {
		name     string
		producer agentProducer
		provider string
		pid      int
		want     bool
	}{
		{"original Claude", agentProducer{Provider: "claude", ProcessID: 1981468}, "claude", 1981468, true},
		{"nested Claude cannot replace original", agentProducer{Provider: "claude", ProcessID: 519935}, "claude", 1981468, false},
		{"original Codex", agentProducer{Provider: "codex", ProcessID: 42}, "codex", 42, true},
		{"provider changed", agentProducer{Provider: "claude", ProcessID: 42}, "codex", 42, false},
		{"frontend absent", agentProducer{Provider: "claude", ProcessID: 42}, "", 0, false},
		{"invalid process", agentProducer{Provider: "claude", ProcessID: 1}, "claude", 1, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := bindingProducerIsOriginalFrontend(test.producer, test.provider, test.pid); got != test.want {
				t.Fatalf("binding original frontend match = %v, want %v", got, test.want)
			}
		})
	}
}
