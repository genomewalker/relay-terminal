package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"

	"golang.org/x/sys/unix"
)

// Exact native record shared with the ledger abort contract. It is descriptive
// evidence; the durable handoff and current physical owner are verified separately.
type hostNativeRefusalRecord struct {
	Version       int                  `json:"v"`
	State         string               `json:"state"`
	OperationID   string               `json:"operation_id"`
	ClaimID       string               `json:"claim_id"`
	ReservationID string               `json:"reservation_id"`
	CapsuleSHA256 string               `json:"capsule_sha256"`
	Source        nativeRotationSource `json:"source"`
	ProcessID     uint32               `json:"process_id"`
}
type hostNativeRefusalProof struct {
	Version            int                     `json:"v"`
	State              string                  `json:"state"`
	RequestSHA256      string                  `json:"request_sha256"`
	HostSnapshotSHA256 string                  `json:"host_snapshot_sha256"`
	JournalSHA256      string                  `json:"journal_sha256"`
	NativeRecords      map[string]string       `json:"native_records"`
	JournalDirectory   string                  `json:"journal_directory"`
	Receipt            hostNativeRefusalRecord `json:"receipt"`
}
type hostNativeRefusalJournalEvidence struct {
	hostNativeJournalEvidence
	receipt hostNativeRefusalRecord
}

func validHostNativeRefusal(record hostNativeRefusalRecord, request hostNativeClaimRequest) bool {
	return record.Version == 1 && record.State == "refused" && record.OperationID == request.Epoch &&
		record.ClaimID == request.HostClaimID && record.ReservationID == request.Reservation.Native.ReservationID &&
		record.CapsuleSHA256 == request.Capsule.SHA256 && record.Source.matches(request.Reservation.Native) &&
		record.ProcessID == uint32(request.Source.Enrollment.AgentPID)
}

// Refusal requires the original source binding; the restoration observer's
// allowance for an attached destination must never authorize source abort.
func verifyHostNativeRefusalOwner(e hostRotationEnrollment, receipt hostNativeRefusalRecord) error {
	if e.Client != "codex" || e.AgentPID <= 1 || e.WorkerPID <= 1 || e.AgentStart == 0 || e.WorkerStart == 0 ||
		receipt.ProcessID != uint32(e.AgentPID) || receipt.Source.ThreadID != e.SessionID || !receipt.Source.valid() {
		return errors.New("native refusal process identity changed")
	}
	server := NewServer()
	manifest, err := loadManifest(server.manifestPath(e.PaneID))
	if err != nil || manifest.SessionID != e.PaneID || manifest.WorkerPID != e.WorkerPID ||
		manifest.WorkerStartTime != e.WorkerStart || manifest.NodeBootID != e.NodeBootID || validateWorkerIdentity(manifest) != nil {
		return errors.New("native refusal worker changed")
	}
	start, err := NativeAgentIncarnation(e.PaneID, e.AgentPID, "codex")
	if err != nil || start != e.AgentStart {
		return errors.New("native refusal provider incarnation changed")
	}
	binding, err := ReadNativeAgentBinding(e.PaneID)
	if err != nil || binding.Producer.Provider != "codex" || binding.Producer.ProcessID != e.AgentPID ||
		binding.Producer.ProcessStart != e.AgentStart || binding.SessionID != e.SessionID ||
		binding.TranscriptPath != receipt.Source.RolloutPath {
		return errors.New("native refusal original foreground owner changed")
	}
	return nil
}

