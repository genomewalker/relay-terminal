package daemon

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"path/filepath"
	"strconv"
	"unicode/utf8"
)

// Native core receipts use numeric generations and contain no app-server token.
// These are observations only; journal/process/target verification and ledger ACK
// must precede treating a restored observation as a completed host transaction.
type nativeRotationSource struct {
	RuntimeID           string `json:"runtime_id"`
	ThreadID            string `json:"thread_id"`
	TurnID              string `json:"turn_id"`
	RolloutPath         string `json:"rollout_path"`
	AdmissionGeneration uint64 `json:"admission_generation"`
}
type nativeRotationCompletion struct {
	OperationID       string               `json:"operation_id"`
	HostClaimID       string               `json:"host_claim_id"`
	Source            nativeRotationSource `json:"source"`
	TargetThreadID    string               `json:"target_thread_id"`
	TargetRuntimeID   string               `json:"target_runtime_id"`
	TargetRolloutPath string               `json:"target_rollout_path"`
	CapsuleSHA256     string               `json:"capsule_sha256"`
	SettingsSHA256    string               `json:"settings_sha256"`
	ProcessID         uint32               `json:"process_id"`
	JournalDirectory  string               `json:"journal_directory"`
}

func nativeWireHash(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, c := range value {
		if !(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
func nativeWirePath(value string) bool {
	return filepath.IsAbs(value) && len(value) <= 4096 && bytes.IndexByte([]byte(value), 0) < 0
}
func (source nativeRotationSource) valid() bool {
	return validHostNativeUUID(source.RuntimeID) && validHostNativeUUID(source.ThreadID) &&
		len(source.TurnID) > 0 && len(source.TurnID) <= 256 && bytes.IndexByte([]byte(source.TurnID), 0) < 0 &&
		nativeWirePath(source.RolloutPath)
}
func (source nativeRotationSource) matches(receipt nativeRotationReceipt) bool {
	return source.valid() && source.RuntimeID == receipt.RuntimeID && source.ThreadID == receipt.ThreadID &&
		source.TurnID == receipt.TurnID && source.RolloutPath == receipt.RolloutPath &&
		strconv.FormatUint(source.AdmissionGeneration, 10) == receipt.AdmissionGeneration
}
func (receipt nativeRotationCompletion) valid(operationID, hostClaimID string) bool {
	return receipt.OperationID == operationID && receipt.HostClaimID == hostClaimID && receipt.Source.valid() &&
		validHostNativeUUID(receipt.TargetThreadID) && receipt.TargetThreadID != receipt.Source.ThreadID &&
		validHostNativeUUID(receipt.TargetRuntimeID) && receipt.TargetRuntimeID != receipt.Source.RuntimeID &&
		nativeWirePath(receipt.TargetRolloutPath) && receipt.TargetRolloutPath != receipt.Source.RolloutPath &&
		nativeWirePath(receipt.JournalDirectory) && receipt.ProcessID > 0 &&
		nativeWireHash(receipt.CapsuleSHA256) && nativeWireHash(receipt.SettingsSHA256)
}

func validateNativeRotationReply(command nativeRotationCommand, reply nativeRotationReply) error {
	invalid := errors.New("native rotation response does not match request")
	if !utf8.ValidString(reply.Reason) || len([]rune(reply.Reason)) > 512 ||
		(reply.JournalDirectory != "" && reply.State != "source_retained") {
		return invalid
	}
	transaction := command.Operation == "commit" || command.Operation == "reconcile" || command.Operation == "acknowledge"
	if !transaction {
		if reply.OperationID != "" || reply.HostClaimID != "" || reply.Completion != nil || reply.Source != nil || reply.JournalDirectory != "" {
			return invalid
		}
		if reply.State == "prepared" {
			if command.Operation != "prepare" || reply.ReservationID != "" {
				return invalid
			}
			return nil
		}
		if reply.Native != nil || reply.Frontend != nil || reply.CommitSupported != nil || reply.ReservationID != "" {
			return invalid
		}
		if reply.State == "refused" || (reply.State == "released" && command.Operation == "release") {
			return nil
		}
		return invalid
	}
	operationID, hostClaimID := command.OperationID, command.HostClaimID
	if command.Operation == "commit" {
		if command.Commit == nil {
			return invalid
		}
		operationID, hostClaimID = command.Commit.OperationID, command.Commit.HostClaimID
	}
	if !validHostNativeUUID(operationID) || !validHostNativeUUID(hostClaimID) || operationID == hostClaimID ||
		reply.OperationID != operationID || reply.HostClaimID != hostClaimID ||
		reply.Native != nil || reply.Frontend != nil || reply.CommitSupported != nil || reply.ReservationID != "" {
		return invalid
	}
	switch reply.State {
	case "pending":
		if reply.Completion != nil || reply.Source != nil {
			return invalid
		}
	case "acknowledged":
		if command.Operation != "acknowledge" || reply.Completion != nil || reply.Source != nil {
			return invalid
		}
	case "restored":
		if command.Operation == "acknowledge" || reply.Completion == nil || reply.Source != nil ||
			!reply.Completion.valid(operationID, hostClaimID) {
			return invalid
		}
	case "source_retained":
		if command.Operation == "acknowledge" || reply.Source == nil || reply.Completion != nil || !reply.Source.valid() ||
			(reply.JournalDirectory != "" && (!nativeWirePath(reply.JournalDirectory) || filepath.Clean(reply.JournalDirectory) != reply.JournalDirectory ||
				filepath.Base(reply.JournalDirectory) != operationID || filepath.Base(filepath.Dir(reply.JournalDirectory)) != "relay-context-rotation")) {
			return invalid
		}
	default:
		return invalid
	}
	return nil
}

func nativeCommitMatchesLease(command nativeRotationCommand, lease *hostNativeRotationLease) bool {
	e := command.Commit
	if e == nil || e.Version != 1 || e.ThreadID != lease.native.ThreadID || e.TurnID != lease.native.TurnID ||
		command.ThreadID != e.ThreadID || command.ReservationID != lease.native.ReservationID ||
		command.TurnID != "" || command.OperationID != "" || command.HostClaimID != "" ||
		!validHostNativeUUID(e.OperationID) || !validHostNativeUUID(e.HostClaimID) || e.OperationID == e.HostClaimID ||
		e.Reservation.Native != lease.native || e.Reservation.Frontend != lease.frontend ||
		!nativeWireHash(e.CapsuleSHA256) || len(e.CapsuleBase64) > base64.StdEncoding.EncodedLen(16384) {
		return false
	}
	i := e.Intent
	if i.Version != 1 || i.Mode != "native_v1" || i.State != "commit_requested" ||
		i.SessionID != e.ThreadID || i.Epoch != e.OperationID || i.OperationID != e.OperationID ||
		i.HostClaimID != e.HostClaimID || i.IntentID != e.OperationID || i.Token == 0 || i.Seq == 0 ||
		len(i.ClaimID) == 0 || len(i.ClaimID) > 256 || bytes.IndexByte([]byte(i.ClaimID), 0) >= 0 ||
		!nativeWireHash(i.RequestSHA256) {
		return false
	}
	capsule, err := base64.StdEncoding.Strict().DecodeString(e.CapsuleBase64)
	return err == nil && base64.StdEncoding.EncodeToString(capsule) == e.CapsuleBase64 && len(capsule) <= 16384 &&
		utf8.Valid(capsule) && bytes.IndexByte(capsule, 0) < 0 && len(bytes.TrimSpace(capsule)) > 0 &&
		hostRotationCapsuleHash(capsule) == e.CapsuleSHA256
}

// This is the production callback: the durable marker and all admission checks
// precede the only path that hands the original lease to the private pipe.
func (claim *hostNativeRotationClaim) submitNativeCommit(ctx context.Context) (nativeRotationReply, error) {
	var observed nativeRotationReply
	err := claim.handoffNativeCommit(ctx, func(ctx context.Context, lease *hostNativeRotationLease, envelope hostNativeCommitEnvelope) error {
		var err error
		observed, err = lease.bridge.callOwned(ctx, nativeRotationCommand{Operation: "commit",
			ThreadID: envelope.ThreadID, ReservationID: lease.native.ReservationID, Commit: &envelope}, lease)
		if err != nil {
			return err
		}
		if observed.Completion != nil && (!observed.Completion.Source.matches(lease.native) ||
			observed.Completion.CapsuleSHA256 != envelope.CapsuleSHA256 ||
			int(observed.Completion.ProcessID) != lease.bridge.providerPID) {
			return errors.New("native completion source, process or capsule changed")
		}
		if observed.Source != nil && !observed.Source.matches(lease.native) {
			return errors.New("native retained source changed")
		}
		return nil
	})
	if err != nil {
		return nativeRotationReply{}, err
	}
	return observed, nil
}

// A new authenticated pipe may observe an existing identity after disconnection.
// The caller must verify observations against its durable claim and native journal.
func (bridge *hostNativeRotationBridge) observeNativeCommit(ctx context.Context, threadID, operationID, hostClaimID string) (nativeRotationReply, error) {
	if !validHostNativeUUID(threadID) || !validHostNativeUUID(operationID) ||
		!validHostNativeUUID(hostClaimID) || operationID == hostClaimID {
		return nativeRotationReply{}, errors.New("invalid native reconciliation identity")
	}
	return bridge.call(ctx, nativeRotationCommand{Operation: "reconcile", ThreadID: threadID,
		OperationID: operationID, HostClaimID: hostClaimID})
}
