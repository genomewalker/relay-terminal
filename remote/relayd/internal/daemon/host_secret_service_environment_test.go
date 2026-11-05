package daemon

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHostSecretServiceFindsOnlyOwnedPrivateUserBus(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "relay-vault-bus-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)
	listener, err := net.Listen("unix", filepath.Join(root, "bus"))
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if hostVerifiedUserBus(root) != "unix:path="+filepath.Join(root, "bus") {
		t.Fatal("private user socket was not discovered")
	}
	link := root + "-link"
	if err := os.Symlink(root, link); err != nil {
		t.Fatal(err)
	}
	defer os.Remove(link)
	if hostVerifiedUserBus(link) != "" {
		t.Fatal("symlink runtime accepted")
	}
	if err := os.Chmod(root, 0755); err != nil {
		t.Fatal(err)
	}
	if hostVerifiedUserBus(root) != "" {
		t.Fatal("public runtime directory accepted")
	}
}

func TestHostSecretServiceEnvironmentDoesNotPassProviderSecrets(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "relay-vault-env-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)
	listener, err := net.Listen("unix", filepath.Join(root, "bus"))
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	t.Setenv("XDG_RUNTIME_DIR", root)
	t.Setenv("DBUS_SESSION_BUS_ADDRESS", "")
	t.Setenv("ANTHROPIC_API_KEY", "FIXTURE_ONLY_MUST_NOT_PASS_TO_CHILD")
	values := map[string]string{}
	for _, pair := range hostSecretServiceEnvironment() {
		parts := strings.SplitN(pair, "=", 2)
		values[parts[0]] = parts[1]
	}
	if values["DBUS_SESSION_BUS_ADDRESS"] != "unix:path="+filepath.Join(root, "bus") || values["ANTHROPIC_API_KEY"] != "" {
		t.Fatal("headless discovery failed or provider environment was copied")
	}
	t.Setenv("DBUS_SESSION_BUS_ADDRESS", "unix:path=/explicit/owned/bus")
	if !strings.Contains(strings.Join(hostSecretServiceEnvironment(), "\n"), "DBUS_SESSION_BUS_ADDRESS=unix:path=/explicit/owned/bus") {
		t.Fatal("explicit user bus was replaced")
	}
}
