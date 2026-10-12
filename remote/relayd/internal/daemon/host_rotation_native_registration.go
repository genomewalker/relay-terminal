package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"strings"
)

type hostNativeRegistrationTarget struct {
	Enrollment      hostRotationEnrollment `json:"enrollment"`
	RuntimeID       string                 `json:"runtime_id"`
	RolloutPath     string                 `json:"rollout_path"`
	BindingRevision string                 `json:"binding_revision"`
	ThreadID        *string                `json:"thread_id"`
}
type hostNativeRegistrationRequest struct {
	hostNativeIntentRequest
	Receipt hostNativeJournalRecord      `json:"receipt"`
	Target  hostNativeRegistrationTarget `json:"target"`
}
type hostNativeRegistrationReceipt struct {
	Version       int                          `json:"v"`
	Mode          string                       `json:"mode"`
	SessionID     string                       `json:"session_id"`
	Epoch         string                       `json:"epoch"`
	OperationID   string                       `json:"operation_id"`
	HostClaimID   string                       `json:"host_claim_id"`
	ClaimID       string                       `json:"claim_id"`
	Token         uint64                       `json:"token"`
	RequestSHA256 string                       `json:"request_sha256"`
	Seq           uint64                       `json:"seq"`
	NewSessionID  string                       `json:"new_session_id"`
	NativeReceipt hostNativeJournalRecord      `json:"native_receipt"`
	Target        hostNativeRegistrationTarget `json:"target"`
}
type hostNativeRegistrationPhase struct {
	Version            int                            `json:"v"`
	State              string                         `json:"state"`
	HostSnapshotSHA256 string                         `json:"host_snapshot_sha256"`
	Completion         hostNativeCompletionProof      `json:"completion"`
	Request            hostNativeRegistrationRequest  `json:"request"`
	Registration       *hostNativeRegistrationReceipt `json:"registration"`
}
type hostNativeRegistrationDependencies struct {
	binding func(hostRotationEnrollment, nativeRotationCompletion) (string, error)
	ledger  func(context.Context, string, any) (json.RawMessage, error)
}

// The broader completion observer permits the old source while attachment is
// catching up. Registration additionally requires the exact attached target.
func readHostNativeRegistrationBinding(e hostRotationEnrollment, r nativeRotationCompletion) (string, error) {
	if err := verifyHostNativeCompletionOwner(e, r); err != nil {
		return "", err
	}
	b, err := ReadNativeAgentBinding(e.PaneID)
	if err != nil || b.SessionID != r.TargetThreadID || b.TranscriptPath != r.TargetRolloutPath ||
		b.Producer.Provider != "codex" || b.Producer.ProcessID != e.AgentPID || b.Producer.ProcessStart != e.AgentStart ||
		strings.TrimSpace(b.Revision) == "" || len(b.Revision) > 256 {
		return "", errors.New("native registration target is not attached")
	}
	if err := verifyHostNativeCompletionOwner(e, r); err != nil {
		return "", err
	}
	return b.Revision, nil
}

// Compare JSON trees with exact integers so missing nullable or zero-valued
// fields cannot collapse into a valid decoded Go value.
func hostNativeRegistrationExactShape(raw []byte, value any) bool {
	expected, err := json.Marshal(value)
	if err != nil {
		return false
	}
	var actualTree, expectedTree any
	actual := json.NewDecoder(bytes.NewReader(raw))
	actual.UseNumber()
	wanted := json.NewDecoder(bytes.NewReader(expected))
	wanted.UseNumber()
	return actual.Decode(&actualTree) == nil && wanted.Decode(&expectedTree) == nil && reflect.DeepEqual(actualTree, expectedTree)
}

