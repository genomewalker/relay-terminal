package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// Recovery observations carry no live bridge, frontend or native capability.
// All observations leave the durable active fence intact.
type hostNativeClaimRecovery struct {
	State         string
	SessionID     string
	OperationID   string
	RequestSHA256 string
	Receipt       *hostNativeClaimReceipt
}

type hostNativeClaimSnapshot struct {
	request       hostNativeClaimRequest
	journal       *hostNativeClaimJournal
	phases        map[string]hostNativeClaimPhase
	commitPending bool
	fingerprint   string
}

type hostNativeStatusRequest struct {
	Version   int    `json:"v"`
	SessionID string `json:"session_id"`
	Epoch     string `json:"epoch"`
}

// Compare decoded JSON trees to the typed encoding as well as disallowing
// unknown fields. This rejects omitted zero fields, null scalars, case aliases
// and unexpected nested fields, without depending on key order or whitespace.
func decodeHostNativeRecord(raw []byte, target any) error {
	if len(raw) == 0 || len(raw) > hostNativeClaimRecordLimit || !rotationSourceJSONUnambiguous(raw) {
		return errors.New("invalid native recovery record")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	encoded, err := json.Marshal(target)
	if err != nil {
		return err
	}
	canonical := func(data []byte) ([]byte, error) {
		var value any
		d := json.NewDecoder(bytes.NewReader(data))
		d.UseNumber()
		if err := d.Decode(&value); err != nil {
			return nil, err
		}
		return json.Marshal(value)
	}
	got, err := canonical(raw)
	if err != nil {
		return err
	}
	want, err := canonical(encoded)
	if err != nil || !bytes.Equal(got, want) {
		return errors.New("incomplete native recovery record")
	}
	return nil
}

func validateHostNativeStoredRequest(r hostNativeClaimRequest) error {
	b := r.Source
	if r.Version != 1 || !validHostNativeUUID(r.SessionID) || !validHostNativeUUID(r.Epoch) ||
		!validHostNativeUUID(r.HostClaimID) || r.Epoch == r.HostClaimID ||
		r.Claimant != "relay:"+r.Epoch || r.SessionID != b.Enrollment.SessionID ||
		b.Enrollment.Client != "codex" || b.SourceChunks < 1 || b.SourceChunks > rotationSourceMaxChunks ||
		r.LeaseMS < 1 || r.LeaseMS > 5000 || r.LeaseMS > int64(r.Reservation.Native.ExpiresInMS) {
		return errors.New("invalid stored native request identity")
	}
	// This reconstructs only descriptive fields, never transcript evidence or
	// an enrollment capability. The source validator checks their bounds.
	source := hostRotationSource{
		Enrollment: b.Enrollment,
		Boundary: hostRotationSourceBoundary{TurnID: b.TurnID, TurnSeq: b.TurnSeq,
			TranscriptMtimeMS: b.TranscriptMtimeMS, TranscriptBytes: b.TranscriptBytes},
		BindingRevision: b.BindingRevision, TranscriptSHA256: b.SourceSHA256, EvidenceSHA256: b.EvidenceSHA256,
		Chunks: make([]string, b.SourceChunks),
	}
	binding, err := hostRotationCapsuleSource(source)
	if err != nil || binding != b || b.Enrollment.AgentPID > 2147483647 || b.Enrollment.WorkerPID > 2147483647 ||
		!hostRotationCapsuleDigest(r.Capsule.ArtifactID) || !hostRotationCapsuleDigest(r.Capsule.SHA256) ||
		r.Capsule.Bytes < 1 || r.Capsule.Bytes > 16384 {
		return errors.New("invalid stored native source or capsule")
	}
	n, f := r.Reservation.Native, r.Reservation.Frontend
	if !validNativeRotationReceipt(nativeRotationCommand{ThreadID: r.SessionID, TurnID: b.TurnID},
		nativeRotationReply{Native: &n, Frontend: &f}) ||
		!validHostNativeUUID(n.ReservationID) || !validHostNativeUUID(n.RuntimeID) ||
		!validHostNativeUUID(f.RuntimeID) || !utf8.ValidString(n.RolloutPath) || strings.ContainsRune(n.RolloutPath, '\x00') {
		return errors.New("invalid stored native reservation")
	}
	for _, value := range []string{n.AdmissionGeneration, f.Generation} {
		number, err := strconv.ParseUint(value, 10, 64)
		if err != nil || strconv.FormatUint(number, 10) != value {
			return errors.New("invalid stored reservation generation")
		}
	}
	return nil
}

func readHostNativeClaimSnapshot(workerDirectory, sessionID string) (*hostNativeClaimSnapshot, error) {
	if !validHostNativeUUID(sessionID) {
		return nil, errors.New("invalid recovery session")
	}
	root, lock, err := lockHostNativeClaimRoot(workerDirectory, false)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	defer lock.Close()
	activeRaw, err := readHostNativeClaimFile(root, sessionID+".active.json")
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var active hostNativeClaimActive
	if decodeHostNativeRecord(activeRaw, &active) != nil || active.Version != 1 ||
		!validHostNativeUUID(active.OperationID) || !hostRotationCapsuleDigest(active.RequestSHA256) {
		return nil, errors.New("invalid active native claim")
	}
	requestRaw, err := readHostNativeClaimFile(root, active.OperationID+".request.json")
	if err != nil {
		return nil, err
	}
	var request hostNativeClaimRequest
	if decodeHostNativeRecord(requestRaw, &request) != nil ||
		hostRotationCapsuleHash(requestRaw) != active.RequestSHA256 ||
		request.SessionID != sessionID || request.Epoch != active.OperationID ||
		validateHostNativeStoredRequest(request) != nil {
		return nil, errors.New("native recovery request mismatch")
	}
	snapshot := &hostNativeClaimSnapshot{request: request,
		journal: &hostNativeClaimJournal{workerDirectory, sessionID, active.OperationID, active.RequestSHA256},
		phases:  make(map[string]hostNativeClaimPhase)}
	var evidence bytes.Buffer
	evidence.Write(activeRaw)
	evidence.WriteByte('\n')
	evidence.Write(requestRaw)
	for _, state := range []string{"claim_uncertain", "claim_received", "release_requested", "released", "commit_requested"} {
		evidence.WriteString("\n" + state + ":")
		raw, err := readHostNativeClaimFile(root, active.OperationID+"."+state+".json")
		if errors.Is(err, os.ErrNotExist) {
			evidence.WriteString("absent")
			continue
		}
		if err != nil {
			return nil, err
		}
		evidence.Write(raw)
		if state == "commit_requested" {
			// The future commit owner defines its schema. Presence blocks
			// reservation cleanup even if the rest of recovery is valid.
			snapshot.commitPending = true
			continue
		}
		var phase hostNativeClaimPhase
		if decodeHostNativeRecord(raw, &phase) != nil || phase.Version != 1 ||
			phase.State != state || phase.RequestSHA256 != active.RequestSHA256 {
			return nil, errors.New("native recovery phase mismatch")
		}
		if state == "claim_uncertain" {
			if phase.Claim != nil {
				return nil, errors.New("unexpected uncertain claim receipt")
			}
		} else {
			if phase.Claim == nil {
				return nil, errors.New("native recovery phase lacks receipt")
			}
			encoded, _ := json.Marshal(phase.Claim)
			if _, err := decodeHostNativeClaimIdentity(encoded, request, state == "released"); err != nil {
				return nil, err
			}
		}
		snapshot.phases[state] = phase
	}
	received, hasReceived := snapshot.phases["claim_received"]
	release, hasRelease := snapshot.phases["release_requested"]
	released, hasReleased := snapshot.phases["released"]
	if hasRelease && (!hasReceived || *release.Claim != *received.Claim) {
		return nil, errors.New("release request lacks matching acquisition")
	}
	if hasReleased {
		matching := *released.Claim
		matching.Closed = false
		matching.ReleaseSeq = 0
		if !hasRelease || matching != *release.Claim {
			return nil, errors.New("released phase lacks matching release intent")
		}
	}
	if err := root.Sync(); err != nil {
		return nil, err
	}
	snapshot.fingerprint = hostRotationCapsuleHash(evidence.Bytes())
	return snapshot, nil
}

func inspectHostNativeClaim(ctx context.Context, workerDirectory, sessionID string,
	ledger func(context.Context, string, any) (json.RawMessage, error)) (hostNativeClaimRecovery, error) {
	result := hostNativeClaimRecovery{State: "unresolved", SessionID: sessionID}
	if ctx.Err() != nil {
		return result, ctx.Err()
	}
	if ledger == nil {
		return result, errors.New("native recovery ledger unavailable")
	}
	before, err := readHostNativeClaimSnapshot(workerDirectory, sessionID)
	if err != nil {
		return result, err
	}
	if before == nil {
		result.State = "no_active_claim"
		return result, nil
	}
	result.OperationID, result.RequestSHA256 = before.request.Epoch, before.journal.requestSHA256
	if before.commitPending {
		result.State = "commit_pending"
		return result, nil
	}
	raw, err := ledger(ctx, "rotation_status", hostNativeStatusRequest{1, sessionID, before.request.Epoch})
	if err != nil {
		return result, err
	}
	if ctx.Err() != nil {
		return result, ctx.Err()
	}
	result, err = classifyHostNativeClaimStatus(raw, before, time.Now())
	if err != nil {
		return result, err
	}
	// No filesystem lock is held over the RPC. Any concurrent phase change
	// invalidates this observation; the caller may make a fresh status read.
	after, err := readHostNativeClaimSnapshot(workerDirectory, sessionID)
	if err != nil || after == nil || after.fingerprint != before.fingerprint {
		result.State = "unresolved"
		result.Receipt = nil
		return result, errors.New("native recovery journal changed during status")
	}
	if ctx.Err() != nil {
		result.State = "unresolved"
		result.Receipt = nil
		return result, ctx.Err()
	}
	return result, nil
}

func classifyHostNativeClaimStatus(raw []byte, snapshot *hostNativeClaimSnapshot, now time.Time) (hostNativeClaimRecovery, error) {
	r := snapshot.request
	result := hostNativeClaimRecovery{State: "unresolved", SessionID: r.SessionID,
		OperationID: r.Epoch, RequestSHA256: snapshot.journal.requestSHA256}
	fail := func() (hostNativeClaimRecovery, error) { return result, errors.New("native recovery ledger mismatch") }
	var fields map[string]json.RawMessage
	if len(raw) > 262144 || !rotationSourceJSONUnambiguous(raw) || json.Unmarshal(raw, &fields) != nil {
		return fail()
	}
	required := []string{"v", "session_id", "epoch", "client", "cwd", "owner", "signal", "turn_seq",
		"claim", "live", "capsule", "intent", "ack", "lifecycle_performed", "new_session_id", "usage_history"}
	allowed := map[string]bool{"usage": true}
	for _, key := range required {
		if _, ok := fields[key]; !ok {
			return fail()
		}
		allowed[key] = true
	}
	for key := range fields {
		if !allowed[key] {
			return fail()
		}
	}
	var status struct {
		Version            int    `json:"v"`
		SessionID          string `json:"session_id"`
		Epoch              string `json:"epoch"`
		Client             string `json:"client"`
		CWD                string `json:"cwd"`
		Owner              string `json:"owner"`
		TurnSeq            uint64 `json:"turn_seq"`
		Live               bool   `json:"live"`
		LifecyclePerformed bool   `json:"lifecycle_performed"`
	}
	if json.Unmarshal(raw, &status) != nil || status.Version != 1 || status.SessionID != r.SessionID ||
		status.Epoch != r.Epoch || status.Client != "codex" || status.Owner != "relay" ||
		status.CWD != r.Source.Enrollment.CWD || status.TurnSeq < r.Source.TurnSeq ||
		!bytes.Equal(bytes.TrimSpace(fields["live"]), []byte(strconv.FormatBool(status.Live))) ||
		!bytes.Equal(bytes.TrimSpace(fields["lifecycle_performed"]), []byte(strconv.FormatBool(status.LifecyclePerformed))) {
		return fail()
	}
	isNull := func(key string) bool { return bytes.Equal(bytes.TrimSpace(fields[key]), []byte("null")) }
	if !isNull("signal") || !isNull("capsule") {
		return fail()
	}
	if !isNull("intent") || !isNull("ack") || status.LifecyclePerformed || !isNull("new_session_id") {
		result.State = "native_transaction_pending"
		return result, nil
	}
	if isNull("claim") {
		_, received := snapshot.phases["claim_received"]
		_, release := snapshot.phases["release_requested"]
		_, released := snapshot.phases["released"]
		if status.Live || received || release || released {
			return fail()
		}
		// An earlier submitted claim can still be in flight. Absence is not a
		// cancellation barrier and must never remove the active fence.
		result.State = "claim_not_observed"
		return result, nil
	}
	var marker struct {
		Closed *bool `json:"closed"`
	}
	if json.Unmarshal(fields["claim"], &marker) != nil || marker.Closed == nil {
		return fail()
	}
	receipt, err := decodeHostNativeClaimIdentity(fields["claim"], r, *marker.Closed)
	if err != nil {
		return fail()
	}
	if *marker.Closed && status.Live {
		return fail()
	}
	if received, ok := snapshot.phases["claim_received"]; ok {
		matching := receipt
		matching.Closed = false
		matching.ReleaseSeq = 0
		if matching != *received.Claim {
			return fail()
		}
	}
	if released, ok := snapshot.phases["released"]; ok && receipt != *released.Claim {
		return fail()
	}
	if receipt.Closed {
		if _, ok := snapshot.phases["release_requested"]; ok {
			result.State = "release_confirmed"
		} else {
			result.State = "closed_without_release_intent"
		}
	} else if _, ok := snapshot.phases["release_requested"]; ok {
		result.State = "release_unconfirmed"
	} else if receipt.ExpiresAtMS <= now.UnixMilli() {
		result.State = "claim_expired"
	} else {
		if !status.Live {
			return fail()
		}
		result.State = "claim_open"
	}
	result.Receipt = &receipt
	return result, nil
}
