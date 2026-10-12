//go:build linux

package daemon

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

type linuxUnixSocket struct {
	inode, peer, uid uint32
	cookie           uint64
	path             string
}

func nativeProcRead(path string, limit int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil || int64(len(data)) > limit {
		return nil, errors.New("native proc read exceeded limit")
	}
	return data, nil
}
func linuxProcessSocketInodes(pid int) (map[uint32]bool, error) {
	directory := fmt.Sprintf("/proc/%d/fd", pid)
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) > 4096 {
		return nil, errors.New("native file descriptor inventory unavailable")
	}
	result := map[uint32]bool{}
	for _, entry := range entries {
		target, err := os.Readlink(filepath.Join(directory, entry.Name()))
		if err != nil {
			continue
		}
		if !strings.HasPrefix(target, "socket:[") || !strings.HasSuffix(target, "]") {
			continue
		}
		inode, err := strconv.ParseUint(strings.TrimSuffix(strings.TrimPrefix(target, "socket:["), "]"), 10, 32)
		if err == nil {
			result[uint32(inode)] = true
		}
	}
	return result, nil
}

// Query one exact inode using SOCK_DIAG_BY_FAMILY and UDIAG_SHOW_PEER/NAME/UID.
// This avoids a host-wide socket dump and obtains peer identities from Linux.
func linuxUnixSocketIdentity(ctx context.Context, inode uint32) (linuxUnixSocket, bool, error) {
	var empty linuxUnixSocket
	fd, err := unix.Socket(unix.AF_NETLINK, unix.SOCK_RAW|unix.SOCK_CLOEXEC, unix.NETLINK_SOCK_DIAG)
	if err != nil {
		return empty, false, err
	}
	defer unix.Close(fd)
	if err = unix.Bind(fd, &unix.SockaddrNetlink{Family: unix.AF_NETLINK}); err != nil {
		return empty, false, err
	}
	packet := make([]byte, 40)
	binary.NativeEndian.PutUint32(packet[0:4], 40)
	binary.NativeEndian.PutUint16(packet[4:6], 20)
	binary.NativeEndian.PutUint16(packet[6:8], unix.NLM_F_REQUEST)
	binary.NativeEndian.PutUint32(packet[8:12], 1)
	packet[16] = unix.AF_UNIX
	binary.NativeEndian.PutUint32(packet[20:24], 0xffffffff)
	binary.NativeEndian.PutUint32(packet[24:28], inode)
	binary.NativeEndian.PutUint32(packet[28:32], 0x45)
	binary.NativeEndian.PutUint32(packet[32:36], 0xffffffff)
	binary.NativeEndian.PutUint32(packet[36:40], 0xffffffff)
	if err = unix.Sendto(fd, packet, 0, &unix.SockaddrNetlink{Family: unix.AF_NETLINK}); err != nil {
		return empty, false, err
	}
	timeout := 1000
	if deadline, ok := ctx.Deadline(); ok {
		left := time.Until(deadline).Milliseconds()
		if left <= 0 {
			return empty, false, context.DeadlineExceeded
		}
		if left < int64(timeout) {
			timeout = int(left)
		}
	}
	descriptors := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}
	if count, e := unix.Poll(descriptors, timeout); e != nil || count != 1 {
		return empty, false, errors.New("native Unix peer query timed out")
	}
	buffer := make([]byte, 65536)
	count, _, flags, address, err := unix.Recvmsg(fd, buffer, nil, 0)
	if err != nil || flags&unix.MSG_TRUNC != 0 {
		return empty, false, errors.New("native Unix peer response unavailable")
	}
	from, ok := address.(*unix.SockaddrNetlink)
	if !ok || from.Pid != 0 {
		return empty, false, errors.New("native Unix peer response is not from kernel")
	}
	messages, err := syscall.ParseNetlinkMessage(buffer[:count])
	if err != nil {
		return empty, false, err
	}
	for _, message := range messages {
		if message.Header.Seq != 1 {
			continue
		}
		if message.Header.Type == unix.NLMSG_ERROR {
			if len(message.Data) < 4 {
				return empty, false, errors.New("short native Unix peer error")
			}
			code := int32(binary.NativeEndian.Uint32(message.Data[:4]))
			if code == -int32(unix.ENOENT) {
				return empty, false, nil
			}
			return empty, false, fmt.Errorf("native Unix peer query rejected: %d", code)
		}
		if message.Header.Type != 20 || len(message.Data) < 16 || message.Data[0] != unix.AF_UNIX {
			continue
		}
		data := message.Data
		row := linuxUnixSocket{inode: binary.NativeEndian.Uint32(data[4:8]), cookie: binary.NativeEndian.Uint64(data[8:16]), uid: 0xffffffff}
		for offset := 16; offset+4 <= len(data); {
			length := int(binary.NativeEndian.Uint16(data[offset : offset+2]))
			kind := binary.NativeEndian.Uint16(data[offset+2:offset+4]) & 0x3fff
			if length < 4 || offset+length > len(data) {
				return empty, false, errors.New("invalid native Unix peer attribute")
			}
			value := data[offset+4 : offset+length]
			switch kind {
			case 0:
				if len(value) > 0 && value[0] != 0 {
					row.path = strings.TrimRight(string(value), "\x00")
				}
			case 2:
				if len(value) == 4 {
					row.peer = binary.NativeEndian.Uint32(value)
				}
			case 7:
				if len(value) == 4 {
					row.uid = binary.NativeEndian.Uint32(value)
				}
			}
			offset += (length + 3) &^ 3
		}
		if row.inode != inode {
			return empty, false, errors.New("native Unix socket identity mismatch")
		}
		// Older kernels omit UNIX_DIAG_UID. Ownership is independently proved
		// by the pinned process's /proc fd inventory and final SO_PEERCRED.
		if row.uid != 0xffffffff && row.uid != uint32(os.Getuid()) {
			return empty, false, nil
		}
		return row, true, nil
	}
	return empty, false, errors.New("native Unix peer response missing")
}

