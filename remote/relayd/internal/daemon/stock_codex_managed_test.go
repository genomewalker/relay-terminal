package daemon

import (
	"net"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/relay-terminal/relayd/internal/agentlaunch"
)

func TestManagedStockCodexMakesOnlyItsOwnedBackendSocketPrivate(t *testing.T) {
	// t.TempDir paths exceed the macOS unix socket path limit.
	dir, err := os.MkdirTemp("/tmp", "rcx-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "server.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err := os.Chmod(path, 0666); err != nil {
		t.Fatal(err)
	}
	if err := privateManagedCodexBackendSocket(path); err != nil {
		t.Fatal(err)
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0600 {
		t.Fatal("backend socket stayed public")
	}
	regular := filepath.Join(dir, "regular")
	if err := os.WriteFile(regular, []byte("fixture"), 0644); err != nil {
		t.Fatal(err)
	}
	if privateManagedCodexBackendSocket(regular) == nil {
		t.Fatal("regular file accepted as backend socket")
	}
	link := filepath.Join(dir, "link.sock")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if privateManagedCodexBackendSocket(link) == nil {
		t.Fatal("linked socket accepted")
	}
}

func TestManagedCodexBackendAppliesOnlyValidatedSavedPermissions(t *testing.T) {
	saved := agentlaunch.CodexPermissions{SandboxMode: "danger-full-access", ApprovalPolicy: "never"}
	got := managedCodexBackendArguments("/tmp/s.sock", saved)
	expected := []string{"app-server", "--listen", "unix:///tmp/s.sock", "-c", `sandbox_mode="danger-full-access"`, "-c", `approval_policy="never"`}
	if !reflect.DeepEqual(got, expected) {
		t.Fatalf("got %q", got)
	}
	for _, permissions := range []agentlaunch.CodexPermissions{{}, {SandboxMode: "danger-full-access"}, {SandboxMode: "none", ApprovalPolicy: "never"}} {
		if got := managedCodexBackendArguments("/tmp/s.sock", permissions); !reflect.DeepEqual(got, expected[:3]) {
			t.Fatalf("%#v: got %q", permissions, got)
		}
	}
}
