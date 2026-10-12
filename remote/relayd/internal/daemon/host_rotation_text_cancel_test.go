package daemon

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestHostRotationTextCommandCancellation(t *testing.T) {
	python, err := hostRotationTextPython(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, mode := range []string{"graceful", "bounded_kill"} {
		t.Run(mode, func(t *testing.T) {
			root := t.TempDir()
			ready := filepath.Join(root, "ready.sock")
			marker := filepath.Join(root, "term")
			listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: ready, Net: "unix"})
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			listener.SetDeadline(time.Now().Add(10 * time.Second))
			script := "import signal,socket,sys\ndef terminate(*_):\n open(sys.argv[2], 'w').write('terminated')\n raise SystemExit(0)\nsignal.signal(signal.SIGTERM, terminate if sys.argv[3]=='graceful' else signal.SIG_IGN)\ns=socket.socket(socket.AF_UNIX);s.connect(sys.argv[1]);s.close()\nsignal.pause()\n"
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			go func() {
				_, err := hostRotationTextCommand(ctx, python, []string{"-I", "-S", "-c", script, ready, marker, mode}, nil)
				done <- err
			}()
			connection, err := listener.AcceptUnix()
			if err != nil {
				cancel()
				t.Fatal(err)
			}
			connection.Close()
			began := time.Now()
			cancel()
			select {
			case err := <-done:
				if err == nil {
					t.Fatal("cancelled command succeeded")
				}
				if mode == "graceful" && !errors.Is(err, context.Canceled) {
					t.Fatal("graceful cancellation did not report context cancellation", err)
				}
			case <-time.After(8 * time.Second):
				t.Fatal("text cancellation exceeded bounded cleanup")
			}
			elapsed := time.Since(began)
			if mode == "graceful" {
				data, err := os.ReadFile(marker)
				if err != nil || string(data) != "terminated" {
					t.Fatal("SIGTERM cleanup was not delivered", err)
				}
				if elapsed >= 3*time.Second {
					t.Fatal("graceful process reached forced-kill deadline")
				}
			} else {
				if elapsed < 2800*time.Millisecond || elapsed > 6*time.Second {
					t.Fatal("forced termination bound changed", elapsed)
				}
				if _, err := os.Stat(marker); !os.IsNotExist(err) {
					t.Fatal("ignored SIGTERM executed cleanup")
				}
			}
		})
	}
}