func decodeHostNativeRegistration(raw []byte, q hostNativeRegistrationRequest, intentSeq uint64) (hostNativeRegistrationReceipt, error) {
	var r hostNativeRegistrationReceipt
	if decodeHostNativeRecord(raw, &r) != nil || !hostNativeRegistrationExactShape(raw, r) || r.Version != 1 || r.Mode != "native_v1" ||
		r.SessionID != q.SessionID || r.Epoch != q.Epoch || r.OperationID != q.Epoch ||
		r.HostClaimID != q.HostClaimID || r.ClaimID != q.ClaimID || r.Token != q.Token ||
		r.RequestSHA256 != q.RequestSHA256 || r.Seq <= intentSeq || r.NewSessionID != q.Target.Enrollment.SessionID ||
		!reflect.DeepEqual(r.NativeReceipt, q.Receipt) || !reflect.DeepEqual(r.Target, q.Target) {
		return hostNativeRegistrationReceipt{}, errors.New("native registration receipt mismatch")
	}
	return r, nil
}

type hostNativeRegistrationSession struct {
	SessionID      string          `json:"session_id"`
	ThreadID       json.RawMessage `json:"thread_id"`
	Client         string          `json:"client"`
	ProjectDir     string          `json:"project_dir"`
	TranscriptPath string          `json:"transcript_path"`
	Status         string          `json:"status"`
	EndedAt        json.RawMessage `json:"ended_at"`
	MetadataJSON   string          `json:"metadata_json"`
}

func readHostNativeRegistrationSession(ctx context.Context, deps hostNativeRegistrationDependencies,
	e hostRotationEnrollment, rollout string) (hostNativeRegistrationSession, *string, json.RawMessage, error) {
	var row hostNativeRegistrationSession
	fail := func() (hostNativeRegistrationSession, *string, json.RawMessage, error) {
		return row, nil, nil, errors.New("native registration ledger session mismatch")
	}
	raw, err := deps.ledger(ctx, "session_get", map[string]any{"session_id": e.SessionID})
	if err != nil {
		return row, nil, nil, err
	}
	if len(raw) > hostNativeClaimRecordLimit || !rotationSourceJSONUnambiguous(raw) || json.Unmarshal(raw, &row) != nil ||
		row.SessionID != e.SessionID || row.Client != "codex" || row.ProjectDir != e.CWD || row.TranscriptPath != rollout ||
		row.Status != "active" || string(row.EndedAt) != "null" || len(row.ThreadID) == 0 ||
		len(row.MetadataJSON) > hostNativeClaimRecordLimit || !rotationSourceJSONUnambiguous([]byte(row.MetadataJSON)) {
		return fail()
	}
	var thread *string
	if json.Unmarshal(row.ThreadID, &thread) != nil || thread != nil && (strings.TrimSpace(*thread) == "" || len(*thread) > 4096) {
		return fail()
	}
	var metadata struct {
		Owner        string          `json:"owner"`
		Registration json.RawMessage `json:"native_registration"`
	}
	if json.Unmarshal([]byte(row.MetadataJSON), &metadata) != nil || metadata.Owner != "relay" {
		return fail()
	}
	return row, thread, metadata.Registration, nil
}

func readHostNativeRegistrationStatus(ctx context.Context, deps hostNativeRegistrationDependencies,
	q hostNativeRegistrationRequest, intentSeq uint64) (hostNativeRegistrationReceipt, error) {
	raw, err := deps.ledger(ctx, "rotation_status", map[string]any{"session_id": q.SessionID, "epoch": q.Epoch})
	if err != nil {
		return hostNativeRegistrationReceipt{}, err
	}
	var status struct {
		Version      int             `json:"v"`
		SessionID    string          `json:"session_id"`
		Epoch        string          `json:"epoch"`
		Client       string          `json:"client"`
		CWD          string          `json:"cwd"`
		Owner        string          `json:"owner"`
		Registration json.RawMessage `json:"registration"`
	}
	if len(raw) > 262144 || !rotationSourceJSONUnambiguous(raw) || json.Unmarshal(raw, &status) != nil ||
		status.Version != 1 || status.SessionID != q.SessionID || status.Epoch != q.Epoch ||
		status.Client != "codex" || status.CWD != q.Target.Enrollment.CWD || status.Owner != "relay" {
		return hostNativeRegistrationReceipt{}, errors.New("native registration status identity changed")
	}
	return decodeHostNativeRegistration(status.Registration, q, intentSeq)
}

