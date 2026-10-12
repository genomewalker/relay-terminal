package daemon

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"

	"golang.org/x/sys/unix"
)

type hostNativeCompletionInput struct {
	journal     *hostNativeClaimJournal
	request     hostNativeClaimRequest
	claim       hostNativeClaimReceipt
	intent      hostNativeIntentReceipt
	fingerprint string
}
type hostNativeCompletionProof struct {
	Version            int                      `json:"v"`
	State              string                   `json:"state"`
	RequestSHA256      string                   `json:"request_sha256"`
	HostSnapshotSHA256 string                   `json:"host_snapshot_sha256"`
	JournalSHA256      string                   `json:"journal_sha256"`
	NativeRecords      map[string]string        `json:"native_records"`
	Receipt            nativeRotationCompletion `json:"receipt"`
}

// This observation is valid after the short preparation expires. It grants no
// native capability and never submits or retries a ledger/native mutation.
func readHostNativeCompletionInputAt(root *os.File, workerDirectory, sessionID string) (*hostNativeCompletionInput, error) {
	files := make(map[string]string)
	read := func(name string, target any) error {
		raw, err := readHostNativeClaimFile(root, name)
		if err != nil {
			return err
		}
		if err := decodeHostNativeRecord(raw, target); err != nil {
			return err
		}
		files[name] = hostRotationCapsuleHash(raw)
		return nil
	}
	var active hostNativeClaimActive
	if err := read(sessionID+".active.json", &active); err != nil {
		return nil, err
	}
	if active.Version != 1 || !validHostNativeUUID(active.OperationID) || !nativeWireHash(active.RequestSHA256) {
		return nil, errors.New("native completion active identity changed")
	}
	input := &hostNativeCompletionInput{journal: &hostNativeClaimJournal{workerDirectory, sessionID, active.OperationID, active.RequestSHA256}}
	if err := read(active.OperationID+".request.json", &input.request); err != nil {
		return nil, err
	}
	r := input.request
	if files[active.OperationID+".request.json"] != active.RequestSHA256 || r.SessionID != sessionID ||
		r.Epoch != active.OperationID || validateHostNativeStoredRequest(r) != nil {
		return nil, errors.New("native completion request changed")
	}
	for _, state := range []string{"claim_uncertain", "release_requested", "released"} {
		var stat unix.Stat_t
		err := unix.Fstatat(int(root.Fd()), active.OperationID+"."+state+".json", &stat, unix.AT_SYMLINK_NOFOLLOW)
		if !errors.Is(err, unix.ENOENT) {
			return nil, errors.New("native completion conflicts with another phase")
		}
	}
	for _, state := range []string{"claim_received", "commit_requested"} {
		var phase hostNativeClaimPhase
		if err := read(active.OperationID+"."+state+".json", &phase); err != nil {
			return nil, err
		}
		if phase.Version != 1 || phase.State != state || phase.RequestSHA256 != active.RequestSHA256 || phase.Claim == nil {
			return nil, errors.New("native completion lacks durable claim and commit")
		}
		raw, _ := json.Marshal(phase.Claim)
		if _, err := decodeHostNativeClaimIdentity(raw, r, false); err != nil {
			return nil, err
		}
		if state == "claim_received" {
			input.claim = *phase.Claim
		} else if input.claim != *phase.Claim {
			return nil, errors.New("native completion claim changed")
		}
	}
	var intent hostNativeIntentPhase
	if err := read(active.OperationID+".intent_received.json", &intent); err != nil {
		return nil, err
	}
	if intent.Version != 1 || intent.State != "intent_received" || intent.RequestSHA256 != active.RequestSHA256 {
		return nil, errors.New("native completion intent changed")
	}
	intentRequest := hostNativeIntentRequest{1, sessionID, r.Epoch, input.claim.ClaimID, input.claim.Token, r.HostClaimID, active.RequestSHA256}
	raw, _ := json.Marshal(intent.Intent)
	if _, err := decodeHostNativeIntent(raw, intentRequest, input.claim); err != nil {
		return nil, err
	}
	input.intent = intent.Intent
	var handoff hostNativeHandoffPhase
	if err := read(active.OperationID+".native_handoff_requested.json", &handoff); err != nil {
		return nil, err
	}
	if handoff.Version != 1 || handoff.State != "native_handoff_requested" || handoff.RequestSHA256 != active.RequestSHA256 ||
		handoff.Intent != input.intent || !nativeWireHash(handoff.EnvelopeSHA256) {
		return nil, errors.New("native completion handoff changed")
	}
	b := r.Source
	source := hostRotationSource{Enrollment: b.Enrollment,
		Boundary:        hostRotationSourceBoundary{TurnID: b.TurnID, TurnSeq: b.TurnSeq, TranscriptMtimeMS: b.TranscriptMtimeMS, TranscriptBytes: b.TranscriptBytes},
		BindingRevision: b.BindingRevision, TranscriptSHA256: b.SourceSHA256, EvidenceSHA256: b.EvidenceSHA256, Chunks: make([]string, b.SourceChunks)}
	capsule, err := readHostRotationCapsule(context.Background(), workerDirectory, r.Capsule, source)
	if err != nil {
		return nil, err
	}
	envelope := hostNativeCommitEnvelope{1, r.Epoch, r.HostClaimID, r.SessionID, b.TurnID, r.Reservation, input.intent, r.Capsule.SHA256,
		base64.StdEncoding.EncodeToString([]byte(capsule))}
	raw, err = json.Marshal(envelope)
	if err != nil || hostRotationCapsuleHash(raw) != handoff.EnvelopeSHA256 {
		return nil, errors.New("native completion handoff bytes changed")
	}
	raw, _ = json.Marshal(files)
	input.fingerprint = hostRotationCapsuleHash(raw)
	return input, nil
}
func readHostNativeCompletionInput(workerDirectory, sessionID string) (*hostNativeCompletionInput, error) {
	if !validHostNativeUUID(sessionID) {
		return nil, errors.New("invalid native completion source")
	}
	root, lock, err := lockHostNativeClaimRoot(workerDirectory, false)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	defer lock.Close()
	return readHostNativeCompletionInputAt(root, workerDirectory, sessionID)
}

