//go:build !windows

package programstatus

import (
	"bytes"
	"context"
	"encoding/hex"
	"io"
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
		marker = "MUX-REPLY-EXACT"
		command = tmuxReplyProducerCommand(tmux, socket, payload, DetectionReply, false)
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

// tmuxReplyProducerEnv carries the round-trip producer's parameters. The
// producer is this test binary, run as the program in the private tmux pane.
const tmuxReplyProducerEnv = "RELAY_TMUX_REPLY_PRODUCER"

func tmuxReplyProducerCommand(tmux, socket, payload, reply string, refuseDuplicate bool) string {
	quote := func(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'" }
	spec := strings.Join([]string{tmux, socket, hex.EncodeToString([]byte(payload)),
		hex.EncodeToString([]byte(reply)), strconv.FormatBool(refuseDuplicate)}, "\n")
	return tmuxReplyProducerEnv + "=" + quote(spec) + " exec " + quote(os.Args[0]) + " -test.run='^TestTmuxReplyProducer$'"
}

// TestTmuxReplyProducer is the program in the round-trip test's tmux pane. It
// waits for the test, puts its terminal in raw mode, writes the payload, reads
// exactly the expected reply (and, when asked, no second copy within 150ms),
// then prints MUX-REPLY-EXACT and holds until the test releases it.
func TestTmuxReplyProducer(t *testing.T) {
	spec, ok := os.LookupEnv(tmuxReplyProducerEnv)
	if !ok {
		t.Skip("runs only inside the round-trip test's tmux pane")
	}
	os.Exit(runTmuxReplyProducer(spec))
}

func runTmuxReplyProducer(spec string) int {
	fields := strings.Split(spec, "\n")
	if len(fields) != 5 {
		return 2
	}
	tmux, socket := fields[0], fields[1]
	payload, payloadErr := hex.DecodeString(fields[2])
	reply, replyErr := hex.DecodeString(fields[3])
	if payloadErr != nil || replyErr != nil {
		return 2
	}
	if exec.Command(tmux, "-S", socket, "wait-for", "emit").Run() != nil {
		return 1
	}
	raw := exec.Command("stty", "raw", "-echo")
	raw.Stdin = os.Stdin
	if raw.Run() != nil {
		return 1
	}
	if _, err := os.Stdout.Write(payload); err != nil {
		return 1
	}
	got := make([]byte, len(reply))
	if _, err := io.ReadFull(os.Stdin, got); err != nil || !bytes.Equal(got, reply) {
		_, _ = os.Stdout.WriteString("MUX-REPLY-WRONG")
		return 1
	}
	if fields[4] == "true" {
		extra := make(chan bool, 1)
		go func() {
			b := make([]byte, 1)
			n, _ := os.Stdin.Read(b)
			extra <- n > 0
		}()
		select {
		case more := <-extra:
			if more {
				_, _ = os.Stdout.WriteString("MUX-REPLY-DUPLICATE")
				return 1
			}
		case <-time.After(150 * time.Millisecond):
		}
	}
	_, _ = os.Stdout.WriteString("MUX-REPLY-EXACT")
	if exec.Command(tmux, "-S", socket, "wait-for", "hold").Run() != nil {
		return 1
	}
	return 0
}
