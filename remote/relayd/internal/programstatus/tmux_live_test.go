//go:build !windows

package programstatus

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/creack/pty"
)

func TestRealTmuxPassthroughStatusAndDetection(t *testing.T) {
	runRealTmux(t, false)
}
func TestRealTmuxDetectionReplyReturnsToProducer(t *testing.T) {
	runRealTmux(t, true)
}
func runRealTmux(t *testing.T, roundTrip bool) {
	tmux, err := exec.LookPath("tmux")
	if err != nil {
		t.Skip("tmux is not installed")
	}
	dir, err := os.MkdirTemp("/tmp", "relay-mux-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	socket := filepath.Join(dir, "s")
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	env := []string{}
	for _, entry := range os.Environ() {
		if !strings.HasPrefix(entry, "TMUX=") && !strings.HasPrefix(entry, "TERM=") {
			env = append(env, entry)
		}
	}
	env = append(env, "TERM=xterm-256color")
	run := func(args ...string) error {
		cmd := exec.CommandContext(ctx, tmux, append([]string{"-S", socket, "-f", "/dev/null"}, args...)...)
		cmd.Env = env
		_, err := cmd.CombinedOutput()
		return err
	}
	defer func() { _ = exec.Command(tmux, "-S", socket, "kill-server").Run() }()
	quote := func(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'" }
	payload := tmuxWrap(seq("id=tmux-real:state=done:app=fixture")) + tmuxWrap("\x1b]7501;?\a")
	command := quote(tmux) + " -S " + quote(socket) + " wait-for emit; printf %s " + quote(payload) +
		"; printf MUX-STATUS-EMITTED; " + quote(tmux) + " -S " + quote(socket) + " wait-for hold"

	marker := "MUX-STATUS-EMITTED"
	if roundTrip {
		python, err := exec.LookPath("python3")
		if err != nil {
			t.Skip("python3 is not installed")
		}
		marker = "MUX-REPLY-EXACT"
		signal := "[" + strconv.Quote(tmux) + ", '-S', " + strconv.Quote(socket) + ", 'wait-for', 'emit']"
		hold := "[" + strconv.Quote(tmux) + ", '-S', " + strconv.Quote(socket) + ", 'wait-for', 'hold']"
		program := "import os, tty, subprocess\nsubprocess.check_call(" + signal + ")\ntty.setraw(0)\n" +
			"os.write(1, " + strconv.Quote(payload) + ".encode())\nreply=b''\n" +
			"while len(reply)<10:\n reply+=os.read(0,10-len(reply))\n" +
			"assert reply==" + strconv.Quote(DetectionReply) + ".encode(),repr(reply)\n" +
			"os.write(1,b'MUX-REPLY-EXACT')\nsubprocess.check_call(" + hold + ")\n"
		producer := filepath.Join(dir, "producer.py")
		if err := os.WriteFile(producer, []byte(program), 0600); err != nil {
			t.Fatal(err)
		}
		command = quote(python) + " " + quote(producer)
	}
	if err := run("new-session", "-d", "-s", "relay-probe", "-x", "80", "-y", "24", command); err != nil {
		t.Fatal("private tmux session creation:", err)
	}
	if err := run("set-option", "-g", "allow-passthrough", "on"); err != nil {
		t.Fatal("private tmux passthrough setting:", err)
	}
	client := exec.CommandContext(ctx, tmux, "-S", socket, "attach-session", "-t", "relay-probe")
	client.Env = env
	fd, err := pty.StartWithSize(client, &pty.Winsize{Cols: 80, Rows: 24})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = fd.Close(); cancel(); _ = client.Wait() }()
	chunks := make(chan []byte, 16)
	errors := make(chan error, 1)
	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := fd.Read(buf)
			if n > 0 {
				data := append([]byte(nil), buf[:n]...)
				select {
				case chunks <- data:
				case <-ctx.Done():
					return
				}
			}
			if err != nil {
				errors <- err
				return
			}
		}
	}()
	var tracker Tracker
	var capture []byte
	queries, signalled := 0, false
	for {
		select {
		case chunk := <-chunks:
			capture = append(capture, chunk...)
			if len(capture) > 32*1024 {
				t.Fatal("private tmux capture bound exceeded")
			}
			events := tracker.Feed(chunk)
			queries += events.DetectionQueries
			if roundTrip && events.DetectionQueries > 0 {
				if _, err := fd.Write([]byte(DetectionReply)); err != nil {
					t.Fatal(err)
				}
			}
			if !signalled {
				// The attached client has emitted its first physical PTY frame.
				// Signal the producer once, without polling or timed sleeps.
				if err := run("wait-for", "-S", "emit"); err != nil {
					t.Fatal(err)
				}
				signalled = true
			}
			records := tracker.Snapshot()
			if len(records) == 1 && records[0].ID == "tmux-real" && records[0].State == "done" &&
				queries == 1 && bytes.Contains(capture, []byte(marker)) {
				t.Logf("real private tmux PTY accepted status/query; fixed reply roundtrip=%v", roundTrip)
				return
			}
		case err := <-errors:
			t.Fatal("private tmux client stream ended:", err)
		case <-ctx.Done():
			t.Fatalf("tmux acceptance timeout: %d records, %d queries, %d captured bytes",
				len(tracker.Snapshot()), queries, len(capture))
		}
	}
}
