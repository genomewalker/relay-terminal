package daemon

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

const nativeRotationWireLimit = 64 * 1024

var nativeRotationUUID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

type nativeRotationCommand struct {
	Version       int                       `json:"v"`
	ID            string                    `json:"id"`
	Operation     string                    `json:"operation"`
	ThreadID      string                    `json:"thread_id"`
	TurnID        string                    `json:"turn_id,omitempty"`
	ReservationID string                    `json:"reservation_id,omitempty"`
	OperationID   string                    `json:"operation_id,omitempty"`
	HostClaimID   string                    `json:"host_claim_id,omitempty"`
	Commit        *hostNativeCommitEnvelope `json:"commit,omitempty"`
}

type nativeRotationReceipt struct {
	ReservationID       string `json:"reservationId"`
	RuntimeID           string `json:"runtimeId"`
	ThreadID            string `json:"threadId"`
	TurnID              string `json:"turnId"`
	RolloutPath         string `json:"rolloutPath"`
	AdmissionGeneration string `json:"admissionGeneration"`
	ExpiresInMS         uint32 `json:"expiresInMs"`
}

type nativeRotationFrontend struct {
	RuntimeID  string `json:"runtime_id"`
	Generation string `json:"generation"`
}

type nativeRotationReply struct {
	Version          int                       `json:"v"`
	ID               string                    `json:"id,omitempty"`
	State            string                    `json:"state"`
	ReservationID    string                    `json:"reservation_id,omitempty"`
	Native           *nativeRotationReceipt    `json:"native,omitempty"`
	Frontend         *nativeRotationFrontend   `json:"frontend,omitempty"`
	CommitSupported  *bool                     `json:"commit_supported,omitempty"`
	OperationID      string                    `json:"operation_id,omitempty"`
	HostClaimID      string                    `json:"host_claim_id,omitempty"`
	Completion       *nativeRotationCompletion `json:"completion,omitempty"`
	Source           *nativeRotationSource     `json:"source,omitempty"`
	Reason           string                    `json:"reason,omitempty"`
	JournalDirectory string                    `json:"journal_directory,omitempty"`
}

type nativeRotationPending struct {
	command nativeRotationCommand
	started time.Time
	reply   chan nativeRotationReply
}

// The connection is the authority. A persisted or copied response cannot recreate it.
type hostNativeRotationBridge struct {
	connection    net.Conn
	writer        *protocol.Writer
	providerPID   int
	providerStart uint64
	helperPID     int
	mu            sync.Mutex
	pending       *nativeRotationPending
	active        *hostNativeRotationLease
	done          chan struct{}
	once          sync.Once
}

type hostNativeRotationLease struct {
	bridge   *hostNativeRotationBridge
	native   nativeRotationReceipt
	frontend nativeRotationFrontend
	deadline time.Time
	revoked  chan struct{}
	timer    *time.Timer
	// Protected by bridge.mu. Submission is sticky across timeout/disconnect.
	commitSupported bool
	submitted       bool
	operationID     string
	hostClaimID     string
}

func (bridge *hostNativeRotationBridge) close() {
	bridge.once.Do(func() {
		close(bridge.done)
		_ = bridge.connection.Close()
		bridge.mu.Lock()
		bridge.revokeLocked()
		bridge.mu.Unlock()
	})
}

func (bridge *hostNativeRotationBridge) revokeLocked() {
	if lease := bridge.active; lease != nil && !lease.submitted {
		bridge.active = nil
		if lease.timer != nil {
			lease.timer.Stop()
		}
		close(lease.revoked)
	}
}

func nativeRotationCallerMatches(pid, provider int, start uint64) bool {
	identity, err := processStartIdentity(pid)
	if err != nil {
		return false
	}
	chain, err := networkAncestors(pid, identity)
	if err != nil || len(chain) < 2 || chain[0] != pid || chain[1] != provider {
		return false
	}
	actual, err := processStartTime(provider)
	return err == nil && actual == start
}

