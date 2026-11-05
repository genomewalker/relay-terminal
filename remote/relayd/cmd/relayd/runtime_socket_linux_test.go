//go:build linux

package main

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

func TestDefaultSocketAdoptsOnlyTheProbedRuntime(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", "")
	t.Setenv("HOME", "/shared/home/test")
	saved := defaultSocketRuntimeProbe
	t.Cleanup(func() { defaultSocketRuntimeProbe = saved })
	uid := os.Getuid()
	wantDirectory := filepath.Join("/run/user", strconv.Itoa(uid))
	wantSocket := filepath.Join(wantDirectory, "relayd.sock")
	calls := 0
	defaultSocketRuntimeProbe = func(directory string, owner int) string {
		calls++
		if directory != wantDirectory || owner != uid {
			t.Fatal("SOCKET_DISCOVERY_WRONG_RUNTIME_OR_OWNER")
		}
		return wantSocket
	}
	if got := defaultSocket(); got != wantSocket || calls != 1 {
		t.Fatalf("SOCKET_EXISTING_RUNTIME_NOT_ADOPTED: socket=%q calls=%d", got, calls)
	}
	// An explicitly supplied runtime wins without consulting another socket.
	t.Setenv("XDG_RUNTIME_DIR", "/tmp/explicit-private-runtime")
	if got := defaultSocket(); got != "/tmp/explicit-private-runtime/relayd.sock" || calls != 1 {
		t.Fatalf("SOCKET_EXPLICIT_RUNTIME_LOST: socket=%q calls=%d", got, calls)
	}
}
