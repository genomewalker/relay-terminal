package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

func nativeRotationTestBridge(t *testing.T) (*hostNativeRotationBridge, net.Conn) {
	t.Helper()
	a, b := net.Pipe()
	bridge := &hostNativeRotationBridge{connection: a, writer: protocol.NewWriter(a), done: make(chan struct{})}
	t.Cleanup(func() { bridge.close(); b.Close() })
	return bridge, b
}

func nativeRotationTestPrepare(t *testing.T, bridge *hostNativeRotationBridge, peer net.Conn) *hostNativeRotationLease {
	t.Helper()
	completed := make(chan error, 1)
	go func() {
		_, err := bridge.call(context.Background(), nativeRotationCommand{Operation: "prepare",
			ThreadID: "00000000-0000-0000-0000-000000000701", TurnID: "turn-1"})
		completed <- err
	}()
	_ = peer.SetReadDeadline(time.Now().Add(5 * time.Second))
	frame, err := protocol.ReadFrame(peer)
	if err != nil {
		t.Fatal(err)
	}
	var command nativeRotationCommand
	if frame.Type != protocol.HostRequest || json.Unmarshal(frame.Payload, &command) != nil {
		t.Fatal("request")
	}
	supported := true
	reply := nativeRotationReply{Version: 1, ID: command.ID, State: "prepared", CommitSupported: &supported,
		Native: &nativeRotationReceipt{ReservationID: "00000000-0000-0000-0000-000000000702",
			RuntimeID: "00000000-0000-0000-0000-000000000703", ThreadID: command.ThreadID,
			TurnID: command.TurnID, RolloutPath: "/tmp/rotation-rollout.jsonl", AdmissionGeneration: "12", ExpiresInMS: 5000},
		Frontend: &nativeRotationFrontend{RuntimeID: "00000000-0000-0000-0000-000000000704", Generation: "7"}}
	raw, _ := json.Marshal(reply)
	if err := bridge.receive(raw); err != nil {
		t.Fatal(err)
	}
	if err := <-completed; err != nil {
		t.Fatal(err)
	}
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if bridge.active == nil {
		t.Fatal("missing lease")
	}
	return bridge.active
}

func TestNativeRotationBridgePrepareAndExplicitRelease(t *testing.T) {
	bridge, peer := nativeRotationTestBridge(t)
	lease := nativeRotationTestPrepare(t, bridge, peer)
	completed := make(chan error, 1)
	go func() { completed <- lease.release(context.Background()) }()
	frame, err := protocol.ReadFrame(peer)
	if err != nil {
		t.Fatal(err)
	}
	var command nativeRotationCommand
	if json.Unmarshal(frame.Payload, &command) != nil || command.Operation != "release" ||
		command.ReservationID != lease.native.ReservationID {
		t.Fatal("release identity")
	}
	raw, _ := json.Marshal(nativeRotationReply{Version: 1, ID: command.ID, State: "released"})
	if err := bridge.receive(raw); err != nil {
		t.Fatal(err)
	}
	if err := <-completed; err != nil {
		t.Fatal(err)
	}
	select {
	case <-lease.revoked:
	default:
		t.Fatal("release did not revoke")
	}
}

func TestNativeRotationBridgeDisconnectRevokesHeldLease(t *testing.T) {
	bridge, peer := nativeRotationTestBridge(t)
	lease := nativeRotationTestPrepare(t, bridge, peer)
	bridge.close()
	select {
	case <-lease.revoked:
	default:
		t.Fatal("disconnect did not revoke")
	}
}

func TestNativeRotationBridgeFrontendRevocationMatchesReservation(t *testing.T) {
	bridge, peer := nativeRotationTestBridge(t)
	lease := nativeRotationTestPrepare(t, bridge, peer)
	raw, _ := json.Marshal(nativeRotationReply{Version: 1, State: "revoked", ReservationID: "other"})
	if err := bridge.receive(raw); err != nil {
		t.Fatal(err)
	}
	select {
	case <-lease.revoked:
		t.Fatal("unrelated revocation")
	default:
	}
	raw, _ = json.Marshal(nativeRotationReply{Version: 1, State: "revoked", ReservationID: lease.native.ReservationID})
	if err := bridge.receive(raw); err != nil {
		t.Fatal(err)
	}
	select {
	case <-lease.revoked:
	default:
		t.Fatal("reservation not revoked")
	}
}

