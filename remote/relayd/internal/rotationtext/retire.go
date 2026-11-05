package rotationtext

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// Retirement of the legacy sqlite journal, fenced against legacy writers.
//
// The retirement runs inside ReconcileLegacy, after the fold, still holding the
// ledger lock, the exclusive read gate and sqlite's SHARED lock on the legacy
// file. While SHARED is held no sqlite writer can reach EXCLUSIVE, so nothing
// can commit to the legacy file. The steps are:
//
//  1. Precondition, checked before anything is written: every executable in
//     the helper directories that names rotation-text has an allowlisted
//     SHA-256. Any other such image on an exec path refuses the operation.
//  2. A sealed copy is made: the exact bytes of the folded legacy file (whose
//     SHA-256 the fresh import record carries), mode 0400, the same mtime.
//  3. The sealed copy and the legacy file swap names atomically
//     (renamex_np RENAME_SWAP / renameat2 RENAME_EXCHANGE). The legacy path is
//     never absent: from this instant every new opener gets the sealed copy,
//     which a sqlite writer can only open read-only, so no new writer can
//     commit anywhere and the path is never recreated.
//  4. Only processes that opened the original inode before the swap can still
//     reach it, and that set can only shrink. Under the same locks the tool
//     refuses (and swaps back) if any other process holds RESERVED or PENDING
//     on it (a transaction in progress) or has it open while running an image
//     whose SHA-256 is not on the operator's reviewed allowlist. The holder
//     scan must be complete and must observe this process's own descriptor
//     on the inode; anything else refuses.
//
// Ledger-aware relayds that predate r1 accept the sealed copy: it is a private
// regular file with one link whose bytes match the import record.
// Trust boundary: processes of this uid are visible to the holder scan (lsof on
// Darwin, /proc on Linux); a process of another uid could hold the file only
// through a permission the 0700 directory does not grant. The allowlist is the
// operator's statement of which exact images were reviewed as never writing
// the legacy journal; "names rotation-text" only selects which helper
// executables must be on it.

const (
	retiredSuffix  = ".retired-"
	textRootMarker = "rotation-text"
	holderScanTime = 15 * time.Second
)

// RetireReport describes a retirement.
type RetireReport struct {
	Retired       bool     `json:"retired"`
	RetiredPath   string   `json:"retired_path,omitempty"`
	SealedSHA256  string   `json:"sealed_sha256,omitempty"`
	HelpersOK     []string `json:"allowlisted_helpers"`
	HoldersSeen   []string `json:"holders_seen"`
	SwappedBack   bool     `json:"swapped_back,omitempty"`
	RefusalReason string   `json:"refusal_reason,omitempty"`
}

// errRetireRefused stops a retirement with the legacy file left in place.
type errRetireRefused struct{ reason string }

func (e *errRetireRefused) Error() string {
	return "legacy journal not retired: " + e.reason
}

// legacyHolder is a process with the legacy inode open. ImageSHA256 is empty
// for this process itself, whose image is never classified.
type legacyHolder struct {
	PID         int
	Image       string
	ImageSHA256 string
}

// errHolderScan is an incomplete or unparsable holder inventory.
type errHolderScan struct{ reason string }

func (e *errHolderScan) Error() string { return "holder scan incomplete: " + e.reason }

// Seams for tests; production values are the platform implementations.
var (
	listLegacyHolders = platformLegacyHolders
	swapNames         = platformSwapNames
	retireNow         = time.Now
)

// imageHashLimit bounds how much of an executable is hashed.
const imageHashLimit = 1 << 30