func verifyHostNativeCompletionOwner(e hostRotationEnrollment, receipt nativeRotationCompletion) error {
	if e.Client != "codex" || e.AgentPID <= 1 || e.WorkerPID <= 1 || e.AgentStart == 0 || e.WorkerStart == 0 ||
		receipt.ProcessID != uint32(e.AgentPID) || receipt.Source.ThreadID != e.SessionID || !receipt.Source.valid() {
		return errors.New("native completion process identity changed")
	}
	server := NewServer()
	manifest, err := loadManifest(server.manifestPath(e.PaneID))
	if err != nil || manifest.SessionID != e.PaneID || manifest.WorkerPID != e.WorkerPID ||
		manifest.WorkerStartTime != e.WorkerStart || manifest.NodeBootID != e.NodeBootID || validateWorkerIdentity(manifest) != nil {
		return errors.New("native completion worker changed")
	}
	start, err := NativeAgentIncarnation(e.PaneID, e.AgentPID, "codex")
	if err != nil || start != e.AgentStart {
		return errors.New("native completion provider incarnation changed")
	}
	binding, err := ReadNativeAgentBinding(e.PaneID)
	if err != nil || binding.Producer.Provider != "codex" || binding.Producer.ProcessID != e.AgentPID ||
		binding.Producer.ProcessStart != e.AgentStart {
		return errors.New("native completion foreground owner changed")
	}
	source := binding.SessionID == e.SessionID && binding.TranscriptPath == receipt.Source.RolloutPath
	target := binding.SessionID == receipt.TargetThreadID && binding.TranscriptPath == receipt.TargetRolloutPath
	if !source && !target {
		return errors.New("native completion foreground identity changed")
	}
	return nil
}

func verifyAndRecordHostNativeCompletion(ctx context.Context, workerDirectory, sessionID string, receipt nativeRotationCompletion,
	verifyOwner func(hostRotationEnrollment, nativeRotationCompletion) error) (*hostNativeCompletionProof, error) {
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if verifyOwner == nil {
		return nil, errors.New("native completion owner verifier unavailable")
	}
	input, err := readHostNativeCompletionInput(workerDirectory, sessionID)
	if err != nil {
		return nil, err
	}
	r := input.request
	if !receipt.valid(r.Epoch, r.HostClaimID) || !receipt.Source.matches(r.Reservation.Native) ||
		receipt.CapsuleSHA256 != r.Capsule.SHA256 || receipt.ProcessID != uint32(r.Source.Enrollment.AgentPID) {
		return nil, errors.New("native completion differs from durable handoff")
	}
	if err := verifyOwner(r.Source.Enrollment, receipt); err != nil {
		return nil, err
	}
	journal, err := readHostNativeRestorationJournal(receipt)
	if err != nil {
		return nil, err
	}
	if err := verifyOwner(r.Source.Enrollment, receipt); err != nil {
		return nil, err
	}
	after, err := readHostNativeRestorationJournal(receipt)
	if err != nil || after.fingerprint != journal.fingerprint || !os.SameFile(after.directory, journal.directory) {
		return nil, errors.New("native completion journal changed during verification")
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	root, lock, err := lockHostNativeClaimRoot(workerDirectory, false)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	defer lock.Close()
	current, err := readHostNativeCompletionInputAt(root, workerDirectory, sessionID)
	if err != nil || current.fingerprint != input.fingerprint {
		return nil, errors.New("native completion host intent changed during verification")
	}
	proof := &hostNativeCompletionProof{1, "native_restored_verified", input.journal.requestSHA256, input.fingerprint,
		journal.fingerprint, journal.records, receipt}
	raw, err := json.Marshal(proof)
	if err != nil {
		return nil, err
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if err := writeHostNativeClaimFile(root, r.Epoch+".native_restored_verified.json", raw, true); err != nil {
		return nil, err
	}
	// The active fence remains. Registration, ledger ACK, native retirement and
	// ordered host finalization are separate durable steps.
	return proof, nil
}
func (claim *hostNativeRotationClaim) recordNativeCompletion(ctx context.Context, observation nativeRotationReply) (*hostNativeCompletionProof, error) {
	if claim == nil {
		return nil, errors.New("native claim unavailable")
	}
	claim.mu.Lock()
	if claim.journal == nil || !claim.handoffAttempted || observation.State != "restored" || observation.Completion == nil ||
		observation.OperationID != claim.request.Epoch || observation.HostClaimID != claim.request.HostClaimID {
		claim.mu.Unlock()
		return nil, errors.New("native completion observation unavailable")
	}
	directory, session := claim.journal.workerDirectory, claim.request.SessionID
	receipt := *observation.Completion
	claim.mu.Unlock()
	return verifyAndRecordHostNativeCompletion(ctx, directory, session, receipt, verifyHostNativeCompletionOwner)
}
