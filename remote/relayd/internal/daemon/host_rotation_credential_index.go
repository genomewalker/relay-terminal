package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"
)

// This index contains references and account identities only. Write and sync
// intent before touching the vault so an interrupted sheet or RPC cannot orphan
// a key. Deleted references remain tombstones; a save is never replayed.
type hostRotationCredentialRecord struct {
	Reference string `json:"reference"`
	AccountID string `json:"account_id"`
	State     string `json:"state"`
}
type hostRotationCredentialIndex struct {
	Version int                            `json:"v"`
	Entries []hostRotationCredentialRecord `json:"entries"`
}
type hostRotationCredentialReceipt struct {
	Version   int    `json:"v"`
	Status    string `json:"status"`
	Reference string `json:"reference"`
	Storage   string `json:"storage"`
}

func validCredentialRecord(r hostRotationCredentialRecord) bool {
	if !validPromptEditorID(r.Reference) || !validPromptEditorID(r.AccountID) {
		return false
	}
	switch r.State {
	case "pending", "saved", "deleting", "missing", "missing_or_locked", "deleted":
		return true
	}
	return false
}
func credentialRecordActive(r hostRotationCredentialRecord) bool {
	return r.State != "deleted" && r.State != "missing"
}
func hostRotationCredentialIndexService(ctx context.Context, workerDirectory, operation, reference, accountID, secret string) (json.RawMessage, error) {
	if operation != "list" && operation != "save" && operation != "status" && operation != "delete" {
		return nil, errors.New("invalid credential operation")
	}
	if operation == "list" {
		if reference != "" || accountID != "" || secret != "" {
			return nil, errors.New("invalid credential request")
		}
	} else if !validPromptEditorID(reference) || (operation == "save") != (secret != "") ||
		(operation == "save" && !validPromptEditorID(accountID)) ||
		(operation != "save" && accountID != "") {
		return nil, errors.New("invalid credential request")
	}
	if operation == "save" {
		if len(secret) < 16 || len(secret) > 512 {
			return nil, errors.New("invalid API credential")
		}
		for _, c := range []byte(secret) {
			if c <= 32 || c >= 127 {
				return nil, errors.New("invalid API credential")
			}
		}
	}
	if err := privateBindingObject(workerDirectory, true); err != nil {
		return nil, errors.New("credential reference directory unavailable")
	}
	root := filepath.Join(workerDirectory, "rotation-credentials")
	if err := os.Mkdir(root, 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return nil, errors.New("credential reference directory unavailable")
	}
	if err := privateBindingObject(root, true); err != nil {
		return nil, errors.New("credential reference directory is not private")
	}
	// A nonblocking host lock serializes vault writes and status reconciliation
	// across every pane worker without holding a terminal input mutex.
	lockPath := filepath.Join(root, "index.lock")
	fd, err := syscall.Open(lockPath, syscall.O_RDWR|syscall.O_CREAT|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0600)
	if err != nil {
		return nil, errors.New("credential reference lock unavailable")
	}
	lock := os.NewFile(uintptr(fd), lockPath)
	defer lock.Close()
	if err := privateBindingObject(lockPath, false); err != nil {
		return nil, errors.New("credential reference lock is not private")
	}
	if err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return nil, errors.New("another credential operation is still running; check stored keys again")
	}
	defer syscall.Flock(fd, syscall.LOCK_UN)
	indexPath := filepath.Join(root, "index.json")
	index := hostRotationCredentialIndex{Version: 1, Entries: []hostRotationCredentialRecord{}}
	if _, err := os.Lstat(indexPath); err == nil {
		if err := privateBindingObject(indexPath, false); err != nil {
			return nil, errors.New("credential reference index is not private")
		}
		f, err := os.Open(indexPath)
		if err != nil {
			return nil, errors.New("credential reference index unavailable")
		}
		raw, readErr := io.ReadAll(io.LimitReader(f, 1<<20+1))
		f.Close()
		if readErr != nil || len(raw) > 1<<20 || !rotationSourceJSONUnambiguous(raw) {
			return nil, errors.New("credential reference index unavailable")
		}
		decoder := json.NewDecoder(bytes.NewReader(raw))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&index) != nil || index.Version != 1 || len(index.Entries) > 4096 {
			return nil, errors.New("credential reference index unavailable")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, errors.New("credential reference index unavailable")
	}
	seen := map[string]bool{}
	active, position := 0, -1
	for i, record := range index.Entries {
		if !validCredentialRecord(record) || seen[record.Reference] {
			return nil, errors.New("credential reference index unavailable")
		}
		seen[record.Reference] = true
		if credentialRecordActive(record) {
			active++
		}
		if record.Reference == reference {
			position = i
		}
	}
	if active > 64 {
		return nil, errors.New("credential reference index unavailable")
	}
	if operation == "list" {
		entries := []hostRotationCredentialRecord{}
		for _, record := range index.Entries {
			if credentialRecordActive(record) {
				entries = append(entries, record)
			}
		}
		raw, _ := json.Marshal(map[string]any{"v": 1, "status": "ready", "entries": entries})
		return raw, nil
	}
	if operation == "save" {
		if position >= 0 {
			return nil, errors.New("credential save was already recorded; check its status instead of saving again")
		}
		if active >= 64 || len(index.Entries) >= 4096 {
			return nil, errors.New("credential reference limit reached; remove unused stored keys")
		}
		index.Entries = append(index.Entries, hostRotationCredentialRecord{reference, accountID, "pending"})
		position = len(index.Entries) - 1
		if err := saveCredentialIndex(root, indexPath, index); err != nil {
			return nil, errors.New("credential reference could not be saved; no vault operation was started")
		}
	} else {
		if position < 0 {
			return nil, errors.New("credential reference is not registered on this host")
		}
		if operation == "delete" {
			index.Entries[position].State = "deleting"
			if err := saveCredentialIndex(root, indexPath, index); err != nil {
				return nil, errors.New("credential removal could not be recorded; no vault operation was started")
			}
		}
	}
	raw, err := hostRotationCredentialService(ctx, operation, reference, secret)
	if err != nil {
		return nil, err
	}
	var receipt hostRotationCredentialReceipt
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&receipt) != nil || receipt.Version != 1 || receipt.Reference != reference ||
		(receipt.Storage != "macos_keychain" && receipt.Storage != "linux_secret_service") ||
		(operation == "save" && receipt.Status != "saved") ||
		(operation == "delete" && receipt.Status != "deleted") ||
		(operation == "status" && receipt.Status != "saved" && receipt.Status != "missing" && receipt.Status != "missing_or_locked") {
		return nil, errors.New("credential outcome unconfirmed; check its registered reference")
	}
	index.Entries[position].State = receipt.Status
	if err := saveCredentialIndex(root, indexPath, index); err != nil {
		return nil, errors.New("credential outcome could not be recorded; check its registered reference")
	}
	return raw, nil
}

func saveCredentialIndex(root, path string, index hostRotationCredentialIndex) error {
	raw, err := json.Marshal(index)
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(root, ".index-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(temporary.Name())
	defer temporary.Close()
	if err := temporary.Chmod(0600); err != nil {
		return err
	}
	if _, err := temporary.Write(raw); err != nil {
		return err
	}
	if err := temporary.Sync(); err != nil {
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporary.Name(), path); err != nil {
		return err
	}
	directory, err := os.Open(root)
	if err != nil {
		return err
	}
	defer directory.Close()
	if err := directory.Sync(); err != nil {
		return err
	}
	// Sync the parent too when the registry directory has just been created.
	parent, err := os.Open(filepath.Dir(root))
	if err != nil {
		return err
	}
	defer parent.Close()
	return parent.Sync()
}
