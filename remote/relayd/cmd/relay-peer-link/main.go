// relay-peer-link creates an explicit pair of native peer endpoints over SSH.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/relay-terminal/relayd/internal/peernet"
)

type duplex struct {
	io.Reader
	io.Writer
	close func() error
}

func (d duplex) Close() error { return d.close() }

func main() {
	if e := run(); e != nil {
		fmt.Fprintln(os.Stderr, "peer link offline:", e)
		os.Exit(1)
	}
}
func run() error {
	discover := flag.Bool("discover", false, "List verified local peer metadata without connecting")
	serve := flag.Bool("serve", false, "Serve framed stdin/stdout over SSH")
	home := flag.String("home", "", "Registry home (defaults to current user's home)")
	name := flag.String("name", "", "Exact local peer name")
	session := flag.String("session", "", "Exact local session ID")
	pid := flag.Int("pid", 0, "Exact local peer PID")
	label := flag.String("label", "", "Host label advertised to other endpoint")
	host := flag.String("host", "", "Configured SSH host alias")
	remoteBinary := flag.String("remote-binary", ".local/share/relay/peer-network/relay-peer-link", "Remote executable (home-relative path)")
	remoteName := flag.String("remote-name", "", "Exact remote peer name")
	remoteSession := flag.String("remote-session", "", "Exact remote session ID")
	remotePID := flag.Int("remote-pid", 0, "Exact remote peer PID")
	remoteStart := flag.String("remote-start", "", "Exact remote process start identity")
	remoteLabel := flag.String("remote-label", "", "Remote host label")
	expectedName := flag.String("expected-name", "", "Expected other endpoint (serve mode)")
	expectedSession := flag.String("expected-session", "", "Expected other session (serve mode)")
	retries := flag.Int("retries", 0, "Reconnect attempts after failure, 0..20; never replay messages")
	flag.Parse()
	if *home == "" {
		h, e := os.UserHomeDir()
		if e != nil {
			return e
		}
		*home = h
	}
	if *discover {
		if *serve || *host != "" {
			return fmt.Errorf("discovery must run locally on the target host")
		}
		result, err := peernet.Discover(*home)
		if err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(result)
	}
	c := peernet.Config{Home: *home, Name: *name, Session: *session, PID: *pid, Label: *label}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if *serve {
		c.ExpectedName = *expectedName
		c.ExpectedSession = *expectedSession
		return peernet.Run(ctx, duplex{os.Stdin, os.Stdout, os.Stdin.Close}, c, os.Stderr)
	}
	if *retries < 0 || *retries > 20 {
		return fmt.Errorf("retries must be between 0 and 20")
	}
	safe := regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]*$`)
	for _, v := range []string{*host, *remoteName, *remoteSession, *remoteLabel, *name, *session, *label} {
		if !safe.MatchString(v) {
			return fmt.Errorf("invalid remote identifier")
		}
	}
	if !regexp.MustCompile(`^[A-Za-z0-9_./-]+$`).MatchString(*remoteBinary) || (*remoteBinary)[0] == '-' || *remotePID <= 0 || len(*remoteStart) > 128 || strings.ContainsAny(*remoteStart, "\r\n\x00") {
		return fmt.Errorf("invalid remote executable or PID")
	}
	// Arguments also reach a remote shell: restrict identifiers and quote the path.
	args := []string{"-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3", "--", *host, "exec '" + *remoteBinary + "' --serve --name " + *remoteName + " --session " + *remoteSession + " --pid " + strconv.Itoa(*remotePID) + " --label " + *remoteLabel + " --expected-name " + *label + "--" + *name + " --expected-session " + *session}
	c.ExpectedName = *remoteLabel + "--" + *remoteName
	c.ExpectedSession = *remoteSession
	c.ExpectedStart = *remoteStart
	original, e := peernet.Resolve(c.Home, c.Name, c.Session, c.PID)
	if e != nil {
		return e
	}
	state, e := newStatus(*home, *host, c.Name, c.Session, c.ExpectedName, c.ExpectedSession)
	if e != nil {
		return e
	}
	c.OnEvent = func(event peernet.Event) {
		if event.ProcessStart != "" {
			c.ExpectedStart = event.ProcessStart
		}
		state.observe(event)
	}
	defer func() { state.set("stopped", state.Error, state.Attempt) }()
	for attempt := 0; attempt <= *retries; attempt++ {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		current, err := peernet.Resolve(c.Home, c.Name, c.Session, c.PID)
		if err != nil || current.Start != original.Start || current.Socket != original.Socket {
			return fmt.Errorf("local endpoint changed; reconnect refused")
		}
		state.set("connecting", "", attempt)
		err = connect(ctx, c, args)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		state.set("offline", fmt.Sprint(err), attempt)
		if attempt == *retries {
			return err
		}
		delay := retryDelay(attempt)
		fmt.Fprintln(os.Stderr, "peer link offline; reconnect in", delay, "(no message replay)")
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
	}
	return nil
}

func retryDelay(attempt int) time.Duration {
	if attempt > 4 {
		return 30 * time.Second
	}
	return time.Second * time.Duration(1<<attempt)
}

func connect(parent context.Context, c peernet.Config, args []string) error {
	ctx, stop := context.WithCancel(parent)
	defer stop()
	command := exec.CommandContext(ctx, "ssh", args...)
	command.Stderr = os.Stderr
	out, e := command.StdoutPipe()
	if e != nil {
		return e
	}
	in, e := command.StdinPipe()
	if e != nil {
		return e
	}
	if e = command.Start(); e != nil {
		return e
	}
	var once sync.Once
	stream := duplex{out, in, func() error { once.Do(func() { in.Close(); out.Close(); stop() }); return nil }}
	e = peernet.Run(ctx, stream, c, os.Stderr)
	stream.Close()
	wait := command.Wait()
	if e != nil {
		return e
	}
	return wait
}
