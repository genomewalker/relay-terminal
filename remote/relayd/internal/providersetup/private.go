package providersetup

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

const FileLimit = 2 << 20

// Store anchors every destination below one owned home directory. Subsequent
// component traversal and final-file opens never follow symbolic links.
type Store struct {
	root int
	home string
	// beforeCommit is a deterministic scheduling seam used by the bounded CAS
	// checks. It is nil in every command-line caller.
	beforeCommit func(string)
}
type snapshot struct {
	raw  []byte
	stat unix.Stat_t
}

func ownedRegular(mode uint32, uid uint32, expected uint32) bool {
	return uid == expected && mode&unix.S_IFMT == unix.S_IFREG
}

func Open(home string) (*Store, error) {
	if !filepath.IsAbs(home) {
		return nil, errors.New("home must be absolute")
	}
	fd, e := unix.Open(home, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if e != nil {
		return nil, e
	}
	var st unix.Stat_t
	if e = unix.Fstat(fd, &st); e != nil || st.Uid != uint32(os.Getuid()) {
		unix.Close(fd)
		return nil, errors.New("home must be an owned directory")
	}
	return &Store{root: fd, home: home}, nil
}
func (s *Store) Close() error { return unix.Close(s.root) }
func parts(path string) ([]string, error) {
	if len(path) == 0 || len(path) > 4096 || filepath.IsAbs(path) || strings.ContainsRune(path, 0) {
		return nil, errors.New("invalid relative path")
	}
	p := strings.Split(path, "/")
	for _, v := range p {
		if v == "" || v == "." || v == ".." {
			return nil, errors.New("invalid path component")
		}
	}
	return p, nil
}
func (s *Store) parent(path string, create bool) (int, string, error) {
	p, e := parts(path)
	if e != nil {
		return -1, "", e
	}
	fd, e := unix.Dup(s.root)
	if e != nil {
		return -1, "", e
	}
	for _, v := range p[:len(p)-1] {
		n, e := unix.Openat(fd, v, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		if errors.Is(e, unix.ENOENT) && create {
			if x := unix.Mkdirat(fd, v, 0700); x != nil && !errors.Is(x, unix.EEXIST) {
				unix.Close(fd)
				return -1, "", x
			}
			n, e = unix.Openat(fd, v, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		}
		unix.Close(fd)
		if e != nil {
			return -1, "", e
		}
		var st unix.Stat_t
		if e = unix.Fstat(n, &st); e != nil || st.Uid != uint32(os.Getuid()) {
			unix.Close(n)
			return -1, "", errors.New("parent must be an owned directory")
		}
		fd = n
	}
	return fd, p[len(p)-1], nil
}
func readAt(fd int, name string) (*snapshot, error) {
	f, e := unix.Openat(fd, name, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if errors.Is(e, unix.ENOENT) {
		return nil, nil
	}
	if e != nil {
		return nil, e
	}
	file := os.NewFile(uintptr(f), name)
	defer file.Close()
	var st unix.Stat_t
	if e = unix.Fstat(f, &st); e != nil {
		return nil, e
	}
	if !ownedRegular(uint32(st.Mode), st.Uid, uint32(os.Getuid())) {
		return nil, errors.New("destination must be an owned regular file")
	}
	if st.Size > FileLimit {
		return nil, errors.New("file exceeds bound")
	}
	raw, e := io.ReadAll(io.LimitReader(file, FileLimit+1))
	if e != nil {
		return nil, e
	}
	if len(raw) > FileLimit {
		return nil, errors.New("file exceeds bound")
	}
	var after unix.Stat_t
	if e = unix.Fstat(f, &after); e != nil {
		return nil, e
	}
	if after.Size != st.Size || after.Mtim != st.Mtim || after.Ino != st.Ino {
		return nil, errors.New("file changed during read")
	}
	return &snapshot{raw: raw, stat: st}, nil
}
func (s *Store) read(path string) (*snapshot, error) {
	fd, name, e := s.parent(path, false)
	if errors.Is(e, unix.ENOENT) {
		return nil, nil
	}
	if e != nil {
		return nil, e
	}
	defer unix.Close(fd)
	return readAt(fd, name)
}
func same(a, b *snapshot) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return a.stat.Ino == b.stat.Ino && a.stat.Dev == b.stat.Dev && a.stat.Mtim == b.stat.Mtim && a.stat.Size == b.stat.Size && bytes.Equal(a.raw, b.raw)
}
func randomName(prefix string) (string, error) {
	var b [12]byte
	if _, e := rand.Read(b[:]); e != nil {
		return "", e
	}
	return prefix + hex.EncodeToString(b[:]), nil
}
func writeExclusive(fd int, name string, raw []byte, mode uint32) error {
	n, e := unix.Openat(fd, name, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, mode)
	if e != nil {
		return e
	}
	f := os.NewFile(uintptr(n), name)
	_, e = f.Write(raw)
	// Creation modes are filtered by umask, and a write may clear special mode
	// bits. The canonical adapter repair chmods only after writing; retain that
	// exact mode contract before syncing or publishing the temporary file.
	if e == nil {
		e = unix.Fchmod(n, mode)
	}
	if e == nil {
		e = f.Sync()
	}
	if x := f.Close(); e == nil {
		e = x
	}
	return e
}

func privateDirectory(fd int) error {
	var st unix.Stat_t
	if e := unix.Fstat(fd, &st); e != nil {
		return e
	}
	if st.Uid != uint32(os.Getuid()) || st.Mode&unix.S_IFMT != unix.S_IFDIR || st.Mode&077 != 0 {
		return errors.New("backup directory must be owned and private")
	}
	return nil
}

// replace uses the caller's original snapshot rather than silently rebasing a
// settings transformation onto a concurrently changed destination.
func (s *Store) replace(path string, raw []byte, expected *snapshot, mode uint32, backupName string) error {
	if len(raw) > FileLimit {
		return errors.New("replacement exceeds bound")
	}
	fd, name, e := s.parent(path, true)
	if e != nil {
		return e
	}
	defer unix.Close(fd)
	current, e := readAt(fd, name)
	if e != nil {
		return e
	}
	if !same(expected, current) {
		return errors.New("destination changed before installation")
	}
	if current != nil && bytes.Equal(current.raw, raw) {
		return nil
	}
	if current != nil {
		if e = unix.Mkdirat(fd, "backups", 0700); e != nil && !errors.Is(e, unix.EEXIST) {
			return e
		}
		bfd, e := unix.Openat(fd, "backups", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		if e != nil {
			return e
		}
		var st unix.Stat_t
		if e = unix.Fstat(bfd, &st); e != nil || st.Uid != uint32(os.Getuid()) || st.Mode&077 != 0 {
			unix.Close(bfd)
			return errors.New("backup directory must be owned and private")
		}
		bn := backupName
		if bn == "" {
			bn, e = randomName(name + "-shell-ui-")
			if e != nil {
				unix.Close(bfd)
				return e
			}
		}
		e = writeExclusive(bfd, bn, current.raw, 0600)
		if e == nil {
			e = unix.Fsync(bfd)
		}
		unix.Close(bfd)
		if e != nil {
			return e
		}
	}
	temporary, e := randomName("." + name + "-")
	if e != nil {
		return e
	}
	if e = writeExclusive(fd, temporary, raw, mode); e != nil {
		return e
	}
	defer unix.Unlinkat(fd, temporary, 0)
	if s.beforeCommit != nil {
		s.beforeCommit(path)
	}
	current, e = readAt(fd, name)
	if e != nil {
		return e
	}
	if !same(expected, current) {
		return errors.New("destination changed during installation")
	}
	if e = unix.Renameat(fd, temporary, fd, name); e != nil {
		return e
	}
	return unix.Fsync(fd)
}
func (s *Store) put(path string, raw []byte, mode uint32) error {
	old, e := s.read(path)
	if e != nil {
		return e
	}
	return s.replace(path, raw, old, mode, "")
}
func (s *Store) locked(fn func() error) error {
	fd, name, e := s.parent(".config/relay/provider-setup.lock", true)
	if e != nil {
		return e
	}
	defer unix.Close(fd)
	lock, e := unix.Openat(fd, name, unix.O_RDWR|unix.O_CREAT|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0600)
	if e != nil {
		return e
	}
	defer unix.Close(lock)
	var st unix.Stat_t
	if e = unix.Fstat(lock, &st); e != nil || st.Uid != uint32(os.Getuid()) || st.Mode&unix.S_IFMT != unix.S_IFREG || st.Mode&077 != 0 {
		return fmt.Errorf("setup lock must be an owned private regular file")
	}
	if e = unix.Flock(lock, unix.LOCK_EX); e != nil {
		return e
	}
	defer unix.Flock(lock, unix.LOCK_UN)
	return fn()
}
