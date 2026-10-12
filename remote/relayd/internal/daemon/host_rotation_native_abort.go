package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"reflect"
)

type hostNativeAbortRequest struct {
	hostNativeIntentRequest
	Receipt hostNativeRefusalRecord `json:"receipt"`
}
type hostNativeAbortReceipt struct {
	Version            int                     `json:"v"`
	Mode               string                  `json:"mode"`
	SessionID          string                  `json:"session_id"`
	Epoch              string                  `json:"epoch"`
	OperationID        string                  `json:"operation_id"`
	HostClaimID        string                  `json:"host_claim_id"`
	ClaimID            string                  `json:"claim_id"`
	Token              uint64                  `json:"token"`
	RequestSHA256      string                  `json:"request_sha256"`
	Seq                uint64                  `json:"seq"`
	LifecyclePerformed bool                    `json:"lifecycle_performed"`
	NativeReceipt      hostNativeRefusalRecord `json:"native_receipt"`
}
type hostNativeAbortPhase struct {
	Version               int                     `json:"v"`
	State                 string                  `json:"state"`
	RefusalSnapshotSHA256 string                  `json:"refusal_snapshot_sha256"`
	Refusal               hostNativeRefusalProof  `json:"refusal"`
	Request               hostNativeAbortRequest  `json:"request"`
	Abort                 *hostNativeAbortReceipt `json:"abort"`
}
type hostNativeAbortInput struct {
	completion  *hostNativeCompletionInput
	refusal     hostNativeRefusalProof
	fingerprint string
}
type hostNativeAbortDependencies struct {
	owner  func(hostRotationEnrollment, hostNativeRefusalRecord) error
	ledger func(context.Context, string, any) (json.RawMessage, error)
}

func readHostNativeAbortInputAt(root *os.File, directory, sessionID string) (*hostNativeAbortInput, error) {
	c, err := readHostNativeCompletionInputAt(root, directory, sessionID)
	if err != nil {
		return nil, err
	}
	if err := checkHostNativeRefusalConflictsAt(root, c.request.Epoch); err != nil {
		return nil, err
	}
	raw, err := readHostNativeClaimFile(root, c.request.Epoch+".native_refused_verified.json")
	var p hostNativeRefusalProof
	if err != nil || decodeHostNativeRecord(raw, &p) != nil || !hostNativeRegistrationExactShape(raw, p) ||
		p.Version != 1 || p.State != "native_refused_verified" || p.RequestSHA256 != c.journal.requestSHA256 ||
		p.HostSnapshotSHA256 != c.fingerprint || !nativeWireHash(p.JournalSHA256) ||
		!validHostNativeRefusal(p.Receipt, c.request) || p.JournalDirectory == "" {
		return nil, errors.New("native abort lacks exact durable refusal")
	}
	hashes, _ := json.Marshal(map[string]string{"host": c.fingerprint, "refusal": hostRotationCapsuleHash(raw)})
	return &hostNativeAbortInput{c, p, hostRotationCapsuleHash(hashes)}, nil
}
func readHostNativeAbortInput(directory, sessionID string) (*hostNativeAbortInput, error) {
	if !validHostNativeUUID(sessionID) {
		return nil, errors.New("invalid native abort source")
	}
	root, lock, err := lockHostNativeClaimRoot(directory, false)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	defer lock.Close()
	return readHostNativeAbortInputAt(root, directory, sessionID)
}
func hostNativeAbortRequestFor(input *hostNativeAbortInput) hostNativeAbortRequest {
	c := input.completion
	return hostNativeAbortRequest{hostNativeIntentRequest{1, c.request.SessionID, c.request.Epoch,
		c.claim.ClaimID, c.claim.Token, c.request.HostClaimID, c.journal.requestSHA256}, input.refusal.Receipt}
}
func decodeHostNativeAbort(raw []byte, q hostNativeAbortRequest, intentSeq uint64) (hostNativeAbortReceipt, error) {
	var a hostNativeAbortReceipt
	if decodeHostNativeRecord(raw, &a) != nil || !hostNativeRegistrationExactShape(raw, a) ||
		a.Version != 1 || a.Mode != "native_v1" || a.SessionID != q.SessionID || a.Epoch != q.Epoch ||
		a.OperationID != q.Epoch || a.HostClaimID != q.HostClaimID || a.ClaimID != q.ClaimID || a.Token != q.Token ||
		a.RequestSHA256 != q.RequestSHA256 || a.Seq <= intentSeq || a.LifecyclePerformed || a.NativeReceipt != q.Receipt {
		return hostNativeAbortReceipt{}, errors.New("native ledger abort identity mismatch")
	}
	return a, nil
}

