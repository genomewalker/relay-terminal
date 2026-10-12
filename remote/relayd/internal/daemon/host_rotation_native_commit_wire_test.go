package daemon

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"math"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

func nativeWireCommand(t *testing.T, peer net.Conn) nativeRotationCommand {
	t.Helper()
	_ = peer.SetReadDeadline(time.Now().Add(5 * time.Second))
	frame, err := protocol.ReadFrame(peer)
	var command nativeRotationCommand
	if err != nil || frame.Type != protocol.HostRequest || json.Unmarshal(frame.Payload, &command) != nil {
		t.Fatalf("command: %v", err)
	}
	return command
}
func nativeWireEnvelope(lease *hostNativeRotationLease) hostNativeCommitEnvelope {
	operation := "00000000-0000-0000-0000-000000000801"
	claim := "00000000-0000-0000-0000-000000000802"
	capsule := "Continue the task."
	return hostNativeCommitEnvelope{1, operation, claim, lease.native.ThreadID, lease.native.TurnID,
		hostNativeReservationPair{lease.native, lease.frontend},
		hostNativeIntentReceipt{1, "native_v1", lease.native.ThreadID, operation, operation, claim, "ledger:3", 3,
			operation, strings.Repeat("a", 64), 4, "commit_requested"},
		hostRotationCapsuleHash([]byte(capsule)), base64.StdEncoding.EncodeToString([]byte(capsule))}
}
func nativeWireSource(receipt nativeRotationReceipt) nativeRotationSource {
	return nativeRotationSource{receipt.RuntimeID, receipt.ThreadID, receipt.TurnID, receipt.RolloutPath, 12}
}
func TestHostNativeWireDurableHandoffPreservesUncertainty(t *testing.T) {
	for _, state := range []string{"pending", "restored", "source_retained", "lost", "wrong_capsule", "wrong_process", "wrong_source", "wrong_identity"} {
		t.Run(state, func(t *testing.T) {
			h, c, _ := nativeCommitFixture(t)
			if _, err := c.requestCommitIntent(context.Background()); err != nil {
				t.Fatal(err)
			}
			type result struct {
				reply nativeRotationReply
				err   error
			}
			done := make(chan result, 1)
			go func() { r, e := c.submitNativeCommit(context.Background()); done <- result{r, e} }()
			command := nativeWireCommand(t, h.peer)
			if command.Operation != "commit" || command.Commit == nil || command.Commit.OperationID != c.request.Epoch ||
				command.Commit.HostClaimID != c.request.HostClaimID || command.ReservationID != c.lease.native.ReservationID {
				t.Fatal("handoff binding")
			}
			raw, err := os.ReadFile(filepath.Join(h.dir, hostNativeClaimDirectory, c.request.Epoch+".native_handoff_requested.json"))
			var phase hostNativeHandoffPhase
			envelope, _ := json.Marshal(command.Commit)
			if err != nil || decodeHostNativeRecord(raw, &phase) != nil || phase.EnvelopeSHA256 != hostRotationCapsuleHash(envelope) {
				t.Fatal("pipe preceded durable handoff")
			}
			reply := nativeRotationReply{Version: 1, ID: command.ID, State: state, OperationID: c.request.Epoch, HostClaimID: c.request.HostClaimID}
			if state == "source_retained" {
				source := nativeWireSource(c.lease.native)
				reply.Source = &source
			}
			if state == "restored" || strings.HasPrefix(state, "wrong_") {
				reply.State = "restored"
				reply.Completion = &nativeRotationCompletion{OperationID: c.request.Epoch, HostClaimID: c.request.HostClaimID,
					Source: nativeWireSource(c.lease.native), TargetThreadID: "00000000-0000-0000-0000-000000000803",
					TargetRuntimeID: "00000000-0000-0000-0000-000000000804", TargetRolloutPath: "/tmp/rotated.jsonl",
					CapsuleSHA256: c.request.Capsule.SHA256, SettingsSHA256: strings.Repeat("b", 64), ProcessID: uint32(h.bridge.providerPID), JournalDirectory: "/tmp/native-journal"}
			}
			switch state {
			case "wrong_capsule":
				reply.Completion.CapsuleSHA256 = strings.Repeat("c", 64)
			case "wrong_process":
				reply.Completion.ProcessID++
			case "wrong_source":
				reply.Completion.Source.AdmissionGeneration++
			case "wrong_identity":
				reply.HostClaimID = reply.Completion.TargetThreadID
			}
			if state == "lost" {
				h.bridge.close()
			} else {
				raw, _ = json.Marshal(reply)
				err = h.bridge.receive(raw)
				if state == "wrong_identity" {
					if err == nil {
						t.Fatal("foreign identity accepted")
					}
					h.bridge.close()
				} else if err != nil {
					t.Fatal(err)
				}
			}
			observed := <-done
			bad := state == "lost" || strings.HasPrefix(state, "wrong_")
			if (observed.err != nil) != bad {
				t.Fatalf("observation %s: %v", state, observed.err)
			}
			if !bad && observed.reply.State != state {
				t.Fatal("state lost")
			}
			if _, err := c.submitNativeCommit(context.Background()); err == nil {
				t.Fatal("native submission replayed")
			}
			h.bridge.close()
			h.bridge.mu.Lock()
			retained := h.bridge.active == c.lease && c.lease.submitted
			h.bridge.revokeLocked()
			h.bridge.mu.Unlock()
			if !retained {
				t.Fatal("disconnect released submitted owner")
			}
			select {
			case <-c.lease.revoked:
				t.Fatal("uncertainty treated as release")
			default:
			}
			if c.lease.release(context.Background()) == nil {
				t.Fatal("submitted lease released")
			}
			nativeCommitFence(t, h, c)
		})
	}
}
func TestNativeRotationWireRequiresActualSupportedLease(t *testing.T) {
	for _, mode := range []string{"copied", "unsupported", "expired", "changed_capsule", "changed_frontend", "changed_intent", "no_lease"} {
		t.Run(mode, func(t *testing.T) {
			bridge, peer := nativeRotationTestBridge(t)
			lease := nativeRotationTestPrepare(t, bridge, peer)
			envelope := nativeWireEnvelope(lease)
			actual := lease
			switch mode {
			case "copied":
				copied := *lease
				actual = &copied
			case "unsupported":
				lease.commitSupported = false
			case "expired":
				lease.deadline = time.Now().Add(-time.Second)
			case "changed_capsule":
				envelope.CapsuleBase64 = base64.StdEncoding.EncodeToString([]byte("different"))
			case "changed_frontend":
				envelope.Reservation.Frontend.Generation = "8"
			case "changed_intent":
				envelope.Intent.HostClaimID = envelope.OperationID
			case "no_lease":
				actual = nil
			}
			_, err := bridge.callOwned(context.Background(), nativeRotationCommand{Operation: "commit", ThreadID: lease.native.ThreadID,
				ReservationID: lease.native.ReservationID, Commit: &envelope}, actual)
			if err == nil || lease.submitted {
				t.Fatal("invalid lease reached submission")
			}
		})
	}
}
func TestHostNativeClaimRefusesUnsupportedCommitBeforeLedger(t *testing.T) {
	h := newNativeClaimHarness(t)
	h.afterPrepare = func(lease *hostNativeRotationLease) { lease.commitSupported = false }
	if _, err := h.acquire(context.Background()); err == nil || h.claimCalls != 0 {
		t.Fatal("unsupported native commit claimed")
	}
}
func TestNativeRotationWireLargeCapsuleAndExactAcknowledgment(t *testing.T) {
	bridge, peer := nativeRotationTestBridge(t)
	lease := nativeRotationTestPrepare(t, bridge, peer)
	envelope := nativeWireEnvelope(lease)
	capsule := strings.Repeat("x", 16384)
	envelope.CapsuleBase64 = base64.StdEncoding.EncodeToString([]byte(capsule))
	envelope.CapsuleSHA256 = hostRotationCapsuleHash([]byte(capsule))
	done := make(chan error, 1)
	go func() {
		_, err := bridge.callOwned(context.Background(), nativeRotationCommand{Operation: "commit", ThreadID: lease.native.ThreadID,
			ReservationID: lease.native.ReservationID, Commit: &envelope}, lease)
		done <- err
	}()
	command := nativeWireCommand(t, peer)
	encoded, _ := json.Marshal(command)
	if len(encoded) <= 16384 || len(encoded)+1 > nativeRotationWireLimit {
		t.Fatal("capsule envelope bound")
	}
	raw, _ := json.Marshal(nativeRotationReply{Version: 1, ID: command.ID, State: "pending", OperationID: envelope.OperationID, HostClaimID: envelope.HostClaimID})
	if err := bridge.receive(raw); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	for _, state := range []string{"pending", "acknowledged"} {
		go func() {
			_, err := bridge.call(context.Background(), nativeRotationCommand{Operation: "acknowledge", ThreadID: lease.native.ThreadID,
				OperationID: envelope.OperationID, HostClaimID: envelope.HostClaimID})
			done <- err
		}()
		command = nativeWireCommand(t, peer)
		raw, _ = json.Marshal(nativeRotationReply{Version: 1, ID: command.ID, State: state, OperationID: envelope.OperationID, HostClaimID: envelope.HostClaimID})
		if err := bridge.receive(raw); err != nil {
			t.Fatal(err)
		}
		if err := <-done; err != nil {
			t.Fatal(err)
		}
		bridge.mu.Lock()
		active := bridge.active
		bridge.mu.Unlock()
		if (active == nil) != (state == "acknowledged") {
			t.Fatal("acknowledgment retired wrong phase")
		}
	}
}
func TestNativeRotationWireReconcileBindsBothIdentities(t *testing.T) {
	bridge, peer := nativeRotationTestBridge(t)
	done := make(chan error, 1)
	operation := "00000000-0000-0000-0000-000000000801"
	claim := "00000000-0000-0000-0000-000000000802"
	go func() {
		_, err := bridge.observeNativeCommit(context.Background(), "00000000-0000-0000-0000-000000000701", operation, claim)
		done <- err
	}()
	command := nativeWireCommand(t, peer)
	if command.Operation != "reconcile" || command.OperationID != operation || command.HostClaimID != claim {
		t.Fatal("reconcile binding")
	}
	raw, _ := json.Marshal(nativeRotationReply{Version: 1, ID: command.ID, State: "pending", OperationID: operation, HostClaimID: claim})
	if err := bridge.receive(raw); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}