// descriptorSHA256 hashes an open file from its start; larger than the limit
// is an error.
func descriptorSHA256(file *os.File) (string, error) {
	hash := sha256.New()
	n, err := io.Copy(hash, io.NewSectionReader(file, 0, imageHashLimit+1))
	if err != nil {
		return "", err
	}
	if n > imageHashLimit {
		return "", errors.New("image larger than the hash limit")
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

// fileSHA256 hashes the file at path, or returns "".
func fileSHA256(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return bytesSHA256(data)
}

// allowlist normalizes the operator's reviewed image hashes.
func allowlist(hashes []string) (map[string]bool, error) {
	allowed := map[string]bool{}
	for _, hash := range hashes {
		hash = strings.ToLower(strings.TrimSpace(hash))
		if len(hash) != 64 || strings.Trim(hash, "0123456789abcdef") != "" {
			return nil, &errRetireRefused{fmt.Sprintf("invalid image SHA-256 %q", hash)}
		}
		allowed[hash] = true
	}
	if len(allowed) == 0 {
		return nil, &errRetireRefused{"no reviewed image SHA-256 allowlist was given"}
	}
	return allowed, nil
}

// checkHelperDirs refuses when an executable in dirs names rotation-text but
// its exact image is not allowlisted: a writer that could still be launched.
func checkHelperDirs(dirs []string, allowed map[string]bool) ([]string, error) {
	ok := []string{}
	if len(dirs) == 0 {
		return ok, &errRetireRefused{"no helper directory to inventory"}
	}
	for _, dir := range dirs {
		entries, err := os.ReadDir(dir)
		if err != nil {
			return ok, &errRetireRefused{fmt.Sprintf("cannot inventory helper directory %s: %v", dir, err)}
		}
		for _, entry := range entries {
			path := filepath.Join(dir, entry.Name())
			info, err := os.Stat(path)
			if err != nil {
				return ok, &errRetireRefused{fmt.Sprintf("cannot stat helper %s: %v", path, err)}
			}
			if !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
				continue
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return ok, &errRetireRefused{fmt.Sprintf("cannot read helper %s: %v", path, err)}
			}
			if !bytes.Contains(data, []byte(textRootMarker)) {
				continue
			}
			if sum := bytesSHA256(data); !allowed[sum] {
				return ok, &errRetireRefused{fmt.Sprintf("helper %s (sha256 %s) names rotation-text and is not a reviewed image; replace or move it first", path, sum)}
			}
			ok = append(ok, path)
		}
	}
	return ok, nil
}

// lockOwner returns the pid of another process holding a lock that conflicts
// with a write lock on byte at, or 0.
func lockOwner(file *os.File, at int64) (int, error) {
	probe := syscall.Flock_t{Type: syscall.F_WRLCK, Whence: io.SeekStart, Start: at, Len: 1}
	if err := syscall.FcntlFlock(file.Fd(), syscall.F_GETLK, &probe); err != nil {
		return 0, err
	}
	if probe.Type == syscall.F_UNLCK {
		return 0, nil
	}
	return int(probe.Pid), nil
}

// suspectHolders lists what keeps retirement unsafe: a transaction in progress
// on the original inode, or a holder whose image is not allowlisted. The scan
// must observe this process's own descriptor, or it proves nothing.
func suspectHolders(ctx context.Context, file *os.File, path string, allowed map[string]bool, report *RetireReport) ([]string, error) {
	suspects := []string{}
	for _, at := range []int64{sqlitePendingByte, sqliteReservedByte} {
		pid, err := lockOwner(file, at)
		if err != nil {
			return nil, err
		}
		if pid != 0 {
			name := "RESERVED"
			if at == sqlitePendingByte {
				name = "PENDING"
			}
			suspects = append(suspects, fmt.Sprintf("pid %d holds sqlite %s (a transaction in progress)", pid, name))
		}
	}
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	scanCtx, cancel := context.WithTimeout(ctx, holderScanTime)
	defer cancel()
	holders, err := listLegacyHolders(scanCtx, path, info)
	if err != nil {
		return nil, err
	}
	self := false
	for _, holder := range holders {
		if holder.PID == os.Getpid() {
			self = true
			continue
		}
		allowedImage := holder.ImageSHA256 != "" && allowed[holder.ImageSHA256]
		report.HoldersSeen = append(report.HoldersSeen, fmt.Sprintf("pid %d %s sha256=%s allowlisted=%v", holder.PID, holder.Image, holder.ImageSHA256, allowedImage))
		if !allowedImage {
			suspects = append(suspects, fmt.Sprintf("pid %d (%s, sha256 %s) has the legacy journal open and is not a reviewed image", holder.PID, holder.Image, holder.ImageSHA256))
		}
	}
	if !self {
		return nil, &errHolderScan{"this process's own descriptor on the legacy inode was not observed"}
	}
	return suspects, nil
}

// retireLegacy runs steps 2-4 under the caller's locks. legacy is the held
// descriptor of the original inode; record is the import record just written
// (or already current), whose SHA-256 the sealed copy must match.
func (l *Ledger) retireLegacy(legacy *os.File, record LedgerImport, allowed map[string]bool, report *RetireReport) (err error) {
	path := l.path(legacyJournalName)
	for _, suffix := range []string{"-journal", "-wal", "-shm"} {
		if _, err := os.Lstat(path + suffix); !errors.Is(err, os.ErrNotExist) {
			return &errRetireRefused{"sqlite side file " + legacyJournalName + suffix + " is present"}
		}
	}
	info, err := legacy.Stat()
	if err != nil {
		return err
	}
	data := make([]byte, info.Size())
	if _, err := legacy.ReadAt(data, 0); err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	// Never open a second descriptor on the legacy inode: closing it would
	// drop this process's POSIX SHARED lock.
	if sum := bytesSHA256(data); sum != record.SHA256 {
		return &errRetireRefused{"legacy journal bytes do not match the import record"}
	}
	stamp := retireNow().UTC().Format("20060102T150405Z")
	retired := path + retiredSuffix + stamp
	if _, err := os.Lstat(retired); !errors.Is(err, os.ErrNotExist) {
		return &errRetireRefused{"retired name already exists: " + retired}
	}
	sealed, err := os.OpenFile(retired, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return err
	}
	created := true
	defer func() {
		if created && err != nil {
			os.Remove(retired) // the sealed copy this call created, never the original
		}
	}()
	if _, err = sealed.Write(data); err == nil {
		err = ledgerSync(sealed)
	}
	if closeErr := sealed.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err = os.Chmod(retired, 0o400); err != nil {
		return err
	}
	if err = os.Chtimes(retired, info.ModTime(), info.ModTime()); err != nil {
		return err
	}
	if err = swapNames(retired, path); err != nil {
		return err
	}
	// From here the original inode is at retired and the sealed copy at path.
	swappedBack := false
	defer func() {
		if err != nil && !swappedBack {
			if swapErr := swapNames(retired, path); swapErr == nil {
				report.SwappedBack = true
			} else {
				created = false // ambiguous: leave both names for the operator
				err = fmt.Errorf("%w; swapping back failed too: %v", err, swapErr)
			}
		}
	}()
	if err = syncDirectory(l.root); err != nil {
		return err
	}
	suspects, err := suspectHolders(l.ctx, legacy, retired, allowed, report)
	if err != nil {
		return err
	}
	if len(suspects) > 0 {
		err = &errRetireRefused{strings.Join(suspects, "; ")}
		return err
	}
	now, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if os.SameFile(now, info) || now.Mode().Perm() != 0o400 {
		err = &errRetireRefused{"the legacy path is not the sealed copy after the swap"}
		return err
	}
	created = false // success: retired now names the original inode
	report.Retired, report.RetiredPath, report.SealedSHA256 = true, retired, record.SHA256
	return nil
}
