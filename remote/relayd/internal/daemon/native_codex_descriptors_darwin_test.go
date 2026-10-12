//go:build darwin

package daemon

import (
	"context"
	"encoding/binary"
	"os"
	"strings"
	"syscall"
	"testing"
)

func TestDarwinNativeFDRecordBounds(t *testing.T) {
	row := make([]byte, 8)
	binary.LittleEndian.PutUint32(row, 12)
	binary.LittleEndian.PutUint32(row[4:], 1)
	got, err := darwinNativeFDRecords(row)
	if err != nil || len(got) != 1 || got[0] != (darwinNativeFD{12, 1}) {
		t.Fatal("kernel fd fields lost", got, err)
	}
	outOfRange := append([]byte(nil), row...)
	binary.LittleEndian.PutUint32(outOfRange, 4096)
	for name, data := range map[string][]byte{
		"empty": nil, "partial": row[:7], "duplicate": append(append([]byte(nil), row...), row...),
		"out_of_range": outOfRange, "truncated_or_excess": make([]byte, 4097*8),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := darwinNativeFDRecords(data); err == nil {
				t.Fatal("incomplete or ambiguous inventory accepted")
			}
		})
	}
}

func TestDarwinNativeVnodeRecordBounds(t *testing.T) {
	record := func() []byte {
		data := make([]byte, 1200)
		binary.LittleEndian.PutUint32(data[24:], 0x1000014)
		binary.LittleEndian.PutUint16(data[28:], syscall.S_IFREG|0600)
		binary.LittleEndian.PutUint16(data[30:], 1)
		binary.LittleEndian.PutUint64(data[32:], 98765)
		binary.LittleEndian.PutUint32(data[40:], uint32(os.Getuid()))
		copy(data[176:], "/private/tmp/fixture sessions/rollout α.jsonl")
		return data
	}
	want := darwinNativeTranscriptDescriptor{12, "/private/tmp/fixture sessions/rollout α.jsonl", 0x1000014, 98765}
	got, eligible, err := darwinNativeVnodeDescriptor(12, record())
	if err != nil || !eligible || got != want {
		t.Fatal("kernel vnode fields lost", got, eligible, err)
	}
	for name, change := range map[string]func([]byte) []byte{
		"short":      func(d []byte) []byte { return d[:1199] },
		"large":      func(d []byte) []byte { return append(d, 0) },
		"zero_inode": func(d []byte) []byte { binary.LittleEndian.PutUint64(d[32:], 0); return d },
		"other_uid":  func(d []byte) []byte { binary.LittleEndian.PutUint32(d[40:], uint32(os.Getuid()+1)); return d },
		"extra_link": func(d []byte) []byte { binary.LittleEndian.PutUint16(d[30:], 2); return d },
		"relative_path": func(d []byte) []byte {
			copy(d[176:], strings.Repeat("\x00", 1024))
			copy(d[176:], "relative.jsonl")
			return d
		},
		"truncated_path": func(d []byte) []byte { copy(d[176:], strings.Repeat("a", 1024)); return d },
		"invalid_utf8":   func(d []byte) []byte { d[180] = 255; return d },
	} {
		t.Run(name, func(t *testing.T) {
			if _, _, err := darwinNativeVnodeDescriptor(12, change(record())); err == nil {
				t.Fatal("incomplete or unsafe vnode accepted")
			}
		})
	}
	for name, change := range map[string]func([]byte){
		"directory": func(d []byte) { binary.LittleEndian.PutUint16(d[28:], syscall.S_IFDIR|0700) },
		"unrelated": func(d []byte) {
			copy(d[176:], strings.Repeat("\x00", 1024))
			copy(d[176:], "/private/tmp/unrelated.log")
		},
	} {
		t.Run(name, func(t *testing.T) {
			data := record()
			change(data)
			if _, eligible, err := darwinNativeVnodeDescriptor(12, data); err != nil || eligible {
				t.Fatal("unrelated vnode accepted", eligible, err)
			}
		})
	}
}

func TestDarwinNativeKernelDescriptorContextAndIdentity(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := darwinKernelTranscriptDescriptors(ctx, os.Getpid()); err != context.Canceled {
		t.Fatal("cancellation not respected", err)
	}
	if _, err := darwinKernelTranscriptDescriptors(context.Background(), 1); err == nil {
		t.Fatal("invalid native process accepted")
	}
}
