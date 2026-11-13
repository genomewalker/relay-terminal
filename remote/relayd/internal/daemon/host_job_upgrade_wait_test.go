package daemon

import (
	"strings"
	"testing"
	"time"
)

// upgrade-supervisor archives with its own, longer ledger wait so a cleanup pass
// in an old supervisor that holds the lock past 30 s does not refuse the upgrade.
func TestUpgradeArchiveWaitsForTheLedgerHolder(t *testing.T) {
	root := t.TempDir()
	old := time.Now().Add(-3 * time.Minute).UTC().Format(time.RFC3339Nano)
	writeArchiveFixture(t, root, hostJobRecord{JobID: "old-exited", State: "exited", UpdatedAt: old})
	writeArchiveFixture(t, root, hostJobRecord{JobID: "old-failed", State: "failed", UpdatedAt: old})
	unlock, err := lockHostJobLedger(root, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := archiveCompletedHostJobsWaiting(root, 0, time.Now().Add(-hostJobArchiveAge), 0); err == nil || !strings.Contains(err.Error(), "busy") {
		t.Fatal("held ledger did not refuse an archive that may not wait", err)
	}
	released := make(chan struct{})
	go func() { time.Sleep(400 * time.Millisecond); unlock(); close(released) }()
	result, err := archiveCompletedHostJobsWaiting(root, 0, time.Now().Add(-hostJobArchiveAge), 5*time.Second)
	<-released
	if err != nil || result.Archived != 2 {
		t.Fatalf("archive did not wait for the ledger holder: %+v %v", result, err)
	}
}
