package main

import (
	"context"
	"flag"
	"os"
	"os/signal"
	"syscall"

	"github.com/relay-terminal/relayd/internal/loopbackproxy"
)

// This standalone helper uses an existing native host job. It does not start,
// upgrade or stop a supervisor and never reads a pane's terminal input.
func runLoopbackProxy(arguments []string) {
	flags := flag.NewFlagSet("loopback-proxy", flag.ContinueOnError)
	port := flags.Int("port", 0, "fixed host-loopback TCP port")
	if err := flags.Parse(arguments); err != nil || len(flags.Args()) != 0 || *port < 1 || *port > 65535 {
		fatal("loopback-proxy requires --port in 1...65535")
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := loopbackproxy.Serve(ctx, *port, os.Stdin, os.Stdout); err != nil {
		fatal("loopback proxy unavailable: " + err.Error())
	}
}
