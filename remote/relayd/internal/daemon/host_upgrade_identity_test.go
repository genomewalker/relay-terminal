package daemon

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestHostUpgradeReservationIncarnation(t *testing.T) {
	start, err := processStartIdentity(os.Getpid())
	if err != nil || start == "" {
		t.Fatalf("current kernel identity: %q %v", start, err)
	}
	for _, tc := range []struct {
		name, start    string
		tracked, allow bool
	}{
		{"matching-live", start, false, false},
		{"unrecorded-live", "", false, false},
		{"replaced", "a conclusively different recorded incarnation", false, true},
		{"tracked-running-replacement", "a conclusively different recorded incarnation", true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := &Server{stateDir: t.TempDir()}
			record := hostJobRecord{JobID: "job-test", State: "running", PID: os.Getpid(), ProcessStart: tc.start}
			dir := filepath.Join(s.stateDir, "host-jobs", record.JobID)
			if err := os.MkdirAll(dir, 0700); err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(dir, "record.json")
			data, err := json.Marshal(record)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, data, 0600); err != nil {
				t.Fatal(err)
			}
			if tc.tracked {
				s.hostJobs.Store(record.JobID, &hostJob{record: record})
			}
			err = s.prepareHostUpgrade()
			if (err == nil) != tc.allow {
				t.Fatalf("allow=%v, err=%v", tc.allow, err)
			}
			if s.hostUpgradeUntil.IsZero() == tc.allow {
				t.Fatal("handoff barrier does not match decision")
			}
			after, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(data, after) {
				t.Fatal("upgrade changed unknown execution outcome or ledger")
			}
		})
	}
}

func TestHostJobProcessStateIdentityProbeFailures(t *testing.T) {
	for _, tc := range []struct {
		name                    string
		probeErr, errorIdentity error
		recorded, current, want string
	}{
		{name: "permission", probeErr: syscall.EPERM, recorded: "old", current: "new", want: "unknown"},
		{name: "probe-unknown", probeErr: syscall.EIO, recorded: "old", current: "new", want: "unknown"},
		{name: "identity-unreadable", errorIdentity: errors.New("unreadable"), recorded: "old", want: "unknown"},
		{name: "identity-empty", recorded: "old", want: "unknown"},
		{name: "unrecorded", current: "new", want: "unknown"},
		{name: "matching", recorded: "old", current: "old", want: "alive"},
		{name: "replacement", recorded: "old", current: "new", want: "replaced"},
		{name: "absent", probeErr: syscall.ESRCH, recorded: "old", want: "absent"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			record := hostJobRecord{State: "running", PID: 123, ProcessStart: tc.recorded}
			got := hostJobProcessStateWith(record, func(pid int, sig syscall.Signal) error {
				if pid != record.PID || sig != 0 {
					t.Fatal("probe must never signal")
				}
				return tc.probeErr
			}, func(pid int) (string, error) {
				if pid != record.PID {
					t.Fatal("wrong identity PID")
				}
				return tc.current, tc.errorIdentity
			})
			if got != tc.want {
				t.Fatalf("state=%q, want %q", got, tc.want)
			}
		})
	}
}
