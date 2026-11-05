package main

import (
	"sync"
	"testing"
)

func TestDesktopSignalStopIsConcurrentAndIdempotent(t *testing.T) {
	for i := 0; i < 64; i++ {
		ctx, stop, err := desktopSignalContext()
		if err != nil {
			t.Fatal(err)
		}
		var group sync.WaitGroup
		group.Add(2)
		for actor := 0; actor < 2; actor++ {
			go func() {
				defer group.Done()
				for step := 0; step < 4; step++ {
					stop()
				}
			}()
		}
		group.Wait()
		select {
		case <-ctx.Done():
		default:
			t.Fatal("stop did not cancel desktop context")
		}
		stop()
	}
}
