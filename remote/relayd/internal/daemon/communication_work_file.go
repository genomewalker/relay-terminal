package daemon

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"unicode"
	"unicode/utf8"
)

// A Work link may carry one small regular file per message. The file travels
// inside the existing pinned mutual-TLS Work wire; its name, size and SHA-256
// are bound into the message fingerprint, and the receiver saves it only after
// recomputing the digest. 64 KiB keeps the base64 body under the 128 KiB peer
// transport limit shared by every peer request.
const workFileLimit = 64 << 10

type workAttachment struct {
	name    string
	sha256  string
	content []byte
}

// workFileRoot is where a receiving host saves verified files.
var workFileRoot = func() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".local", "share", "relay", "work-files"), nil
}

func validWorkFileName(name string) bool {
	if name == "" || len(name) > 255 || !utf8.ValidString(name) || name == "." || name == ".." || strings.HasPrefix(name, ".") || strings.ContainsAny(name, `/\`) {
		return false
	}
	for _, r := range name {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

// readWorkAttachment reads the caller's own regular file on the sending host
// and requires it to match the digest the caller declared.
func readWorkAttachment(path, declared string) (*workAttachment, error) {
	declared = strings.ToLower(strings.TrimSpace(declared))
	if !remoteDigest(declared) {
		return nil, errors.New("file_sha256 must be 64 lowercase hex characters")
	}
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return nil, errors.New("file path must be absolute and clean")
	}
	name := filepath.Base(path)
	if !validWorkFileName(name) {
		return nil, errors.New("file name is not transferable")
	}
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, errors.New("file unavailable; no request submitted")
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return nil, errors.New("only a regular file can be sent")
	}
	if info.Size() == 0 || info.Size() > workFileLimit {
		return nil, fmt.Errorf("file must be 1-%d bytes", workFileLimit)
	}
	content, err := io.ReadAll(io.LimitReader(f, workFileLimit+1))
	if err != nil || len(content) == 0 || len(content) > workFileLimit {
		return nil, errors.New("file changed while reading; no request submitted")
	}
	sum := sha256.Sum256(content)
	if hex.EncodeToString(sum[:]) != declared {
		return nil, errors.New("file SHA-256 does not match file_sha256; no request submitted")
	}
	return &workAttachment{name: name, sha256: declared, content: content}, nil
}

// workWireFileValid checks the fingerprinted file fields: all absent, or a
// safe name, a bounded size and a digest.
func workWireFileValid(m workWire) bool {
	if m.FileName == "" && m.FileSize == 0 && m.FileSHA256 == "" {
		return m.FileContent == ""
	}
	return validWorkFileName(m.FileName) && m.FileSize > 0 && m.FileSize <= workFileLimit && remoteDigest(m.FileSHA256)
}

// decodeWorkWireFile verifies the carried bytes against the fingerprinted
// size and digest before anything is claimed or saved.
func decodeWorkWireFile(m workWire) ([]byte, error) {
	content, err := base64.StdEncoding.Strict().DecodeString(m.FileContent)
	if err != nil || int64(len(content)) != m.FileSize {
		return nil, errors.New("Work file size mismatch")
	}
	sum := sha256.Sum256(content)
	if hex.EncodeToString(sum[:]) != m.FileSHA256 {
		return nil, errors.New("Work file SHA-256 mismatch")
	}
	return content, nil
}

// saveWorkFile writes verified bytes to <root>/<message_id>/<name> with mode
// 0600 and never replaces an existing file.
func saveWorkFile(messageID, name string, content []byte) (string, error) {
	root, err := workFileRoot()
	if err != nil {
		return "", err
	}
	if !validSessionID.MatchString(messageID) || !validWorkFileName(name) {
		return "", errors.New("invalid Work file identity")
	}
	dir := filepath.Join(root, messageID)
	if err = os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	if err = os.Chmod(root, 0o700); err != nil {
		return "", err
	}
	final := filepath.Join(dir, name)
	f, err := os.CreateTemp(dir, ".work-file-*")
	if err != nil {
		return "", err
	}
	temp := f.Name()
	defer os.Remove(temp)
	if err = f.Chmod(0o600); err == nil {
		_, err = f.Write(content)
	}
	if err == nil {
		err = f.Sync()
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return "", err
	}
	if err = os.Link(temp, final); err != nil {
		return "", errors.New("Work file already exists; not replaced")
	}
	saved, err := os.ReadFile(final)
	if err != nil {
		return "", err
	}
	if sha256.Sum256(saved) != sha256.Sum256(content) {
		return "", errors.New("saved Work file failed verification")
	}
	return final, nil
}

func workFileNotice(m workWire, saved string) string {
	return "\n\n[Relay file] " + m.FileName + ", " + strconv.FormatInt(m.FileSize, 10) + " bytes, SHA-256 " + m.FileSHA256 + ", verified and saved on this host at " + saved
}

func workDefaultFileText(a *workAttachment) string {
	return "Sending file " + a.name + " (" + strconv.Itoa(len(a.content)) + " bytes, SHA-256 " + a.sha256 + ")."
}