func nativeCodexEndpoint(ctx context.Context, frontend int) (NativeCodexEndpoint, error) {
	var empty NativeCodexEndpoint
	processInfo, e := os.Stat(fmt.Sprintf("/proc/%d", frontend))
	if e != nil {
		return empty, e
	}
	owner, ok := processInfo.Sys().(*syscall.Stat_t)
	if !ok || int(owner.Uid) != os.Getuid() {
		return empty, errors.New("native frontend kernel owner mismatch")
	}
	selfNS, err := os.Readlink("/proc/self/ns/net")
	if err != nil {
		return empty, err
	}
	frontendNS, err := os.Readlink(fmt.Sprintf("/proc/%d/ns/net", frontend))
	if err != nil || frontendNS != selfNS {
		return empty, errors.New("native frontend network namespace differs")
	}
	frontendStart, err := processStartTime(frontend)
	if err != nil {
		return empty, err
	}
	inodes, err := linuxProcessSocketInodes(frontend)
	if err != nil {
		return empty, err
	}
	type link struct{ front, server linuxUnixSocket }
	links := map[uint32]link{}
	for inode := range inodes {
		row, found, e := linuxUnixSocketIdentity(ctx, inode)
		if e != nil {
			return empty, e
		}
		if !found || row.peer == 0 {
			continue
		}
		peer, found, e := linuxUnixSocketIdentity(ctx, row.peer)
		if e != nil {
			return empty, e
		}
		if found && peer.peer == inode && filepath.IsAbs(peer.path) {
			links[peer.inode] = link{row, peer}
		}
	}
	if len(links) == 0 {
		return empty, errors.New("native frontend has no named Unix daemon peer")
	}
	entries, err := os.ReadDir("/proc")
	if err != nil || len(entries) > 32768 {
		return empty, errors.New("native process inventory unavailable")
	}
	matches := map[string]NativeCodexEndpoint{}
	candidateCount := 0
	for _, entry := range entries {
		pid, e := strconv.Atoi(entry.Name())
		if e != nil || pid == frontend {
			continue
		}
		info, e := os.Stat(filepath.Join("/proc", entry.Name()))
		if e != nil {
			continue
		}
		procStat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || int(procStat.Uid) != os.Getuid() {
			continue
		}
		comm, e := nativeProcRead(filepath.Join("/proc", entry.Name(), "comm"), 256)
		if e != nil || strings.TrimSpace(string(comm)) != "codex" {
			continue
		}
		candidateCount++
		if candidateCount > 64 {
			return empty, errors.New("native Codex inventory exceeds limit")
		}
		before, e := processStartTime(pid)
		if e != nil {
			continue
		}
		owned, e := linuxProcessSocketInodes(pid)
		if e != nil {
			continue
		}
		for inode, pair := range links {
			if !owned[inode] {
				continue
			}
			socket, e := os.Lstat(pair.server.path)
			if e != nil || socket.Mode()&os.ModeSocket == 0 {
				continue
			}
			socketStat, ok := socket.Sys().(*syscall.Stat_t)
			if !ok || int(socketStat.Uid) != os.Getuid() {
				continue
			}
			parent, e := os.Lstat(filepath.Dir(pair.server.path))
			if e != nil || !parent.IsDir() || parent.Mode().Perm()&0077 != 0 {
				continue
			}
			parentStat, ok := parent.Sys().(*syscall.Stat_t)
			if !ok || int(parentStat.Uid) != os.Getuid() {
				continue
			}
			after, e := processStartTime(pid)
			if e != nil || after != before {
				continue
			}
			endpoint := NativeCodexEndpoint{Socket: pair.server.path, DaemonPID: pid, DaemonStart: before, Device: uint64(socketStat.Dev), Inode: socketStat.Ino,
				FrontendSocket: fmt.Sprintf("%d:%d", pair.front.inode, pair.front.cookie), DaemonSocket: fmt.Sprintf("%d:%d", pair.server.inode, pair.server.cookie)}
			matches[fmt.Sprintf("%d:%s", pid, pair.server.path)] = endpoint
		}
	}
	if len(matches) != 1 {
		return empty, errors.New("native frontend has no unique kernel daemon socket")
	}
	var endpoint NativeCodexEndpoint
	for _, value := range matches {
		endpoint = value
	}
	data, err := nativeProcRead(fmt.Sprintf("/proc/%d/net/tcp", frontend), 1<<20)
	if err != nil {
		return empty, err
	}
	origins := map[string]bool{}
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 10 || fields[3] != "0A" {
			continue
		}
		inode, e := strconv.ParseUint(fields[9], 10, 32)
		if e != nil || !inodes[uint32(inode)] {
			continue
		}
		host, portText, ok := strings.Cut(fields[1], ":")
		if !ok || host != "0100007F" {
			continue
		}
		port, e := strconv.ParseUint(portText, 16, 16)
		if e == nil && port > 0 {
			origins["http://127.0.0.1:"+strconv.FormatUint(port, 10)] = true
		}
	}
	if len(origins) != 1 {
		return empty, errors.New("native frontend has no unique loopback listener")
	}
	for origin := range origins {
		endpoint.Origin = origin
	}
	if current, e := processStartTime(frontend); e != nil || current != frontendStart {
		return empty, errors.New("native frontend changed during kernel discovery")
	}
	return endpoint, nil
}