func serveNativeRotationBridge(connection net.Conn, writer *protocol.Writer, session *Session, pane string) {
	uid, pid, err := PeerCredentials(connection)
	if err != nil || uid != os.Getuid() {
		return
	}
	binding, err := ReadNativeAgentBinding(pane)
	if err != nil || binding.Producer.Provider != "codex" ||
		!nativeRotationCallerMatches(pid, binding.Producer.ProcessID, binding.Producer.ProcessStart) {
		return
	}
	bridge := &hostNativeRotationBridge{connection: connection, writer: writer,
		providerPID: binding.Producer.ProcessID, providerStart: binding.Producer.ProcessStart,
		helperPID: pid, done: make(chan struct{})}
	session.nativeRotationMu.Lock()
	if session.nativeRotation != nil {
		session.nativeRotationMu.Unlock()
		return
	}
	session.nativeRotation = bridge
	session.nativeRotationMu.Unlock()
	session.notifyNativeRotationRecovery()
	defer func() {
		bridge.close()
		session.nativeRotationMu.Lock()
		if session.nativeRotation == bridge {
			session.nativeRotation = nil
		}
		session.nativeRotationMu.Unlock()
		session.notifyNativeRotationRecovery()
	}()
	go func() {
		select {
		case <-session.done:
			bridge.close()
		case <-bridge.done:
		}
	}()
	ready, _ := protocol.JSONFrame(protocol.Status, map[string]any{"v": 1, "state": "native_rotation_ready"})
	if writer.Write(ready) != nil {
		return
	}
	for {
		frame, err := protocol.ReadFrame(connection)
		if err != nil || frame.Type != protocol.HostResponse || len(frame.Payload) > nativeRotationWireLimit ||
			bridge.receive(frame.Payload) != nil {
			return
		}
		session.notifyNativeRotationRecovery()
	}
}

func (session *Session) notifyNativeRotationRecovery() {
	session.mu.Lock()
	supervisor := session.hostRotation
	session.mu.Unlock()
	if supervisor != nil {
		supervisor.notify()
	}
}

func validNativeRotationReceipt(command nativeRotationCommand, reply nativeRotationReply) bool {
	n, f := reply.Native, reply.Frontend
	if n == nil || f == nil || n.ThreadID != command.ThreadID || n.TurnID != command.TurnID ||
		!nativeRotationUUID.MatchString(n.ReservationID) || !nativeRotationUUID.MatchString(n.RuntimeID) ||
		!nativeRotationUUID.MatchString(f.RuntimeID) || n.ExpiresInMS == 0 || n.ExpiresInMS > 5000 ||
		!filepath.IsAbs(n.RolloutPath) || len(n.RolloutPath) > 4096 {
		return false
	}
	_, a := strconv.ParseUint(n.AdmissionGeneration, 10, 64)
	_, b := strconv.ParseUint(f.Generation, 10, 64)
	return a == nil && b == nil
}

func (bridge *hostNativeRotationBridge) receive(raw []byte) error {
	var reply nativeRotationReply
	if len(raw)+1 > nativeRotationWireLimit || decodeHostNativeRecord(raw, &reply) != nil || reply.Version != 1 {
		return errors.New("invalid native rotation response")
	}
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if reply.State == "revoked" && reply.ID == "" {
		if bridge.active != nil && bridge.active.native.ReservationID == reply.ReservationID {
			bridge.revokeLocked()
		}
		return nil
	}
	pending := bridge.pending
	if pending == nil || pending.command.ID != reply.ID {
		return errors.New("unexpected native rotation response")
	}
	if err := validateNativeRotationReply(pending.command, reply); err != nil {
		return err
	}
	switch reply.State {
	case "prepared":
		if pending.command.Operation != "prepare" || bridge.active != nil ||
			!validNativeRotationReceipt(pending.command, reply) {
			return errors.New("invalid native reservation")
		}
		deadline := pending.started.Add(time.Duration(reply.Native.ExpiresInMS) * time.Millisecond)
		if !time.Now().Before(deadline) {
			return errors.New("native reservation expired")
		}
		lease := &hostNativeRotationLease{bridge: bridge, native: *reply.Native, frontend: *reply.Frontend,
			deadline: deadline, revoked: make(chan struct{}),
			commitSupported: reply.CommitSupported != nil && *reply.CommitSupported}
		bridge.active = lease
		lease.timer = time.AfterFunc(time.Until(deadline), func() {
			bridge.mu.Lock()
			defer bridge.mu.Unlock()
			if bridge.active == lease {
				bridge.revokeLocked()
			}
		})
	case "released":
		if pending.command.Operation != "release" {
			return errors.New("unexpected native release")
		}
		if bridge.active != nil && bridge.active.native.ReservationID == pending.command.ReservationID {
			bridge.revokeLocked()
		}
	case "refused", "pending", "restored", "source_retained":
	case "acknowledged":
		if lease := bridge.active; lease != nil && lease.submitted &&
			lease.operationID == reply.OperationID && lease.hostClaimID == reply.HostClaimID {
			bridge.active = nil
			close(lease.revoked)
		}
	default:
		return errors.New("unknown native rotation response")
	}
	// Exactly one response is accepted per operation, including while the caller is being scheduled.
	bridge.pending = nil
	pending.reply <- reply
	return nil
}

func (bridge *hostNativeRotationBridge) call(ctx context.Context, command nativeRotationCommand) (nativeRotationReply, error) {
	return bridge.callOwned(ctx, command, nil)
}

