//go:build darwin

package daemon

import (
	"os"
	"testing"
)

// A worker with no agent descendants still sees the user's other panes in
// the kernel process snapshot. Their executable paths should cost no probes.
func BenchmarkDarwinEmptyWorkerDiscovery(b *testing.B) {
	for i := 0; i < b.N; i++ {
		descendantAgentProcesses(os.Getpid())
	}
}