// Check both members of the atomic ledger write, including the complete
// provenance on the destination. Missing rows are never adopted or repaired.
func reconcileHostNativeRegistration(ctx context.Context, deps hostNativeRegistrationDependencies,
	q hostNativeRegistrationRequest, intentSeq uint64) (hostNativeRegistrationReceipt, error) {
	r, err := readHostNativeRegistrationStatus(ctx, deps, q, intentSeq)
	if err != nil {
		return r, err
	}
	_, thread, provenance, err := readHostNativeRegistrationSession(ctx, deps, q.Target.Enrollment, q.Target.RolloutPath)
	if err != nil {
		return r, err
	}
	saved, err := decodeHostNativeRegistration(provenance, q, intentSeq)
	if err != nil || !reflect.DeepEqual(saved, r) || !reflect.DeepEqual(thread, q.Target.ThreadID) {
		return r, errors.New("native registration destination provenance changed")
	}
	after, err := readHostNativeRegistrationStatus(ctx, deps, q, intentSeq)
	if err != nil || !reflect.DeepEqual(after, r) {
		return r, errors.New("native registration changed during reconciliation")
	}
	return r, nil
}

// An exclusive marker admits the initial ledger RPC. Repeats require separate
// exact pending-state validation; partial markers never permit a retry.
func recordHostNativeRegistrationPhase(input *hostNativeCompletionInput, phase hostNativeRegistrationPhase, begin bool) (bool, error) {
	root, lock, err := lockHostNativeClaimRoot(input.journal.workerDirectory, false)
	if err != nil {
		return false, err
	}
	defer root.Close()
	defer lock.Close()
	current, err := readHostNativeCompletionInputAt(root, input.journal.workerDirectory, input.request.SessionID)
	if err != nil || current.fingerprint != input.fingerprint {
		return false, errors.New("native registration host intent changed")
	}
	raw, err := readHostNativeClaimFile(root, input.request.Epoch+".native_restored_verified.json")
	var completion hostNativeCompletionProof
	if err != nil || decodeHostNativeRecord(raw, &completion) != nil || !reflect.DeepEqual(completion, phase.Completion) {
		return false, errors.New("native registration completion proof changed")
	}
	name := input.request.Epoch + ".registration_requested.json"
	requested := phase
	requested.State = "registration_requested"
	requested.Registration = nil
	raw, err = readHostNativeClaimFile(root, name)
	if err == nil {
		var saved hostNativeRegistrationPhase
		if decodeHostNativeRecord(raw, &saved) != nil || !hostNativeRegistrationExactShape(raw, saved) || !reflect.DeepEqual(saved, requested) {
			return false, errors.New("native registration request changed")
		}
		if begin {
			return false, nil
		}
	} else if !errors.Is(err, os.ErrNotExist) || !begin {
		return false, errors.New("native registration request unavailable")
	} else {
		if _, err := readHostNativeClaimFile(root, input.request.Epoch+".registration_received.json"); !errors.Is(err, os.ErrNotExist) {
			return false, errors.New("native registration receipt lacks durable request")
		}
		data, err := json.Marshal(requested)
		if err != nil {
			return false, err
		}
		return true, writeHostNativeClaimFile(root, name, data, false)
	}
	data, err := json.Marshal(phase)
	if err != nil {
		return false, err
	}
	return false, writeHostNativeClaimFile(root, input.request.Epoch+".registration_received.json", data, true)
}

