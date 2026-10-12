// This test-only JSON adapter is not packaged in Relay. Native wire framing
// is exercised separately by loopbackproxy's end-to-end node tests.
package main

import (
	"bufio"
	"context"
	"github.com/relay-terminal/relayd/internal/loopbackproxy"
	"os"
	"os/signal"
	"sync"
	"syscall"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	manager := loopbackproxy.NewManager(ctx)
	defer manager.Close()
	go func() { <-ctx.Done(); os.Stdin.Close() }()
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 128<<10)
	var output sync.Mutex
	slots := make(chan struct{}, 64)
	for scanner.Scan() {
		payload := append([]byte(nil), scanner.Bytes()...)
		slots <- struct{}{}
		go func() {
			defer func() { <-slots }()
			_, response := manager.Handle(payload)
			output.Lock()
			os.Stdout.Write(append(response, '\n'))
			output.Unlock()
		}()
	}
}
