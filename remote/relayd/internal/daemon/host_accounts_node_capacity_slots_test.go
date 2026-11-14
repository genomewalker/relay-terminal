package daemon

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestNodeCapacityChecksRunAtMostFourAtOnce(t *testing.T) {
	var running, peak atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _ = withNodeCapacitySlot(context.Background(), func() ([]byte, error) {
				now := running.Add(1)
				for {
					old := peak.Load()
					if now <= old || peak.CompareAndSwap(old, now) {
						break
					}
				}
				time.Sleep(20 * time.Millisecond)
				running.Add(-1)
				return nil, nil
			})
		}()
	}
	wg.Wait()
	if got := peak.Load(); got != nodeCapacityConcurrency {
		t.Fatalf("peak concurrent capacity checks %d, want %d", got, nodeCapacityConcurrency)
	}
}

func TestNodeCapacityWaitEndsWithTheNode(t *testing.T) {
	release := make(chan struct{})
	for i := 0; i < nodeCapacityConcurrency; i++ {
		go withNodeCapacitySlot(context.Background(), func() ([]byte, error) { <-release; return nil, nil })
	}
	defer close(release)
	deadline := time.Now().Add(time.Second)
	for len(nodeCapacitySlots) < nodeCapacityConcurrency && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := withNodeCapacitySlot(ctx, func() ([]byte, error) { t.Error("ran without a slot"); return nil, nil }); err == nil {
		t.Fatal("queued check outlived its node")
	}
}
