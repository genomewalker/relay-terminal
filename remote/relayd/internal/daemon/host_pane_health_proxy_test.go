//go:build linux || darwin

package daemon

import (
	"bufio"
	"context"
	"errors"
	"math"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

const phProxySession = "5e1c9f40-1111-4222-8333-444455556666"

type phProxyFixture struct {
	pane     string
	socket   string
	dev      int64
	ino      uint64
	requests atomic.Int32
}

// phStartProxy serves a real private Unix socket owned by this process, as
// the Codex frontend proxy is, and writes its descriptor. inode overrides the
// descriptor's control_inode when non-empty.
func phStartProxy(t *testing.T, inode string, respond func(net.Conn)) *phProxyFixture {
	t.Helper()
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	// Unix socket paths are short on macOS: keep the socket out of TempDir.
	directory, err := os.MkdirTemp("", "php")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	fixture := &phProxyFixture{pane: phTestPane, socket: filepath.Join(directory, "s")}
	listener, err := net.Listen("unix", fixture.socket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	if err := os.Chmod(fixture.socket, 0o600); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(fixture.socket)
	if err != nil {
		t.Fatal(err)
	}
	dev, ino := phStatDevIno(info)
	fixture.dev, fixture.ino = dev, ino
	if inode == "" {
		inode = strconv.FormatUint(ino, 10)
	}
	start := newPHReader(context.Background()).kernelStart(int64(os.Getpid()))
	phWrite(t, filepath.Join(os.Getenv("XDG_STATE_HOME"), "relay/workers/codex-proxies", fixture.pane, "descriptor.json"),
		`{"version": 1, "pane": "`+fixture.pane+`", "proxy_pid": `+pyStr(int64(os.Getpid()))+`, "proxy_start": `+pyStr(start)+
			`, "control_socket": "`+fixture.socket+`", "control_device": `+pyStr(dev)+`, "control_inode": `+inode+`}`, 0o600)
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer connection.Close()
				if _, err := bufio.NewReader(connection).ReadString('\n'); err != nil {
					return
				}
				fixture.requests.Add(1)
				respond(connection)
			}()
		}
	}()
	return fixture
}

func phProxyReply(connection net.Conn) {
	_, _ = connection.Write([]byte(`{"active": true, "frontend_pid": 4242, "frontend_start": 99, "last_frontend_thread": "` + phProxySession + `"}` + "\n"))
}

// phSlowProxy sends one byte per second and never finishes a line.
func phSlowProxy(connection net.Conn) {
	for {
		if _, err := connection.Write([]byte(" ")); err != nil {
			return
		}
		time.Sleep(time.Second)
	}
}

func TestPaneHealthProxySessionAcceptsItsExactLiveSocket(t *testing.T) {
	fixture := phStartProxy(t, "", phProxyReply)
	if got := newPHReader(context.Background()).proxySession(fixture.pane, 4242, int64(99)); got != phProxySession {
		t.Fatalf("session = %q", got)
	}
	if fixture.requests.Load() != 1 {
		t.Fatalf("state requests = %d", fixture.requests.Load())
	}
	if raised := phRaised(t, func() { newPHReader(context.Background()).proxySession(fixture.pane, 4243, int64(99)) }); raised == nil || raised.msg != "The live proxy frontend changed." {
		t.Fatalf("other frontend: %+v", raised)
	}
}

func TestPaneHealthProxySessionRejectsAChangedSocketBeforeConnecting(t *testing.T) {
	for _, inode := range []string{"18446744073709551615", "-1", "1.5"} {
		fixture := phStartProxy(t, inode, phProxyReply)
		raised := phRaised(t, func() { newPHReader(context.Background()).proxySession(fixture.pane, 4242, int64(99)) })
		if raised == nil || raised.msg != "The native proxy socket changed." || fixture.requests.Load() != 0 {
			t.Fatalf("inode %q: raised %+v after %d requests", inode, raised, fixture.requests.Load())
		}
	}
	fixture := phStartProxy(t, "", phProxyReply)
	phWrite(t, filepath.Join(os.Getenv("XDG_STATE_HOME"), "relay/workers/codex-proxies", fixture.pane, "descriptor.json"),
		`{"version": 1, "pane": "`+fixture.pane+`", "proxy_pid": `+pyStr(int64(os.Getpid()))+`, "proxy_start": `+
			pyStr(newPHReader(context.Background()).kernelStart(int64(os.Getpid())))+`, "control_socket": "`+fixture.socket+
			`", "control_device": `+pyStr(fixture.dev)+`, "control_inode": `+strconv.FormatUint(fixture.ino+1, 10)+`}`, 0o600)
	if raised := phRaised(t, func() { newPHReader(context.Background()).proxySession(fixture.pane, 4242, int64(99)) }); raised == nil || raised.msg != "The native proxy socket changed." || fixture.requests.Load() != 0 {
		t.Fatalf("wrong inode: %+v", raised)
	}
}