func readHostNativeRefusalJournal(path string, request hostNativeClaimRequest) (hostNativeRefusalJournalEvidence, error) {
	var empty hostNativeRefusalJournalEvidence
	directory, err := openHostNativeOperationDirectory(path, request.Epoch, request.HostClaimID)
	if err != nil {
		return empty, err
	}
	defer directory.Close()
	names, err := directory.Readdirnames(4)
	if err != nil && !errors.Is(err, io.EOF) {
		return empty, err
	}
	allowed := map[string]bool{"refused.json": false, "intent.json": false, "aborted.json": false}
	for _, name := range names {
		if _, ok := allowed[name]; !ok {
			return empty, errors.New("native refusal conflicts with journal state")
		}
		allowed[name] = true
	}
	if !allowed["refused.json"] || (allowed["aborted.json"] && !allowed["intent.json"]) {
		return empty, errors.New("native refusal journal is incomplete")
	}
	evidence := hostNativeRefusalJournalEvidence{hostNativeJournalEvidence: hostNativeJournalEvidence{records: make(map[string]string)}}
	evidence.directory, err = directory.Stat()
	if err != nil {
		return empty, err
	}
	raw, err := readHostNativeClaimFile(directory, "refused.json")
	if err != nil || decodeHostNativeRecord(raw, &evidence.receipt) != nil ||
		!hostNativeRegistrationExactShape(raw, evidence.receipt) || !validHostNativeRefusal(evidence.receipt, request) {
		return empty, errors.New("native refusal differs from durable handoff")
	}
	evidence.records["refused"] = hostRotationCapsuleHash(raw)
	var intent []byte
	for _, state := range []string{"intent", "aborted"} {
		if !allowed[state+".json"] {
			continue
		}
		raw, err := readHostNativeClaimFile(directory, state+".json")
		var record hostNativeJournalRecord
		if err != nil || decodeHostNativeRecord(raw, &record) != nil || !hostNativeRegistrationExactShape(raw, record) ||
			record.Version != 1 || record.State != state || record.OperationID != request.Epoch ||
			record.ClaimID != request.HostClaimID || record.CapsuleSHA256 != request.Capsule.SHA256 ||
			!record.Source.matches(request.Reservation.Native) || record.Restored != nil {
			return empty, errors.New("native refusal preseal identity changed")
		}
		if (record.DestinationThreadID == nil) != (record.SettingsSHA256 == nil) ||
			(record.DestinationThreadID != nil && (!validHostNativeUUID(*record.DestinationThreadID) ||
				*record.DestinationThreadID == record.Source.ThreadID || !nativeWireHash(*record.SettingsSHA256))) {
			return empty, errors.New("native refusal preseal settings changed")
		}
		record.State = "intent"
		normalized, err := json.Marshal(record)
		if err != nil {
			return empty, err
		}
		if intent != nil && !bytes.Equal(intent, normalized) {
			return empty, errors.New("native aborted record differs from intent")
		}
		intent = normalized
		evidence.records[state] = hostRotationCapsuleHash(raw)
	}
	after, err := directory.Stat()
	if err != nil || !os.SameFile(evidence.directory, after) || evidence.directory.Mode() != after.Mode() ||
		evidence.directory.Size() != after.Size() || !evidence.directory.ModTime().Equal(after.ModTime()) {
		return empty, errors.New("native refusal directory changed")
	}
	current, err := openHostNativeOperationDirectory(path, request.Epoch, request.HostClaimID)
	if err != nil {
		return empty, err
	}
	defer current.Close()
	identity, err := current.Stat()
	if err != nil || !os.SameFile(evidence.directory, identity) {
		return empty, errors.New("native refusal path changed")
	}
	encoded, _ := json.Marshal(evidence.records)
	evidence.fingerprint = hostRotationCapsuleHash(encoded)
	return evidence, nil
}

func checkHostNativeRefusalConflictsAt(root *os.File, operationID string) error {
	for _, phase := range []string{"native_restored_verified", "registration_requested", "registration_received",
		"ledger_ack_requested", "ledger_ack_received", "native_ack_requested", "native_retired",
		"host_finalization_requested", "host_finalized"} {
		var stat unix.Stat_t
		if err := unix.Fstatat(int(root.Fd()), operationID+"."+phase+".json", &stat, unix.AT_SYMLINK_NOFOLLOW); !errors.Is(err, unix.ENOENT) {
			return errors.New("native refusal conflicts with restoration progress")
		}
	}
	return nil
}

func verifyAndRecordHostNativeRefusal(ctx context.Context, workerDirectory, sessionID, journalPath string,
	verifyOwner func(hostRotationEnrollment, hostNativeRefusalRecord) error) (*hostNativeRefusalProof, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if verifyOwner == nil {
		return nil, errors.New("native refusal owner verifier unavailable")
	}
	input, err := readHostNativeCompletionInput(workerDirectory, sessionID)
	if err != nil {
		return nil, err
	}
	journal, err := readHostNativeRefusalJournal(journalPath, input.request)
	if err != nil {
		return nil, err
	}
	if err := verifyOwner(input.request.Source.Enrollment, journal.receipt); err != nil {
		return nil, err
	}
	after, err := readHostNativeRefusalJournal(journalPath, input.request)
	if err != nil || after.receipt != journal.receipt || after.fingerprint != journal.fingerprint ||
		!os.SameFile(after.directory, journal.directory) {
		return nil, errors.New("native refusal journal changed during verification")
	}
	if err := verifyOwner(input.request.Source.Enrollment, journal.receipt); err != nil {
		return nil, err
	}
	last, err := readHostNativeRefusalJournal(journalPath, input.request)
	if err != nil || last.fingerprint != journal.fingerprint || !os.SameFile(last.directory, journal.directory) {
		return nil, errors.New("native refusal journal changed after owner verification")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	root, lock, err := lockHostNativeClaimRoot(workerDirectory, false)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	defer lock.Close()
	current, err := readHostNativeCompletionInputAt(root, workerDirectory, sessionID)
	if err != nil || current.fingerprint != input.fingerprint {
		return nil, errors.New("native refusal host intent changed during verification")
	}
	if err := checkHostNativeRefusalConflictsAt(root, input.request.Epoch); err != nil {
		return nil, err
	}
	proof := &hostNativeRefusalProof{1, "native_refused_verified", input.journal.requestSHA256, input.fingerprint,
		journal.fingerprint, journal.records, journalPath, journal.receipt}
	raw, err := json.Marshal(proof)
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := writeHostNativeClaimFile(root, input.request.Epoch+".native_refused_verified.json", raw, true); err != nil {
		return nil, err
	}
	// Keep the active source fence. Ledger abort, native retirement and ordered
	// host cleanup require their own durable evidence.
	return proof, nil
}