// Observe the explicit historical epoch, including the atomic closed-claim and
// aborted-intent revision. A timeout, expired lease or closed flag is insufficient.
func readHostNativeAbortStatus(ctx context.Context, deps hostNativeAbortDependencies, input *hostNativeAbortInput) (*hostNativeAbortReceipt, error) {
	q := hostNativeAbortRequestFor(input)
	raw, err := deps.ledger(ctx, "rotation_status", map[string]any{"session_id": q.SessionID, "epoch": q.Epoch})
	if err != nil {
		return nil, err
	}
	var s struct {
		Version            int             `json:"v"`
		SessionID          string          `json:"session_id"`
		Epoch              string          `json:"epoch"`
		Client             string          `json:"client"`
		CWD                string          `json:"cwd"`
		Owner              string          `json:"owner"`
		Live               *bool           `json:"live"`
		LifecyclePerformed *bool           `json:"lifecycle_performed"`
		NewSessionID       json.RawMessage `json:"new_session_id"`
		Claim              json.RawMessage `json:"claim"`
		Intent             json.RawMessage `json:"intent"`
		Registration       json.RawMessage `json:"registration"`
		Ack                json.RawMessage `json:"ack"`
		Abort              json.RawMessage `json:"abort"`
	}
	fail := func() (*hostNativeAbortReceipt, error) { return nil, errors.New("native ledger abort status mismatch") }
	null := func(r json.RawMessage) bool { return len(r) == 0 || string(r) == "null" }
	if len(raw) > 262144 || !rotationSourceJSONUnambiguous(raw) || json.Unmarshal(raw, &s) != nil ||
		s.Version != 1 || s.SessionID != q.SessionID || s.Epoch != q.Epoch || s.Client != "codex" ||
		s.CWD != input.completion.request.Source.Enrollment.CWD || s.Owner != "relay" ||
		s.Live == nil || s.LifecyclePerformed == nil || *s.LifecyclePerformed ||
		string(s.NewSessionID) != "null" || string(s.Ack) != "null" || !null(s.Registration) {
		return fail()
	}
	if null(s.Abort) {
		var c hostNativeClaimReceipt
		var i hostNativeIntentReceipt
		if decodeHostNativeRecord(s.Claim, &c) != nil || !hostNativeRegistrationExactShape(s.Claim, c) ||
			decodeHostNativeRecord(s.Intent, &i) != nil || !hostNativeRegistrationExactShape(s.Intent, i) ||
			c != input.completion.claim || c.Closed || i != input.completion.intent || i.State != "commit_requested" {
			return fail()
		}
		return nil, ctx.Err()
	}
	a, err := decodeHostNativeAbort(s.Abort, q, input.completion.intent.Seq)
	if err != nil {
		return nil, err
	}
	var c struct {
		hostNativeClaimReceipt
		AbortSeq uint64 `json:"abort_seq"`
	}
	var i struct {
		hostNativeIntentReceipt
		AbortSeq uint64 `json:"abort_seq"`
	}
	wantC, wantI := input.completion.claim, input.completion.intent
	wantC.Closed = true
	wantI.State = "aborted"
	if *s.Live || decodeHostNativeRecord(s.Claim, &c) != nil || !hostNativeRegistrationExactShape(s.Claim, c) ||
		decodeHostNativeRecord(s.Intent, &i) != nil || !hostNativeRegistrationExactShape(s.Intent, i) ||
		c.hostNativeClaimReceipt != wantC || i.hostNativeIntentReceipt != wantI || c.AbortSeq != a.Seq || i.AbortSeq != a.Seq {
		return fail()
	}
	return &a, ctx.Err()
}
func reconcileHostNativeAbort(ctx context.Context, deps hostNativeAbortDependencies, input *hostNativeAbortInput) (*hostNativeAbortReceipt, error) {
	before, err := readHostNativeAbortStatus(ctx, deps, input)
	if err != nil {
		return nil, err
	}
	after, err := readHostNativeAbortStatus(ctx, deps, input)
	if err != nil || !reflect.DeepEqual(before, after) {
		return nil, errors.New("native ledger abort changed during observation")
	}
	return before, ctx.Err()
}
func verifyHostNativeAbortEvidence(ctx context.Context, deps hostNativeAbortDependencies, input *hostNativeAbortInput) error {
	c := input.completion
	p, err := verifyAndRecordHostNativeRefusal(ctx, c.journal.workerDirectory, c.request.SessionID, input.refusal.JournalDirectory, deps.owner)
	if err != nil {
		return err
	}
	if !reflect.DeepEqual(*p, input.refusal) {
		return errors.New("native abort refusal evidence changed")
	}
	return ctx.Err()
}
func recordHostNativeAbortPhase(input *hostNativeAbortInput, phase hostNativeAbortPhase, begin, allowNew bool) (bool, error) {
	c := input.completion
	root, lock, err := lockHostNativeClaimRoot(c.journal.workerDirectory, false)
	if err != nil {
		return false, err
	}
	defer root.Close()
	defer lock.Close()
	current, err := readHostNativeAbortInputAt(root, c.journal.workerDirectory, c.request.SessionID)
	if err != nil || current.fingerprint != input.fingerprint {
		return false, errors.New("native abort host refusal changed")
	}
	want := phase
	want.State = "ledger_abort_requested"
	want.Abort = nil
	name := c.request.Epoch + ".ledger_abort_requested.json"
	raw, err := readHostNativeClaimFile(root, name)
	if err == nil {
		if !hostNativeRegistrationExactShape(raw, want) {
			return false, errors.New("native abort request changed")
		}
	} else {
		if !errors.Is(err, os.ErrNotExist) || !begin || !allowNew {
			return false, errors.New("native abort durable request unavailable")
		}
		if _, err := readHostNativeClaimFile(root, c.request.Epoch+".ledger_abort_received.json"); !errors.Is(err, os.ErrNotExist) {
			return false, errors.New("native abort receipt lacks durable request")
		}
		raw, err := json.Marshal(want)
		if err != nil {
			return false, err
		}
		return true, writeHostNativeClaimFile(root, name, raw, false)
	}
	if begin {
		raw, err := readHostNativeClaimFile(root, c.request.Epoch+".ledger_abort_received.json")
		if errors.Is(err, os.ErrNotExist) {
			return false, nil
		}
		var saved hostNativeAbortPhase
		if err != nil || decodeHostNativeRecord(raw, &saved) != nil || !hostNativeRegistrationExactShape(raw, saved) || saved.Abort == nil {
			return false, errors.New("native abort receipt malformed")
		}
		a, err := decodeHostNativeAbort(mustMarshalHostNativeAbort(saved.Abort), want.Request, c.intent.Seq)
		saved.Abort = nil
		saved.State = "ledger_abort_requested"
		if err != nil || !reflect.DeepEqual(saved, want) || a.Seq == 0 {
			return false, errors.New("native abort receipt changed")
		}
		return false, nil
	}
	raw, err = json.Marshal(phase)
	if err != nil {
		return false, err
	}
	return false, writeHostNativeClaimFile(root, c.request.Epoch+".ledger_abort_received.json", raw, true)
}
func mustMarshalHostNativeAbort(value any) []byte { raw, _ := json.Marshal(value); return raw }

