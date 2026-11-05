package agentaccounts

import (
	"os"
	"testing"
)

func TestReviewerRepairMakesRecognizedLauncherExecutable(t *testing.T) {
	host := LauncherHost{Home: t.TempDir(), GOOS: "darwin", Relayd: macBundleRelayd}
	path := writeLauncherFile(t, host, "claude", LauncherContent("claude", macBundleRelayd))
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	statuses := RepairLaunchers(host)
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm()&0100 == 0 {
		t.Fatalf("repair reports %s for an owner-non-executable managed launcher; mode=%04o", launcherStates(statuses)["claude"], info.Mode().Perm())
	}
}