func (bridge *hostNativeRotationBridge) callOwned(ctx context.Context, command nativeRotationCommand, lease *hostNativeRotationLease) (nativeRotationReply, error) {
	var empty nativeRotationReply
	if ctx.Err() != nil {
		return empty, ctx.Err()
	}
	token := make([]byte, 16)
	if _, err := rand.Read(token); err != nil {
		return empty, err
	}
	command.Version, command.ID = 1, hex.EncodeToString(token)
	frame, err := protocol.JSONFrame(protocol.HostRequest, command)
	if err != nil || len(frame.Payload)+1 > nativeRotationWireLimit {
		return empty, errors.New("native rotation request exceeds limit")
	}
	pending := &nativeRotationPending{command: command, started: time.Now(), reply: make(chan nativeRotationReply, 1)}
	bridge.mu.Lock()
	if bridge.pending != nil || (command.Operation == "prepare" && bridge.active != nil) {
		bridge.mu.Unlock()
		return empty, errors.New("native rotation bridge busy")
	}
	select {
	case <-bridge.done:
		bridge.mu.Unlock()
		return empty, errors.New("native rotation bridge closed")
	default:
	}
	if command.Operation == "commit" {
		if lease == nil || bridge.active != lease || lease.bridge != bridge || !lease.commitSupported ||
			lease.submitted || !time.Now().Before(lease.deadline) || !nativeCommitMatchesLease(command, lease) {
			bridge.mu.Unlock()
			return empty, errors.New("native commit requires its original supported lease")
		}
		lease.submitted = true
		lease.operationID, lease.hostClaimID = command.Commit.OperationID, command.Commit.HostClaimID
		if lease.timer != nil {
			lease.timer.Stop()
		}
	} else if command.Operation == "release" && bridge.active != nil && bridge.active.submitted {
		bridge.mu.Unlock()
		return empty, errors.New("native commit reconciliation required")
	}
	bridge.pending = pending
	bridge.mu.Unlock()
	// Every submitted operation has a bounded response. Cancellation closes this stream; no replay.
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	interrupted := context.AfterFunc(ctx, bridge.close)
	defer interrupted()
	if bridge.writer.Write(frame) != nil {
		bridge.close()
		return empty, errors.New("native rotation request unavailable")
	}
	select {
	case <-ctx.Done():
		bridge.close()
		return empty, ctx.Err()
	case <-bridge.done:
		return empty, errors.New("native rotation bridge closed")
	case reply := <-pending.reply:
		return reply, nil
	}
}

func (session *Session) prepareNativeContextRotation(ctx context.Context, enrollment hostRotationEnrollment, turnID string) (*hostNativeRotationLease, error) {
	if enrollment.PaneID != session.id || enrollment.WorkerPID != os.Getpid() || enrollment.Client != "codex" || len(turnID) == 0 || len(turnID) > 256 {
		return nil, errors.New("native rotation unsupported")
	}
	if err := verifyHostRotationEnrollment(enrollment); err != nil {
		return nil, err
	}
	session.nativeRotationMu.Lock()
	bridge := session.nativeRotation
	session.nativeRotationMu.Unlock()
	if bridge == nil || bridge.providerPID != enrollment.AgentPID || bridge.providerStart != enrollment.AgentStart ||
		!nativeRotationCallerMatches(bridge.helperPID, bridge.providerPID, bridge.providerStart) {
		return nil, errors.New("native foreground bridge unavailable")
	}
	reply, err := bridge.call(ctx, nativeRotationCommand{Operation: "prepare", ThreadID: enrollment.SessionID, TurnID: turnID})
	if err != nil {
		return nil, err
	}
	if reply.State != "prepared" {
		return nil, errors.New("native foreground refused preparation")
	}
	binding, bindingErr := ReadNativeAgentBinding(enrollment.PaneID)
	if verifyHostRotationEnrollment(enrollment) != nil || bindingErr != nil ||
		binding.TranscriptPath != reply.Native.RolloutPath {
		bridge.close()
		return nil, errors.New("native rotation owner or rollout changed")
	}
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	lease := bridge.active
	if lease == nil || lease.native.ReservationID != reply.Native.ReservationID || !time.Now().Before(lease.deadline) {
		return nil, errors.New("native rotation was revoked")
	}
	return lease, nil
}

func (lease *hostNativeRotationLease) release(ctx context.Context) error {
	lease.bridge.mu.Lock()
	submitted := lease.submitted
	lease.bridge.mu.Unlock()
	if submitted {
		return errors.New("native commit reconciliation required")
	}
	select {
	case <-lease.revoked:
		return nil
	default:
	}
	reply, err := lease.bridge.call(ctx, nativeRotationCommand{Operation: "release",
		ThreadID: lease.native.ThreadID, ReservationID: lease.native.ReservationID})
	if err != nil {
		return err
	}
	if reply.State != "released" {
		lease.bridge.close()
		return errors.New("native release refused")
	}
	return nil
}
