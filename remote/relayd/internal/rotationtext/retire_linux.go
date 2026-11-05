//go:build linux

package rotationtext

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"syscall"

	"golang.org/x/sys/unix"
)

func platformSwapNames(a, b string) error {
	return unix.Renameat2(unix.AT_FDCWD, a, unix.AT_FDCWD, b, unix.RENAME_EXCHANGE)
}

// procRoot and procStat are seams for tests of the incomplete-scan rules.
var (
	procRoot = "/proc"
	procStat = os.Stat
)

// gone reports an error that proves the descriptor or process no longer
// exists (closed or exited between listing and reading).
func gone(err error) bool {
	return errors.Is(err, os.ErrNotExist) || errors.Is(err, syscall.ESRCH)
}

// platformLegacyHolders scans /proc for descriptors on the file's inode. For a
// process of this uid, any failure other than "closed/exited" makes the scan
// incomplete and is an error; other uids are outside the trust boundary. The
// image hash is read through /proc/PID/exe, which still works for a replaced
// or deleted executable.
func platformLegacyHolders(ctx context.Context, path string, info os.FileInfo) ([]legacyHolder, error) {
	entries, err := os.ReadDir(procRoot)
	if err != nil {
		return nil, &errHolderScan{err.Error()}
	}
	holders := []legacyHolder{}
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return nil, &errHolderScan{err.Error()}
		}
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid <= 0 {
			continue
		}
		base := filepath.Join(procRoot, entry.Name())
		mine, err := ownedByMe(base)
		if err != nil {
			if gone(err) {
				continue
			}
			return nil, &errHolderScan{fmt.Sprintf("pid %d owner: %v", pid, err)}
		}
		if !mine {
			continue
		}
		fds, err := os.ReadDir(filepath.Join(base, "fd"))
		if err != nil {
			if gone(err) {
				continue
			}
			return nil, &errHolderScan{fmt.Sprintf("pid %d descriptors: %v", pid, err)}
		}
		for _, fd := range fds {
			target, err := procStat(filepath.Join(base, "fd", fd.Name()))
			if err != nil {
				if gone(err) {
					continue
				}
				return nil, &errHolderScan{fmt.Sprintf("pid %d fd %s: %v", pid, fd.Name(), err)}
			}
			if !os.SameFile(target, info) {
				continue
			}
			if pid == os.Getpid() {
				holders = append(holders, legacyHolder{PID: pid, Image: "self"})
				break
			}
			image, _ := os.Readlink(filepath.Join(base, "exe"))
			data, err := os.ReadFile(filepath.Join(base, "exe"))
			if err != nil {
				if gone(err) {
					break
				}
				return nil, &errHolderScan{fmt.Sprintf("pid %d image: %v", pid, err)}
			}
			holders = append(holders, legacyHolder{PID: pid, Image: image, ImageSHA256: bytesSHA256(data)})
			break
		}
	}
	return holders, nil
}

func ownedByMe(base string) (bool, error) {
	info, err := os.Stat(base)
	if err != nil {
		return false, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return false, errors.New("no owner")
	}
	return stat.Uid == uint32(os.Getuid()), nil
}
