package daemon

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

type hostNativeRestoreReceipt struct {
	ThreadID       string `json:"thread_id"`
	RuntimeID      string `json:"runtime_id"`
	RolloutPath    string `json:"rollout_path"`
	CapsuleSHA256  string `json:"capsule_sha256"`
	SettingsSHA256 string `json:"settings_sha256"`
	ProcessID      uint32 `json:"process_id"`
}
type hostNativeJournalRecord struct {
	Version             int                       `json:"v"`
	State               string                    `json:"state"`
	OperationID         string                    `json:"operation_id"`
	ClaimID             string                    `json:"claim_id"`
	CapsuleSHA256       string                    `json:"capsule_sha256"`
	Source              nativeRotationSource      `json:"source"`
	DestinationThreadID *string                   `json:"destination_thread_id"`
	SettingsSHA256      *string                   `json:"settings_sha256"`
	Restored            *hostNativeRestoreReceipt `json:"restored"`
}
type hostNativeJournalEvidence struct {
	records     map[string]string
	fingerprint string
	directory   os.FileInfo
}

func expectedHostNativeJournalRecord(receipt nativeRotationCompletion, state string) hostNativeJournalRecord {
	target, settings := receipt.TargetThreadID, receipt.SettingsSHA256
	result := hostNativeJournalRecord{1, state, receipt.OperationID, receipt.HostClaimID, receipt.CapsuleSHA256,
		receipt.Source, &target, &settings, nil}
	if state == "restored" {
		result.Restored = &hostNativeRestoreReceipt{receipt.TargetThreadID, receipt.TargetRuntimeID,
			receipt.TargetRolloutPath, receipt.CapsuleSHA256, receipt.SettingsSHA256, receipt.ProcessID}
	}
	return result
}

// Resolve only the configured-home ancestors, then traverse descriptor-relative
// without following any link. The journal root and operation must be private,
// owned directories. A link at either journal level is never accepted.
func openHostNativeJournalDirectory(receipt nativeRotationCompletion) (*os.File, error) {
	if !receipt.valid(receipt.OperationID, receipt.HostClaimID) {
		return nil, errors.New("invalid native completion identity")
	}
	return openHostNativeOperationDirectory(receipt.JournalDirectory, receipt.OperationID, receipt.HostClaimID)
}

func openHostNativeOperationDirectory(path, operationID, hostClaimID string) (*os.File, error) {
	if !nativeWirePath(path) || !validHostNativeUUID(operationID) || !validHostNativeUUID(hostClaimID) ||
		operationID == hostClaimID || filepath.Clean(path) != path ||
		filepath.Base(path) != operationID || filepath.Base(filepath.Dir(path)) != "relay-context-rotation" {
		return nil, errors.New("invalid native journal path or identity")
	}
	parent, err := filepath.EvalSymlinks(filepath.Dir(filepath.Dir(path)))
	if err != nil {
		return nil, err
	}
	canonical := filepath.Join(parent, "relay-context-rotation", operationID)
	fd, err := unix.Open("/", unix.O_RDONLY|unix.O_CLOEXEC|unix.O_DIRECTORY, 0)
	if err != nil {
		return nil, err
	}
	parts := strings.Split(strings.TrimPrefix(canonical, "/"), "/")
	for index, name := range parts {
		next, err := unix.Openat(fd, name, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_DIRECTORY|unix.O_NOFOLLOW, 0)
		unix.Close(fd)
		if err != nil {
			return nil, err
		}
		fd = next
		if index >= len(parts)-2 {
			var stat unix.Stat_t
			if unix.Fstat(fd, &stat) != nil || stat.Uid != uint32(os.Getuid()) || stat.Mode&0o077 != 0 {
				unix.Close(fd)
				return nil, errors.New("native journal directory is not private")
			}
		}
	}
	return os.NewFile(uintptr(fd), canonical), nil
}

func readHostNativeRestorationJournal(receipt nativeRotationCompletion) (hostNativeJournalEvidence, error) {
	var empty hostNativeJournalEvidence
	directory, err := openHostNativeJournalDirectory(receipt)
	if err != nil {
		return empty, err
	}
	defer directory.Close()
	names, err := directory.Readdirnames(16)
	if err != nil && !errors.Is(err, io.EOF) {
		return empty, err
	}
	expected := map[string]bool{"intent.json": true, "sealed.json": true, "closed.json": true, "restored.json": true}
	if len(names) != len(expected) {
		return empty, errors.New("native journal is incomplete or conflicting")
	}
	for _, name := range names {
		if !expected[name] {
			return empty, errors.New("native journal has conflicting evidence")
		}
	}
	proof := hostNativeJournalEvidence{records: make(map[string]string)}
	proof.directory, err = directory.Stat()
	if err != nil {
		return empty, err
	}
	for _, state := range []string{"intent", "sealed", "closed", "restored"} {
		raw, err := readHostNativeClaimFile(directory, state+".json")
		var record hostNativeJournalRecord
		if err != nil || decodeHostNativeRecord(raw, &record) != nil {
			return empty, errors.New("native journal record is unavailable or malformed")
		}
		want := expectedHostNativeJournalRecord(receipt, state)
		if record.Version != want.Version || record.State != want.State || record.OperationID != want.OperationID ||
			record.ClaimID != want.ClaimID || record.CapsuleSHA256 != want.CapsuleSHA256 || record.Source != want.Source ||
			record.DestinationThreadID == nil || *record.DestinationThreadID != *want.DestinationThreadID ||
			record.SettingsSHA256 == nil || *record.SettingsSHA256 != *want.SettingsSHA256 ||
			(record.Restored == nil) != (want.Restored == nil) || (record.Restored != nil && *record.Restored != *want.Restored) {
			return empty, errors.New("native journal receipt binding changed")
		}
		proof.records[state] = hostRotationCapsuleHash(raw)
	}
	after, err := directory.Stat()
	if err != nil || !os.SameFile(proof.directory, after) || proof.directory.Mode() != after.Mode() ||
		proof.directory.Size() != after.Size() || !proof.directory.ModTime().Equal(after.ModTime()) {
		return empty, errors.New("native journal directory changed")
	}
	current, err := openHostNativeJournalDirectory(receipt)
	if err != nil {
		return empty, err
	}
	defer current.Close()
	identity, err := current.Stat()
	if err != nil || !os.SameFile(proof.directory, identity) {
		return empty, errors.New("native journal path changed")
	}
	encoded, _ := json.Marshal(proof.records)
	proof.fingerprint = hostRotationCapsuleHash(encoded)
	return proof, nil
}
