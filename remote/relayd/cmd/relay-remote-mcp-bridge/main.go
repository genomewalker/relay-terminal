package main

import (
	"context"
	"flag"
	"fmt"
	"github.com/relay-terminal/relayd/internal/remotemcpbridge"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	host := flag.String("host", "dandy-07", "owning remote host")
	port := flag.Int("port", 48473, "loopback port")
	flag.Parse()
	if *port < 1 || *port > 65535 {
		fmt.Fprintln(os.Stderr, "invalid bridge port")
		os.Exit(2)
	}
	home, e := os.UserHomeDir()
	if e != nil {
		fail(e)
	}
	token, e := remotemcpbridge.LoadCapability(home, *host, *port)
	if e != nil {
		fail(e)
	}
	desktop := remotemcpbridge.HTTPDesktop{}
	bridge := remotemcpbridge.New(*host, token, desktop.Call)
	listener, e := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", *port))
	if e != nil {
		fail(e)
	}
	server := &http.Server{Handler: bridge, ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 10 * time.Second, IdleTimeout: 10 * time.Second}
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer cancel()
	done := make(chan struct{})
	go func() { <-ctx.Done(); _ = server.Shutdown(context.Background()); close(done) }()
	fmt.Println("Scoped remote MCP bridge listening on loopback", *port)
	e = server.Serve(listener)
	if e != nil && e != http.ErrServerClosed {
		fail(e)
	}
	if ctx.Err() != nil {
		<-done
	}
}
func fail(e error) { fmt.Fprintln(os.Stderr, e); os.Exit(1) }
