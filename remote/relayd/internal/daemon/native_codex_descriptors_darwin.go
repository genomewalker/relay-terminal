//go:build darwin

package daemon

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"os"
	"runtime"
	"strings"
	"syscall"
	"unicode/utf8"
	"unsafe"

	"golang.org/x/sys/unix"
)

// Public macOS proc_info ABI, checked against the installed SDK's libproc.h
// and sys/proc_info.h on both supported Darwin architectures. The libproc
// wrappers issue PIDINFO=2 and PIDFDINFO=3; no subprocess or cgo is required.
const (
	darwinNativeFDLimit       = 4096
	darwinNativeFDRecordSize  = 8
	darwinNativeVnodeInfoSize = 1200
	darwinNativeVnodePath     = 176
	darwinNativeVnodePathSize = 1024
)

type darwinNativeFD struct {
	number uint32
	kind   uint32
}

func darwinNativeFDRecords(data []byte) ([]darwinNativeFD, error) {
	if len(data) == 0 || len(data)%darwinNativeFDRecordSize != 0 ||
		len(data)/darwinNativeFDRecordSize > darwinNativeFDLimit {
		return nil, errors.New("native descriptor inventory incomplete or exceeds limit")
	}
	result := make([]darwinNativeFD, 0, len(data)/darwinNativeFDRecordSize)
	seen := map[uint32]bool{}
	for offset := 0; offset < len(data); offset += darwinNativeFDRecordSize {
		number := binary.LittleEndian.Uint32(data[offset:])
		kind := binary.LittleEndian.Uint32(data[offset+4:])
		if number >= darwinNativeFDLimit || seen[number] {
			return nil, errors.New("native descriptor identity ambiguous or exceeds limit")
		}
		seen[number] = true
		result = append(result, darwinNativeFD{number, kind})
	}
	return result, nil
}

func darwinNativeVnodeDescriptor(number uint32, data []byte) (darwinNativeTranscriptDescriptor, bool, error) {
	var empty darwinNativeTranscriptDescriptor
	if number >= darwinNativeFDLimit || len(data) != darwinNativeVnodeInfoSize {
		return empty, false, errors.New("native vnode inventory incomplete")
	}
	mode := binary.LittleEndian.Uint16(data[28:])
	if mode&syscall.S_IFMT != syscall.S_IFREG {
		return empty, false, nil
	}
	pathData := data[darwinNativeVnodePath : darwinNativeVnodePath+darwinNativeVnodePathSize]
	end := bytes.IndexByte(pathData, 0)
	if end < 0 {
		return empty, false, errors.New("native vnode path truncated")
	}
	path := string(pathData[:end])
	if !strings.HasSuffix(path, ".jsonl") {
		return empty, false, nil
	}
	device := uint64(binary.LittleEndian.Uint32(data[24:]))
	inode := binary.LittleEndian.Uint64(data[32:])
	uid := binary.LittleEndian.Uint32(data[40:])
	links := binary.LittleEndian.Uint16(data[30:])
	if inode == 0 || int(uid) != os.Getuid() || links != 1 ||
		!utf8.ValidString(path) || !strings.HasPrefix(path, "/") {
		return empty, false, errors.New("native transcript vnode identity unavailable")
	}
	return darwinNativeTranscriptDescriptor{int(number), path, device, inode}, true, nil
}

func darwinNativeProcInfo(ctx context.Context, call, pid, flavor, arg int, buffer []byte) (int, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	if pid <= 1 || len(buffer) == 0 {
		return 0, errors.New("invalid native descriptor process or buffer")
	}
	count, _, errno := unix.Syscall6(unix.SYS_PROC_INFO, uintptr(call), uintptr(pid),
		uintptr(flavor), uintptr(arg), uintptr(unsafe.Pointer(&buffer[0])), uintptr(len(buffer)))
	runtime.KeepAlive(buffer)
	if errno != 0 {
		return 0, errno
	}
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	if count == 0 || count > uintptr(len(buffer)) {
		return 0, errors.New("native descriptor observation unavailable")
	}
	return int(count), nil
}

func darwinKernelTranscriptDescriptors(ctx context.Context, pid int) ([]darwinNativeTranscriptDescriptor, error) {
	// One spare entry makes a full/truncated inventory unambiguously ineligible.
	buffer := make([]byte, (darwinNativeFDLimit+1)*darwinNativeFDRecordSize)
	count, err := darwinNativeProcInfo(ctx, 2, pid, 1, 0, buffer)
	if err != nil {
		return nil, err
	}
	records, err := darwinNativeFDRecords(buffer[:count])
	if err != nil {
		return nil, err
	}
	result := []darwinNativeTranscriptDescriptor{}
	for _, record := range records {
		if record.kind != 1 { // PROX_FDTYPE_VNODE
			continue
		}
		vnode := make([]byte, darwinNativeVnodeInfoSize)
		count, err := darwinNativeProcInfo(ctx, 3, pid, 2, int(record.number), vnode)
		if err != nil {
			return nil, err
		}
		value, eligible, err := darwinNativeVnodeDescriptor(record.number, vnode[:count])
		if err != nil {
			return nil, err
		}
		if eligible {
			result = append(result, value)
		}
	}
	return result, nil
}
