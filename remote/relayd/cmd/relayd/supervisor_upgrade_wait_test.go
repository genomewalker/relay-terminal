package main

import (
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// A slow old supervisor (Mac 0.5.36 with 172k archived jobs, 2026-11-13) took
// longer than 30 s to prepare and upgrade-supervisor gave up with "invalid
// relayd probe response". The prepare probe must wait as long as it is told to,
// and the default must outlast such a supervisor.
func TestUpgradePrepareWaitsForASlowOldSupervisor(t *testing.T) {
	if upgradePrepareTimeout < 2*time.Minute || upgradeLedgerWait < 2*time.Minute {
		t.Fatalf("upgrade waits too short for a slow old supervisor: prepare %v ledger %v", upgradePrepareTimeout, upgradeLedgerWait)
	}
	dir, err := os.MkdirTemp("/tmp", "sup-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	socket := filepath.Join(dir, "s")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	const prepareTakes = 2500 * time.Millisecond // longer than the plain 2 s probe
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				hello, err := protocol.ReadFrame(conn)
				if err != nil || hello.Type != protocol.Hello {
					return
				}
				time.Sleep(prepareTakes)
				status, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "ready", Version: "0.5.36", ProtocolVersion: 2, UpgradePrepared: true})
				_ = protocol.NewWriter(conn).Write(status)
			}(conn)
		}
	}()

	if _, err := inspectSupervisorForUpgrade(socket, time.Second); err == nil {
		t.Fatal("a 1 s deadline accepted a 2.5 s prepare; the test does not exercise the wait")
	}
	began := time.Now()
	live, err := inspectSupervisorForUpgrade(socket, 10*time.Second)
	if err != nil || !live.Status.UpgradePrepared || live.PeerPID != os.Getpid() {
		t.Fatalf("slow prepare not awaited: %+v %v", live, err)
	}
	if took := time.Since(began); took < prepareTakes {
		t.Fatalf("returned before the supervisor answered: %v", took)
	}
}