// Exact ledger retry is bounded to one call per invocation and requires two
// matching pending observations plus the immutable request and native evidence.
// No native command is submitted here. The active source fence remains present.
func abortHostNativeRefusal(ctx context.Context, directory, sessionID string, deps hostNativeAbortDependencies) (*hostNativeAbortReceipt, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if deps.owner == nil || deps.ledger == nil {
		return nil, errors.New("native abort dependencies unavailable")
	}
	input, err := readHostNativeAbortInput(directory, sessionID)
	if err != nil {
		return nil, err
	}
	check := func() error { return verifyHostNativeAbortEvidence(ctx, deps, input) }
	if err := check(); err != nil {
		return nil, err
	}
	observed, err := reconcileHostNativeAbort(ctx, deps, input)
	if err != nil {
		return nil, err
	}
	q := hostNativeAbortRequestFor(input)
	phase := hostNativeAbortPhase{1, "ledger_abort_requested", input.fingerprint, input.refusal, q, nil}
	submit, err := recordHostNativeAbortPhase(input, phase, true, observed == nil)
	if err != nil {
		return nil, err
	}
	var reply *hostNativeAbortReceipt
	if observed == nil {
		if err := check(); err != nil {
			return nil, err
		}
		if !submit {
			if err := authorizeHostNativeLedgerRetry(directory, q.Epoch, "ledger_abort_requested", "ledger_abort_received", phase, func(root *os.File) error {
				current, err := readHostNativeAbortInputAt(root, directory, sessionID)
				if err != nil || current.fingerprint != input.fingerprint {
					return errors.New("native abort retry refusal changed")
				}
				return nil
			}); err != nil {
				return nil, err
			}
		}
		raw, callErr := deps.ledger(ctx, "rotation_native_abort", q)
		if callErr == nil {
			a, err := decodeHostNativeAbort(raw, q, input.completion.intent.Seq)
			if err != nil {
				return nil, err
			}
			reply = &a
		}
		observed, err = reconcileHostNativeAbort(ctx, deps, input)
		if err != nil {
			return nil, err
		}
	}
	if observed == nil {
		return nil, errors.New("native ledger abort remains pending")
	}
	if reply != nil && !reflect.DeepEqual(reply, observed) {
		return nil, errors.New("native ledger abort reply differs from durable history")
	}
	if err := check(); err != nil {
		return nil, err
	}
	phase.State = "ledger_abort_received"
	phase.Abort = observed
	if _, err := recordHostNativeAbortPhase(input, phase, false, false); err != nil {
		return nil, err
	}
	return observed, nil
}

func readHostNativeDriverRefusal(directory string, input *hostNativeCompletionInput) (*hostNativeRefusalProof, error) {
	root, lock, err := lockHostNativeClaimRoot(directory, false)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	defer lock.Close()
	_, err = readHostNativeClaimFile(root, input.request.Epoch+".native_refused_verified.json")
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	current, err := readHostNativeAbortInputAt(root, directory, input.request.SessionID)
	if err != nil || current.completion.fingerprint != input.fingerprint {
		return nil, errors.New("native recovery refusal changed")
	}
	return &current.refusal, nil
}
