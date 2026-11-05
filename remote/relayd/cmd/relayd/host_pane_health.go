package main

import (
	"context"
	"flag"
	"io"
	"os"
	"time"

	"github.com/relay-terminal/relayd/internal/daemon"
)

func runPaneHealthControllerRPC(arguments []string) {
	flags := flag.NewFlagSet("pane-health-controller-rpc", flag.ExitOnError)
	socket := flags.String("socket", defaultSocket(), "existing host supervisor Unix socket")
	_ = flags.Parse(arguments)
	if flags.NArg() != 0 {
		fatal("usage: relayd pane-health-controller-rpc [--socket PATH]")
	}
	data, err := io.ReadAll(io.LimitReader(os.Stdin, 262145))
	if err != nil || len(data) > 262144 {
		fatal("bounded host health request required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	result, err := daemon.RequestHostPaneHealthController(ctx, *socket, data)
	if err != nil {
		fatal(err.Error())
	}
	_, _ = os.Stdout.Write(append(result, '\n'))
}
