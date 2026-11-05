//go:build darwin

package workorigin

import (
	"bytes"
	"crypto/sha256"
	"crypto/sha512"
	"debug/macho"
	"encoding/binary"
	"errors"
	"golang.org/x/sys/unix"
	"io"
	"os"
	"runtime"
	"unsafe"
)

type nativeReader struct{}

func (nativeReader) uid() uint32 { return uint32(os.Getuid()) }
func (nativeReader) process(pid int) (Process, error) {
	if pid <= 1 || pid > 1<<31-1 {
		return Process{}, errors.New("invalid pid")
	}
	k, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil || k == nil || int(k.Proc.P_pid) != pid || k.Proc.P_stat == 5 {
		return Process{}, errors.New("process unavailable")
	}
	var path [4096]byte
	_, _, errno := unix.Syscall6(unix.SYS_PROC_INFO, 2, uintptr(pid), 11, 0, uintptr(unsafe.Pointer(&path[0])), uintptr(len(path)))
	runtime.KeepAlive(&path)
	end := bytes.IndexByte(path[:], 0)
	if errno != 0 || end <= 0 {
		return Process{}, errors.New("kernel executable unavailable")
	}
	return Process{PID: pid, Parent: int(k.Eproc.Ppid), UID: k.Eproc.Ucred.Uid, StartMicros: k.Proc.P_starttime.Sec*1000000 + int64(k.Proc.P_starttime.Usec), Executable: string(path[:end])}, nil
}
func (nativeReader) pipe(pid, fd int) (Pipe, error) {
	if pid <= 1 || pid > 1<<31-1 || fd < 0 {
		return Pipe{}, errors.New("invalid descriptor")
	}
	// Darwin SDK pipe_fdinfo: proc_fileinfo(24), vinfo_stat(136),
	// pipe_handle(8), pipe_peerhandle(8), status(4), reserved(4).
	var raw [184]byte
	n, _, errno := unix.Syscall6(unix.SYS_PROC_INFO, 3, uintptr(pid), 6, uintptr(fd), uintptr(unsafe.Pointer(&raw[0])), uintptr(len(raw)))
	runtime.KeepAlive(&raw)
	if errno != 0 {
		return Pipe{}, unavailable(errno)
	}
	if n != uintptr(len(raw)) {
		return Pipe{}, errors.New("incomplete pipe identity")
	}
	flags := binary.LittleEndian.Uint32(raw[:4])
	return Pipe{Handle: binary.LittleEndian.Uint64(raw[160:168]), Peer: binary.LittleEndian.Uint64(raw[168:176]), Readable: flags&1 != 0, Writable: flags&2 != 0}, nil
}
func (r nativeReader) pipes(pid int) (map[int]Pipe, error) {
	if pid <= 1 || pid > 1<<31-1 {
		return nil, errors.New("invalid pid")
	}
	var raw [8192 * 8]byte
	n, _, errno := unix.Syscall6(unix.SYS_PROC_INFO, 2, uintptr(pid), 1, 0, uintptr(unsafe.Pointer(&raw[0])), uintptr(len(raw)))
	runtime.KeepAlive(&raw)
	if errno != 0 {
		return nil, unavailable(errno)
	}
	if n == 0 || n >= uintptr(len(raw)) || n%8 != 0 {
		return nil, errors.New("incomplete descriptor inventory")
	}
	result := map[int]Pipe{}
	for offset := 0; offset < int(n); offset += 8 {
		if binary.LittleEndian.Uint32(raw[offset+4:offset+8]) != 6 {
			continue
		}
		fd := int(int32(binary.LittleEndian.Uint32(raw[offset : offset+4])))
		p, err := r.pipe(pid, fd)
		if err == nil {
			result[fd] = p
		}
	}
	return result, nil
}

func (nativeReader) trustedFrontend(p Process) bool {
	current, err := fileCodeHashes(FrontendPath)
	if err != nil {
		return false
	}
	hash, err := runningCodeHash(p.PID)
	if err != nil {
		return false
	}
	for _, expected := range current {
		if hash == expected {
			return true
		}
	}
	return false
}

// CodeDirectory hashes are compared to the kernel's running-code identity,
// not the pathname of an old frontend retained across an app promotion.
func fileCodeHashes(path string) ([][20]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	image, err := macho.NewFile(f)
	if err != nil {
		return nil, err
	}
	for _, load := range image.Loads {
		raw := load.Raw()
		if len(raw) < 16 || image.ByteOrder.Uint32(raw[:4]) != 0x1d {
			continue
		}
		offset, size := int64(image.ByteOrder.Uint32(raw[8:12])), int64(image.ByteOrder.Uint32(raw[12:16]))
		if size < 12 || size > 1<<20 {
			return nil, errors.New("invalid frontend signature size")
		}
		blob := make([]byte, size)
		if _, err = io.ReadFull(io.NewSectionReader(f, offset, size), blob); err != nil {
			return nil, err
		}
		return signatureCodeHashes(blob)
	}
	return nil, errors.New("frontend code signature unavailable")
}
func signatureCodeHashes(blob []byte) ([][20]byte, error) {
	if len(blob) < 12 || binary.BigEndian.Uint32(blob[:4]) != 0xfade0cc0 {
		return nil, errors.New("invalid frontend signature")
	}
	length := int(binary.BigEndian.Uint32(blob[4:8]))
	if length < 12 || length > len(blob) {
		return nil, errors.New("invalid frontend signature length")
	}
	// LC_CODE_SIGNATURE reserves space which codesign may reuse. Bytes after
	// the embedded SuperBlob's declared length are not part of that signature
	// and may retain nonzero prior data. No index or hash may reach them.
	blob = blob[:length]
	count := int(binary.BigEndian.Uint32(blob[8:12]))
	if count <= 0 || count > 64 || 12+count*8 > len(blob) {
		return nil, errors.New("invalid frontend signature index")
	}
	var result [][20]byte
	for i := 0; i < count; i++ {
		offset := int(binary.BigEndian.Uint32(blob[16+i*8 : 20+i*8]))
		if offset < 12+count*8 || offset > len(blob)-8 {
			return nil, errors.New("invalid code directory offset")
		}
		part := blob[offset:]
		if binary.BigEndian.Uint32(part[:4]) != 0xfade0c02 {
			continue
		}
		size := int(binary.BigEndian.Uint32(part[4:8]))
		if size < 40 || size > len(part) {
			return nil, errors.New("invalid code directory length")
		}
		var h [20]byte
		switch part[37] {
		case 2, 3:
			digest := sha256.Sum256(part[:size])
			copy(h[:], digest[:20])
		case 4:
			digest := sha512.Sum384(part[:size])
			copy(h[:], digest[:20])
		default:
			continue
		}
		result = append(result, h)
	}
	if len(result) == 0 {
		return nil, errors.New("strong frontend code directory unavailable")
	}
	return result, nil
}

func runningCodeHash(pid int) ([20]byte, error) {
	var hash [20]byte
	if pid <= 1 || pid > 1<<31-1 {
		return hash, errors.New("invalid code identity PID")
	}
	_, _, errno := unix.Syscall6(unix.SYS_CSOPS, uintptr(pid), 5, uintptr(unsafe.Pointer(&hash[0])), uintptr(len(hash)), 0, 0)
	runtime.KeepAlive(&hash)
	if errno != 0 {
		return hash, unavailable(errno)
	}
	return hash, nil
}
