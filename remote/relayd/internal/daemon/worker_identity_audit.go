package daemon

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// Read-only upgrade audit: aggregates identity validation without printing
// worker tokens, commands, directories or provider content. Never starts a
// supervisor or a worker; legacy validation performs only a token-bound probe.
func AuditWorkerIdentities() (map[string]int, error) {
	directory := defaultWorkerStateDir()
	entries, err := os.ReadDir(directory)
	if err != nil {
		return nil, err
	}
	if len(entries) > 4096 {
		return nil, errors.New("worker identity ledger exceeds limit")
	}
	report := map[string]int{"records": 0, "valid": 0, "legacy_valid": 0, "refused": 0}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		path := filepath.Join(directory, entry.Name())
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() || info.Size() > 65536 {
			report["refused"]++
			continue
		}
		manifest, err := loadManifest(path)
		if err != nil {
			report["refused"]++
			continue
		}
		report["records"]++
		if err := validateWorkerIdentity(manifest); err != nil {
			report["refused"]++
			continue
		}
		report["valid"]++
		if manifest.WorkerStartTime == uint64(manifest.WorkerPID) && strings.HasPrefix(manifest.NodeBootID, "non-linux:") {
			report["legacy_valid"]++
		}
	}
	return report, nil
}
