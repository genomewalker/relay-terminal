//go:build linux

package rotationtext

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

// A descriptor of this uid that cannot be read makes the scan incomplete;
// one that vanished (closed) is skipped; the scan finds this process.
func TestLinuxHolderScanIncompleteness(t *testing.T) {
	path := filepath.Join(t.TempDir(), "held")
	os.WriteFile(path, nil, 0o600)
	held, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	info := lstat(t, path)
	holders, err := platformLegacyHolders(context.Background(), path, info)
	if err != nil || len(holders) == 0 {
		t.Fatalf("scan: %v %v", holders, err)
	}
	found := false
	for _, h := range holders {
		found = found || h.PID == os.Getpid()
	}
	if !found {
		t.Fatal("own descriptor not observed")
	}
	saved := procStat
	defer func() { procStat = saved }()
	procStat = func(name string) (os.FileInfo, error) {
		if strings.Contains(name, "/fd/") {
			return nil, &os.PathError{Op: "stat", Path: name, Err: syscall.EACCES}
		}
		return saved(name)
	}
	var scan *errHolderScan
	if _, err := platformLegacyHolders(context.Background(), path, info); !errors.As(err, &scan) {
		t.Fatalf("unreadable descriptor accepted: %v", err)
	}
	procStat = func(name string) (os.FileInfo, error) {
		if strings.Contains(name, "/fd/") && !strings.HasSuffix(name, "/fd/"+strconv.Itoa(int(held.Fd()))) {
			return nil, &os.PathError{Op: "stat", Path: name, Err: syscall.ENOENT}
		}
		return saved(name)
	}
	if holders, err := platformLegacyHolders(context.Background(), path, info); err != nil || len(holders) == 0 {
		t.Fatalf("closed descriptors were not skipped: %v %v", holders, err)
	}
}
