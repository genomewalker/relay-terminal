package daemon

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// Pair links grow as n*(n-1)/2. The former 256-record cap was shared
// by every workspace on a host. Keep a finite count and a tighter byte
// budget so more workspaces can coexist without oversized RPC responses.
const communicationLinkLimit = 4096
const communicationLinkListBytes = 8 << 20
const communicationLinkStorageBytes = communicationLinkListBytes - (64 << 10)

// Called while Communication holds the existing daemon communication flock.
// replacement is a prospective canonical JSON record, never written here.
// Reads, updates and insertions share the same limits; receipts are untouched.
func communicationLinkInventory(root, replacementPath string, replacement []byte) ([]string, error) {
	paths, err := filepath.Glob(filepath.Join(root, "link-*.json"))
	if err != nil {
		return nil, err
	}
	found := false
	var total int64
	for _, path := range paths {
		if err := privateBindingObject(path, false); err != nil {
			return nil, err
		}
		info, err := os.Lstat(path)
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsRegular() || info.Size() > 128<<10 {
			return nil, errors.New("invalid saved communication link")
		}
		if path == replacementPath {
			found = true
			continue
		}
		total += info.Size()
		if total > communicationLinkStorageBytes {
			return nil, errors.New("saved links exceed the 8 MiB response budget; existing links retained")
		}
	}
	count := len(paths)
	if replacementPath != "" {
		if filepath.Dir(replacementPath) != filepath.Clean(root) || len(replacement) > 128<<10 {
			return nil, errors.New("invalid replacement communication link")
		}
		if !found {
			count++
		}
		total += int64(len(replacement))
	}
	if count > communicationLinkLimit {
		return nil, fmt.Errorf("saved link capacity reached (%d); existing links retained", communicationLinkLimit)
	}
	if total > communicationLinkStorageBytes {
		return nil, errors.New("saved links exceed the 8 MiB response budget; existing links retained")
	}
	return paths, nil
}
