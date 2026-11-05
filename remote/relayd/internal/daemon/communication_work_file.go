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
	if err := workSendablePath(path); err != nil {
		return nil, err
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
	if current, e := os.Lstat(path); e != nil || !os.SameFile(current, info) {
		return nil, errors.New("file changed while opening; no request submitted")
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

// Bounds on what a pinned peer can leave in the save root. A var so tests can
// lower them. The check is made before each save and is not atomic across
// concurrent saves, so the limits can be overshot by a few in-flight files.
var (
	workFileMaxCount = 512
	workFileMaxBytes = int64(64 << 20)
)

// workFileUsage counts saved files (not markers or temporaries) under root.
func workFileUsage(root string) (count int, size int64) {
	_ = filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || strings.HasPrefix(d.Name(), ".") {
			return nil
		}
		if info, e := d.Info(); e == nil {
			count++
			size += info.Size()
		}
		return nil
	})
	return
}

// workSaveDir returns the per-message directory for one sending node. The
// plain message ID is used first; a different node that reuses the same ID gets
// its own suffixed directory instead of colliding. A node's own repeat is
// still refused by the no-replace link in saveWorkFile.
func workSaveDir(root, messageID, owner string) (string, error) {
	sum := sha256.Sum256([]byte(owner))
	tag := hex.EncodeToString(sum[:8])
	for _, name := range []string{messageID, messageID + "-" + tag} {
		dir := filepath.Join(root, name)
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return "", err
		}
		marker := filepath.Join(dir, ".owner")
		data, err := os.ReadFile(marker)
		if errors.Is(err, os.ErrNotExist) {
			f, e := os.OpenFile(marker, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
			if e != nil {
				return "", errors.New("Work file directory is in use")
			}
			_, e = f.WriteString(tag)
			if c := f.Close(); e == nil {
				e = c
			}
			if e != nil {
				return "", e
			}
			return dir, nil
		}
		if err == nil && string(data) == tag {
			return dir, nil
		}
	}
	return "", errors.New("Work file directory is in use")
}

// saveWorkFile writes verified bytes to <root>/<message_id>/<name> (or the
// sender-scoped directory on an ID collision) with mode 0600 and never
// replaces an existing file.
func saveWorkFile(owner, messageID, name string, content []byte) (string, error) {
	root, err := workFileRoot()
	if err != nil {
		return "", err
	}
	if owner == "" || !validSessionID.MatchString(messageID) || !validWorkFileName(name) {
		return "", errors.New("invalid Work file identity")
	}
	if err = os.MkdirAll(root, 0o700); err != nil {
		return "", err
	}
	if err = os.Chmod(root, 0o700); err != nil {
		return "", err
	}
	if count, size := workFileUsage(root); count >= workFileMaxCount || size+int64(len(content)) > workFileMaxBytes {
		return "", errors.New("Work file storage limit reached")
	}
	dir, err := workSaveDir(root, messageID, owner)
	if err != nil {
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

// The file name is chosen by the peer, so it and the path are quoted and
// ASCII-escaped: it cannot add lines, brackets or look-alike text to the note.
func workFileNotice(m workWire, saved string) string {
	return "\n\n[Relay file] " + strconv.QuoteToASCII(m.FileName) + ", " + strconv.FormatInt(m.FileSize, 10) + " bytes, SHA-256 " + m.FileSHA256 + ", verified and saved on this host at " + strconv.QuoteToASCII(saved)
}

func workDefaultFileText(a *workAttachment) string {
	return "Sending file " + strconv.QuoteToASCII(a.name) + " (" + strconv.Itoa(len(a.content)) + " bytes, SHA-256 " + a.sha256 + ")."
}

// workOutboxRoot is the only directory a sender may send files from. Callers
// copy a file there first; nothing else on the host is reachable this way.
var workOutboxRoot = func() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".local", "share", "relay", "work-outbox"), nil
}

// workSendablePath keeps credentials and tool state off the link. The caller
// is an authenticated endpoint, but a provider agent can be steered by its
// inputs, so the sender sends only regular files inside the per-host outbox:
// the path must resolve, with no symlinked component, to itself under the
// canonical outbox root. Inside the outbox, hidden components and key or
// credential file names are refused as defence in depth.
func workSendablePath(path string) error {
	root, err := workOutboxRoot()
	if err != nil {
		return errors.New("Work outbox unavailable; no request submitted")
	}
	canonicalRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return errors.New("Work outbox " + root + " does not exist; create it (mode 0700) and copy the file there; no request submitted")
	}
	if info, e := os.Stat(canonicalRoot); e != nil || !info.IsDir() || info.Mode().Perm()&0o077 != 0 {
		return errors.New("Work outbox " + root + " must be a private directory (mode 0700); no request submitted")
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return errors.New("file unavailable; no request submitted")
	}
	if resolved != path {
		return errors.New("file path must be canonical with no symlinked component; no request submitted")
	}
	rel, err := filepath.Rel(canonicalRoot, resolved)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, "../") || filepath.IsAbs(rel) {
		return errors.New("only files inside the Work outbox " + root + " are sent; copy the file there first; no request submitted")
	}
	for _, part := range strings.Split(rel, "/") {
		if strings.HasPrefix(part, ".") {
			return errors.New("hidden files or directories are not sent; no request submitted")
		}
	}
	lower := strings.ToLower(filepath.Base(path))
	for _, prefix := range []string{"id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "credential", "authorized_keys", "known_hosts"} {
		if strings.HasPrefix(lower, prefix) {
			return errors.New("key or credential files are not sent; no request submitted")
		}
	}
	for _, suffix := range []string{".pem", ".key", ".p12", ".pfx", ".kdbx", ".keychain", ".keychain-db", ".ppk", ".gpg", ".asc"} {
		if strings.HasSuffix(lower, suffix) {
			return errors.New("key or credential files are not sent; no request submitted")
		}
	}
	for _, word := range []string{"secret", "token", "password", "passwd"} {
		if strings.Contains(lower, word) {
			return errors.New("key or credential files are not sent; no request submitted")
		}
	}
	return nil
}