func TestPaneHealthPythonModelComparesUnsignedNativeIntegers(t *testing.T) {
	huge := new(big.Int).SetUint64(math.MaxUint64)
	if !pyEqual(uint64(math.MaxUint64), huge) || !pyEqual(huge, uint64(math.MaxUint64)) || !pyEqual(uint64(7), int64(7)) ||
		pyEqual(uint64(7), int64(8)) || pyEqual(uint64(math.MaxUint64), int64(-1)) || !pyEqual(uint32(7), 7.0) {
		t.Fatal("unsigned equality differs from Python int ==")
	}
	if got := string(pyEncode(pyListOf(uint64(math.MaxUint64), uint32(3)), pyEncodeOptions{itemSep: ",", keySep: ":"})); got != "[18446744073709551615,3]" {
		t.Fatalf("encoded = %s", got)
	}
}

// Cancelling the operation interrupts a proxy that keeps the read alive with
// slow fragments; the probe never outlives its operation by a fragment.
func TestPaneHealthCancelledProbeInterruptsASlowProxyRead(t *testing.T) {
	fixture := phStartProxy(t, "", phSlowProxy)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	backend := newPaneHealthNativeBackend(ctx, t.TempDir(), "/relayd")
	backend.probe = func(ctx context.Context, pane, _ string) *pyObject {
		return pyObj("session", newPHReader(ctx).proxySession(pane, 4242, int64(99)))
	}
	var cancelledAt atomic.Int64
	go func() {
		for fixture.requests.Load() == 0 {
			time.Sleep(5 * time.Millisecond)
		}
		time.Sleep(150 * time.Millisecond)
		cancelledAt.Store(time.Now().UnixNano())
		cancel()
	}()
	_, err := backend.Probe(fixture.pane)
	lag := time.Duration(time.Now().UnixNano() - cancelledAt.Load())
	if !errors.Is(err, errPaneHealthBackendLost) || cancelledAt.Load() == 0 || lag > 300*time.Millisecond {
		t.Fatalf("probe = %v, cancellation lag %v", err, lag)
	}
	t.Logf("cancellation lag %v", lag)
}

// Without cancellation the exchange still ends at its single operation
// deadline instead of renewing three seconds for every fragment.
func TestPaneHealthProxyExchangeHasOneOperationDeadline(t *testing.T) {
	fixture := phStartProxy(t, "", phSlowProxy)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan *phException, 1)
	began := time.Now()
	go func() {
		done <- phRaised(t, func() { newPHReader(ctx).proxySession(fixture.pane, 4242, int64(99)) })
	}()
	select {
	case raised := <-done:
		if raised == nil || raised.kind != phOSError || time.Since(began) > 4500*time.Millisecond {
			t.Fatalf("slow proxy: %+v after %v", raised, time.Since(began))
		}
	case <-time.After(6 * time.Second):
		t.Fatal("slow proxy fragments renewed the exchange deadline")
	}
}

func TestPaneHealthFileReadsNeverWaitOnANamedPipe(t *testing.T) {
	fifo := filepath.Join(t.TempDir(), "fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	for name, read := range map[string]func(){
		"open":         func() { phOpenRead(fifo).Close() },
		"private file": func() { newPHReader(context.Background()).ownerPrivateFile(fifo, 100) },
		"list dir": func() {
			if _, err := phListDir(fifo); err != nil {
				phRaiseOS(err)
			}
		},
		"interpreter": func() {
			if phScriptInterpreter(fifo) != "" {
				phRaise(phValueError, "interpreter")
			}
			phRaise(phOSError, "returned")
		},
	} {
		done := make(chan *phException, 1)
		go func() { done <- phRaised(t, read) }()
		select {
		case raised := <-done:
			if raised == nil {
				t.Fatalf("%s: read a FIFO", name)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("%s: blocked on a FIFO", name)
		}
	}
}