func TestNativeRotationBridgeCancellationClosesSubmittedStream(t *testing.T) {
	bridge, peer := nativeRotationTestBridge(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	completed := make(chan error, 1)
	go func() {
		_, err := bridge.call(ctx, nativeRotationCommand{Operation: "prepare", ThreadID: "thread", TurnID: "turn"})
		completed <- err
	}()
	_ = peer.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := protocol.ReadFrame(peer); err != nil {
		t.Fatal(err)
	}
	cancel()
	if err := <-completed; err == nil {
		t.Fatal("cancelled request succeeded")
	}
	select {
	case <-bridge.done:
	default:
		t.Fatal("submitted stream stayed open")
	}
}

func TestNativeRotationBridgeRejectsUnsolicitedAndDuplicateResponse(t *testing.T) {
	bridge, peer := nativeRotationTestBridge(t)
	if bridge.receive([]byte(`{"v":1,"id":"unknown","state":"refused"}`)) == nil {
		t.Fatal("unsolicited accepted")
	}
	_ = nativeRotationTestPrepare(t, bridge, peer)
	if bridge.receive([]byte(`{"v":1,"v":1,"state":"revoked"}`)) == nil {
		t.Fatal("duplicate JSON accepted")
	}
	_, err := bridge.call(context.Background(), nativeRotationCommand{Operation: "prepare", ThreadID: "thread", TurnID: "turn"})
	if err == nil {
		t.Fatal("second lease accepted")
	}
}

func TestNativeRotationBridgeRejectsReceiptBindingChange(t *testing.T) {
	command := nativeRotationCommand{ThreadID: "thread", TurnID: "turn"}
	reply := nativeRotationReply{Native: &nativeRotationReceipt{ThreadID: "other", TurnID: "turn"}}
	if validNativeRotationReceipt(command, reply) {
		t.Fatal("wrong thread accepted")
	}
}

func TestNativeRotationBridgeCallerRequiresDirectParentIncarnation(t *testing.T) {
	parent := os.Getppid()
	start, err := processStartTime(parent)
	if err != nil {
		t.Fatal(err)
	}
	if !nativeRotationCallerMatches(os.Getpid(), parent, start) {
		t.Fatal("current direct parent rejected")
	}
	if nativeRotationCallerMatches(os.Getpid(), os.Getpid(), start) ||
		nativeRotationCallerMatches(os.Getpid(), parent, start+1) {
		t.Fatal("changed parent accepted")
	}
}

func TestNativeRotationBridgePipeAdapterIsBidirectionalAndEOFCloses(t *testing.T) {
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	input, toInput := io.Pipe()
	defer input.Close()
	defer toInput.Close()
	output, fromOutput := io.Pipe()
	defer output.Close()
	defer fromOutput.Close()
	completed := make(chan error, 1)
	go func() { completed <- forwardNativeRotationBridge(a, protocol.NewWriter(a), input, fromOutput) }()
	request := []byte(`{"v":1,"id":"a","operation":"prepare","thread_id":"thread","turn_id":"turn"}`)
	go func() { _ = protocol.NewWriter(b).Write(protocol.Frame{Type: protocol.HostRequest, Payload: request}) }()
	line, err := bufio.NewReader(output).ReadString('\n')
	if err != nil || line != string(request)+"\n" {
		t.Fatal("command forwarding", err)
	}
	response := []byte(`{"v":1,"id":"a","state":"refused"}`)
	go func() { _, _ = toInput.Write(append(response, '\n')) }()
	frame, err := protocol.ReadFrame(b)
	if err != nil || frame.Type != protocol.HostResponse || string(frame.Payload) != string(response) {
		t.Fatal("reply forwarding", err)
	}
	toInput.Close()
	if err := <-completed; err == nil {
		t.Fatal("EOF was not observed")
	}
}
