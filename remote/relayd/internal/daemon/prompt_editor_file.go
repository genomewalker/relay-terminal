package daemon

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"syscall"
)

type promptEditorFile struct {
	file     *os.File
	path     string
	identity os.FileInfo
	original []byte
}

func openPromptEditorFile(path string) (*promptEditorFile, error) {
	return openPromptEditorFileForOwner(path, nil)
}

func openPromptEditorFileForOwner(path string, verifyOwner func() error) (*promptEditorFile, error) {
	fd, err := syscall.Open(path, syscall.O_RDWR|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), path)
	if file == nil {
		_ = syscall.Close(fd)
		return nil, errors.New("prompt editor file unavailable")
	}
	fail := func(err error) (*promptEditorFile, error) { file.Close(); return nil, err }
	info, err := file.Stat()
	if err != nil {
		return fail(err)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(stat.Uid) != os.Getuid() || !info.Mode().IsRegular() || info.Size() > promptEditorDraftLimit {
		return fail(errors.New("prompt editor file is not a private regular file"))
	}
	if info.Mode().Perm()&0o077 != 0 {
		if verifyOwner == nil {
			return fail(errors.New("prompt editor file is not a private regular file"))
		}
		if err := verifyOwner(); err != nil {
			return fail(err)
		}
		if err := file.Chmod(0o600); err != nil {
			return fail(err)
		}
		info, err = file.Stat()
		if err != nil {
			return fail(err)
		}
	}
	data, err := io.ReadAll(io.LimitReader(file, promptEditorDraftLimit+1))
	if err != nil {
		return fail(err)
	}
	if !validPromptEditorText(data) {
		return fail(errors.New("prompt editor file is invalid or too large"))
	}
	return &promptEditorFile{file: file, path: path, identity: info, original: data}, nil
}

func (capture *promptEditorFile) unchanged() error {
	pathInfo, err := os.Lstat(capture.path)
	if err != nil || !os.SameFile(capture.identity, pathInfo) {
		return errors.New("prompt editor file was replaced")
	}
	if _, err := capture.file.Seek(0, io.SeekStart); err != nil {
		return err
	}
	data, err := io.ReadAll(io.LimitReader(capture.file, promptEditorDraftLimit+1))
	if err != nil {
		return err
	}
	if !bytes.Equal(data, capture.original) {
		return errors.New("prompt editor file contents changed")
	}
	return nil
}

func writePromptEditorBytes(file *os.File, text []byte) error {
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return err
	}
	if _, err := io.Copy(file, bytes.NewReader(text)); err != nil {
		return err
	}
	if err := file.Truncate(int64(len(text))); err != nil {
		return err
	}
	return file.Sync()
}

// Writes through the captured descriptor, never by reopening its path. A
// replaced pathname cannot redirect an approved edit into a different file.
func (capture *promptEditorFile) apply(text []byte, verifyOwner func() error) error {
	if !validPromptEditorText(text) || verifyOwner == nil {
		return errors.New("invalid prompt editor replacement")
	}
	if err := syscall.Flock(int(capture.file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return err
	}
	defer syscall.Flock(int(capture.file.Fd()), syscall.LOCK_UN)
	if err := capture.unchanged(); err != nil {
		return err
	}
	if err := verifyOwner(); err != nil {
		return err
	}
	if err := writePromptEditorBytes(capture.file, text); err != nil {
		if restoreErr := writePromptEditorBytes(capture.file, capture.original); restoreErr != nil {
			return fmt.Errorf("prompt editor write and original restoration failed: %v; %v", err, restoreErr)
		}
		return err
	}
	pathInfo, err := os.Lstat(capture.path)
	if err != nil || !os.SameFile(capture.identity, pathInfo) {
		err = errors.New("prompt editor path changed during write")
	} else {
		err = verifyOwner()
	}
	if err != nil {
		if restoreErr := writePromptEditorBytes(capture.file, capture.original); restoreErr != nil {
			return fmt.Errorf("prompt editor validation and original restoration failed: %v; %v", err, restoreErr)
		}
		return err
	}
	return nil
}

// Fallback is true only for an explicitly unarmed/unsupported worker. An
// armed transaction never delegates to another editor after an error.
func RunPromptEditorFile(pane, path string) (fallback bool, err error) {
	rpc := func(request promptEditorRequest) (promptEditorResponse, error) {
		raw, err := json.Marshal(request)
		if err != nil {
			return promptEditorResponse{}, err
		}
		response, err := CallPromptEditor(pane, "", raw)
		if err != nil {
			return promptEditorResponse{}, err
		}
		var result promptEditorResponse
		if json.Unmarshal(response, &result) != nil {
			return result, errors.New("invalid prompt editor response")
		}
		return result, nil
	}
	status, err := rpc(promptEditorRequest{Operation: "editor-status"})
	if errors.Is(err, ErrPromptEditorUnsupported) {
		return true, nil
	}
	if err != nil {
		return false, err
	}
	if status.State == "unarmed" {
		return true, nil
	}
	if status.State == "cancelled" || status.State == "delivered" {
		return false, nil
	}
	if status.State != "armed" || !validPromptEditorID(status.ID) || status.Owner == nil {
		return false, errors.New("prompt editor capture refused")
	}
	verifyOwner := func() error {
		owner, err := ReadVerifiedPromptOwnerBinding(pane)
		if err != nil || owner != *status.Owner {
			return errors.New("prompt editor owner changed before file access")
		}
		return nil
	}
	capture, err := openPromptEditorFileForOwner(path, verifyOwner)
	if err != nil {
		return false, err
	}
	defer capture.file.Close()
	result, err := rpc(promptEditorRequest{Operation: "capture", ID: status.ID, Text: capture.original})
	if err != nil {
		return false, err
	}
	if !result.Apply {
		if result.State == "cancelled" && result.ID == status.ID {
			if err := capture.unchanged(); err != nil {
				return false, err
			}
			return false, verifyOwner()
		}
		return false, errors.New("prompt editor decision refused")
	}
	if result.State != "committed" || result.ID != status.ID {
		return false, errors.New("prompt editor transaction changed")
	}
	var applyErr error
	if sha256.Sum256(capture.original) == sha256.Sum256(result.Text) {
		applyErr = capture.unchanged()
		if applyErr == nil {
			applyErr = verifyOwner()
		}
	} else {
		applyErr = capture.apply(result.Text, verifyOwner)
	}
	if applyErr != nil {
		_, _ = rpc(promptEditorRequest{Operation: "editor-failed", ID: status.ID})
		return false, applyErr
	}
	if _, err := capture.file.Seek(0, io.SeekStart); err != nil {
		return false, err
	}
	applied, err := io.ReadAll(io.LimitReader(capture.file, promptEditorDraftLimit+1))
	if err != nil || !bytes.Equal(applied, result.Text) {
		_, _ = rpc(promptEditorRequest{Operation: "editor-failed", ID: status.ID})
		return false, errors.New("prompt editor applied contents changed")
	}
	digest := sha256.Sum256(applied)
	receipt, err := rpc(promptEditorRequest{Operation: "editor-applied", ID: status.ID, Digest: hex.EncodeToString(digest[:])})
	if err != nil {
		return false, err
	}
	if receipt.State != "applied" || receipt.ID != status.ID {
		return false, errors.New("prompt editor application receipt refused")
	}
	return false, nil
}