func TestNativeRotationWireNumericGenerationIsExact(t *testing.T) {
	source := nativeRotationSource{RuntimeID: "00000000-0000-0000-0000-000000000703", ThreadID: "00000000-0000-0000-0000-000000000701",
		TurnID: "turn-1", RolloutPath: "/tmp/source", AdmissionGeneration: math.MaxUint64}
	raw, _ := json.Marshal(source)
	var decoded nativeRotationSource
	if decodeHostNativeRecord(raw, &decoded) != nil || decoded != source {
		t.Fatal("numeric generation lost precision")
	}
}
func TestNativeRotationPipeRejectsUnterminatedReply(t *testing.T) {
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	input, writer := io.Pipe()
	defer input.Close()
	done := make(chan error, 1)
	go func() { done <- forwardNativeRotationBridge(a, protocol.NewWriter(a), input, io.Discard) }()
	go func() { _, _ = io.WriteString(writer, "{\"v\":1,\"state\":\"refused\"}"); writer.Close() }()
	_ = b.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := protocol.ReadFrame(b); err == nil {
		t.Fatal("partial reply forwarded")
	}
	if err := <-done; err == nil {
		t.Fatal("EOF missing")
	}
}
func TestNativeRotationPipeForwardsLargeBoundedCommand(t *testing.T) {
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	input, toInput := io.Pipe()
	defer input.Close()
	defer toInput.Close()
	output, fromOutput := io.Pipe()
	defer output.Close()
	defer fromOutput.Close()
	done := make(chan error, 1)
	go func() { done <- forwardNativeRotationBridge(a, protocol.NewWriter(a), input, fromOutput) }()
	raw := []byte("{\"padding\":\"" + strings.Repeat("x", 30000) + "\"}")
	go func() { _ = protocol.NewWriter(b).Write(protocol.Frame{Type: protocol.HostRequest, Payload: raw}) }()
	line, err := bufio.NewReader(output).ReadString('\n')
	if err != nil || line != string(raw)+"\n" {
		t.Fatal("large command forwarding", err)
	}
	toInput.Close()
	<-done
}
