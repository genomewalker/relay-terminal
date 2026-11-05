//go:build darwin

package rotationtext

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"syscall"

	"golang.org/x/sys/unix"
)

const lsofPath = "/usr/sbin/lsof"

func platformSwapNames(a, b string) error {
	return unix.RenamexNp(a, b, unix.RENAME_SWAP)
}

// Capture limits: lsof output past these is refused, and lsof is killed
// while running rather than buffered.
const (
	lsofStdoutCap = lsofOutputLimit
	lsofStderrCap = 64 << 10
)

// cappedBuffer keeps at most limit bytes; a write past it records the
// overflow, ends the command's context and fails the write. The buffer is a
// named field, not embedded: an embedded bytes.Buffer would give the type a
// ReadFrom method that io.Copy calls instead of Write, bypassing the cap.
type cappedBuffer struct {
	data     bytes.Buffer
	limit    int
	overflow bool
	stop     context.CancelFunc
}

var errCaptureOverflow = errors.New("command output exceeded its capture limit")

func (b *cappedBuffer) Write(p []byte) (int, error) {
	if b.overflow || b.data.Len()+len(p) > b.limit {
		b.overflow = true
		b.stop()
		return 0, errCaptureOverflow
	}
	return b.data.Write(p)
}

// runCapped runs name under ctx with bounded stdout and stderr capture. An
// overflow kills the command and is an error, never partial output.
func runCapped(ctx context.Context, name string, args ...string) (stdout, stderr []byte, exitCode int, err error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	out := &cappedBuffer{limit: lsofStdoutCap, stop: cancel}
	diag := &cappedBuffer{limit: lsofStderrCap, stop: cancel}
	command := exec.CommandContext(ctx, name, args...)
	command.Stdout, command.Stderr = out, diag
	err = command.Run()
	if out.overflow || diag.overflow {
		return nil, nil, -1, errCaptureOverflow
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return out.data.Bytes(), diag.data.Bytes(), exit.ExitCode(), nil
	}
	if err != nil {
		return nil, nil, -1, err
	}
	return out.data.Bytes(), diag.data.Bytes(), 0, nil
}

// runLsof runs lsof under ctx. It is a seam so tests can feed the gate exact
// diagnostics; production always calls /usr/sbin/lsof.
var runLsof = func(ctx context.Context, args ...string) (stdout, stderr []byte, exitCode int, err error) {
	return runCapped(ctx, lsofPath, args...)
}

// lsofStrict accepts only a successful run with no diagnostics. The caller
// itself holds what it asks about, so "found nothing" (exit 1) is never a
// valid answer here.
func lsofStrict(ctx context.Context, args ...string) ([]byte, error) {
	stdout, stderr, code, err := runLsof(ctx, args...)
	if err == nil {
		err = ctx.Err()
	}
	if err != nil {
		return nil, &errHolderScan{fmt.Sprintf("lsof did not run: %v", err)}
	}
	if code != 0 || len(stderr) > 0 {
		return nil, &errHolderScan{fmt.Sprintf("lsof exit %d, %d stdout bytes, diagnostics %q", code, len(stdout), clipBytes(stderr, 300))}
	}
	return stdout, nil
}

func clipBytes(b []byte, n int) string {
	if len(b) > n {
		return string(b[:n]) + "..."
	}
	return string(b)
}

// platformLegacyHolders lists the processes with the file open (lsof matches
// it by device and inode) and each one's exact image. Any incomplete answer
// is an error.
func platformLegacyHolders(ctx context.Context, path string, info os.FileInfo) ([]legacyHolder, error) {
	out, err := lsofStrict(ctx, "-n", "-P", "-F", "p", "--", path)
	if err != nil {
		return nil, err
	}
	pids, err := parseLsofHolders(out)
	if err != nil {
		return nil, &errHolderScan{err.Error()}
	}
	holders := []legacyHolder{}
	for _, pid := range pids {
		if pid == os.Getpid() {
			holders = append(holders, legacyHolder{PID: pid, Image: "self"})
			continue
		}
		image, sum, err := darwinImage(ctx, pid)
		if err != nil {
			return nil, err
		}
		holders = append(holders, legacyHolder{PID: pid, Image: image, ImageSHA256: sum})
	}
	return holders, nil
}

// imageCheckHook runs between the identity check and the hash; tests use it
// to replace the pathname at that instant.
var imageCheckHook = func(path string) {}

// darwinImage returns the executable of pid (its first txt descriptor) and the
// SHA-256 of that exact vnode: the file is opened once, its descriptor must
// have lsof's device and inode, and the hash is read from that descriptor.
// A path that no longer names the running vnode gives an unknown image with
// no hash, which is never allowlisted.
func darwinImage(ctx context.Context, pid int) (string, string, error) {
	out, err := lsofStrict(ctx, "-n", "-P", "-a", "-p", strconv.Itoa(pid), "-d", "txt", "-F", "Din")
	if err != nil {
		return "", "", err
	}
	device, inode, path, err := parseLsofImage(out, pid)
	if err != nil {
		return "", "", &errHolderScan{fmt.Sprintf("pid %d image: %v", pid, err)}
	}
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return path + " (unopenable: " + err.Error() + ")", "", nil
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return path + " (unreadable)", "", nil
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.Mode().IsRegular() || uint64(stat.Ino) != inode || uint64(uint32(stat.Dev)) != device {
		return path + " (not the running image)", "", nil
	}
	imageCheckHook(path)
	sum, err := descriptorSHA256(file)
	if err != nil {
		return path + " (unreadable)", "", nil
	}
	return path, sum, nil
}
