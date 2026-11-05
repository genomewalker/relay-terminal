//go:build !darwin

package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"
)

func desktopSignalContext() (context.Context, func(), error) {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	return ctx, stop, nil
}
