package daemon

import (
	"crypto/sha256"
	_ "embed"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

//go:embed testdata/maintenance-retirement/relay-arch-launcher.sh
var mrArchLauncher string

func TestNativeMaintenanceOriginalReviewedArchitectureLauncher(t *testing.T) {
	mrEq(t, fmt.Sprintf("%x", sha256.Sum256([]byte(mrArchLauncher))), phRelayArchLauncherSHA256)
	home := mrTempDir(t)
	t.Setenv("HOME", home)
	launcher := phWrite(t, filepath.Join(home, "launcher"), mrArchLauncher, 0700)
	// Both reviewed payloads are private fixtures; installedRelayImage resolves
	// the host's actual architecture without executing either payload or script.
	for _, arch := range []string{"amd64", "arm64"} {
		phWrite(t, home+"/.local/share/relay/bin/relayd-linux-"+arch, "\x7fELFowned-native-helper", 0o700)
	}
	arch := map[string]string{"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}[phMachine()]
	if arch == "" {
		t.Fatal("test host architecture has no reviewed mapping")
	}
	target := home + "/.local/share/relay/bin/relayd-linux-" + arch
	r := newPHReader(nil)
	mrEq(t, r.installedRelayImage(launcher), target)
	if err := os.Chmod(target, 0722); err != nil {
		t.Fatal(err)
	}
	mrRaise(t, "owner controlled", func() { r.installedRelayImage(launcher) })
}