func registerHostNativeCompletion(ctx context.Context, workerDirectory, sessionID string, receipt nativeRotationCompletion,
	deps hostNativeRegistrationDependencies) (*hostNativeRegistrationReceipt, error) {
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if deps.binding == nil || deps.ledger == nil {
		return nil, errors.New("native registration dependencies unavailable")
	}
	input, err := readHostNativeCompletionInput(workerDirectory, sessionID)
	if err != nil {
		return nil, err
	}
	e := input.request.Source.Enrollment
	revision, err := deps.binding(e, receipt)
	if err != nil || strings.TrimSpace(revision) == "" || len(revision) > 256 {
		return nil, errors.New("native registration binding unavailable")
	}
	owner := func(e hostRotationEnrollment, r nativeRotationCompletion) error {
		current, err := deps.binding(e, r)
		if err != nil {
			return err
		}
		if current != revision {
			return errors.New("native registration binding changed")
		}
		return nil
	}
	verify := func() (*hostNativeCompletionProof, error) {
		return verifyAndRecordHostNativeCompletion(ctx, workerDirectory, sessionID, receipt, owner)
	}
	proof, err := verify()
	if err != nil {
		return nil, err
	}
	_, thread, _, err := readHostNativeRegistrationSession(ctx, deps, e, receipt.Source.RolloutPath)
	if err != nil {
		return nil, err
	}
	targetEnrollment := e
	targetEnrollment.SessionID = receipt.TargetThreadID
	q := hostNativeRegistrationRequest{
		hostNativeIntentRequest{1, sessionID, input.request.Epoch, input.claim.ClaimID, input.claim.Token, input.request.HostClaimID, input.journal.requestSHA256},
		expectedHostNativeJournalRecord(receipt, "restored"),
		hostNativeRegistrationTarget{targetEnrollment, receipt.TargetRuntimeID, receipt.TargetRolloutPath, revision, thread},
	}
	phase := hostNativeRegistrationPhase{1, "registration_requested", input.fingerprint, *proof, q, nil}
	check := func() error {
		current, err := verify()
		if err != nil {
			return err
		}
		if !reflect.DeepEqual(current, proof) {
			return errors.New("native registration completion changed")
		}
		_, currentThread, _, err := readHostNativeRegistrationSession(ctx, deps, e, receipt.Source.RolloutPath)
		if err != nil {
			return err
		}
		if !reflect.DeepEqual(currentThread, thread) {
			return errors.New("native registration logical task changed")
		}
		return ctx.Err()
	}
	if err := check(); err != nil {
		return nil, err
	}
	submit, err := recordHostNativeRegistrationPhase(input, phase, true)
	if err != nil {
		return nil, err
	}
	var reply *hostNativeRegistrationReceipt
	var r hostNativeRegistrationReceipt
	retry := false
	if !submit {
		r, err = reconcileHostNativeRegistration(ctx, deps, q, input.intent.Seq)
		if err != nil {
			if err := verifyHostNativeLedgerRetryPending(ctx, deps, input, q, nil); err != nil {
				return nil, err
			}
			submit, retry = true, true
		}
	}
	if submit {
		if err := check(); err != nil {
			return nil, err
		}
		if retry {
			if err := authorizeHostNativeRegistrationRetry(input, phase); err != nil {
				return nil, err
			}
		}
		raw, callErr := deps.ledger(ctx, "rotation_native_register", q)
		if callErr == nil {
			decoded, decodeErr := decodeHostNativeRegistration(raw, q, input.intent.Seq)
			if decodeErr != nil {
				return nil, decodeErr
			}
			reply = &decoded
		}
		// At most one identical ledger submission per invocation. Even a lost
		// reply is first reconciled; native close/restore are never repeated.
		r, err = reconcileHostNativeRegistration(ctx, deps, q, input.intent.Seq)
	}
	if err != nil {
		return nil, err
	}
	if reply != nil && !reflect.DeepEqual(*reply, r) {
		return nil, errors.New("native registration reply differs from durable ledger")
	}
	if err := check(); err != nil {
		return nil, err
	}
	phase.State = "registration_received"
	phase.Registration = &r
	if _, err := recordHostNativeRegistrationPhase(input, phase, false); err != nil {
		return nil, err
	}
	return &r, nil
}

func (claim *hostNativeRotationClaim) registerNativeCompletion(ctx context.Context, observation nativeRotationReply) (*hostNativeRegistrationReceipt, error) {
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
	return registerHostNativeCompletion(ctx, directory, session, receipt, hostNativeRegistrationDependencies{
		binding: readHostNativeRegistrationBinding, ledger: callHostNativeLedger,
	})
}
