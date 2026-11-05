package daemon

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const communicationInactiveRetention = 7 * 24 * time.Hour

func communicationLinkActivity(link communicationLink, now time.Time) communicationLink {
	link.LastActivityAt, link.InactiveSince = &now, nil
	return link
}

// A missing renderer or failed endpoint is not evidence of an expired pair.
// A complete local catalogue must positively identify a nonrecoverable member.
// Retained upgrade panes and unknown/cross-host members always hold expiry.
func communicationLinkExpiry(link communicationLink, node string, panes []CatalogPane, now time.Time) (communicationLink, bool) {
	known := make(map[string]CatalogPane, len(panes))
	ambiguous := make(map[string]bool)
	for _, pane := range panes {
		id := strings.ToLower(pane.PaneID)
		if _, exists := known[id]; exists {
			ambiguous[id] = true
		}
		known[id] = pane
	}
	stale := false
	for _, member := range link.Members {
		pane, exists := known[member.PaneID]
		if !exists || ambiguous[member.PaneID] || pane.NodeID != node || pane.Retained {
			link.InactiveSince = nil
			return link, false
		}
		if !pane.Recoverable {
			switch pane.State {
			case "exited", "stale", "missing":
				stale = true
			default:
				link.InactiveSince = nil
				return link, false
			}
		}
	}
	if !stale || now.IsZero() {
		link.InactiveSince = nil
		return link, false
	}
	// Migration starts a new observation window; historical membership age is
	// never treated as a week of continuous observed inactivity.
	if link.InactiveSince == nil || now.Before(*link.InactiveSince) {
		started := now
		link.InactiveSince = &started
		return link, false
	}
	start := *link.InactiveSince
	if link.UpdatedAt.After(start) {
		start = link.UpdatedAt
	}
	if link.LastActivityAt != nil && link.LastActivityAt.After(start) {
		start = *link.LastActivityAt
	}
	return link, !now.Before(start) && now.Sub(start) >= communicationInactiveRetention
}

// Older and foreign records can still be listed, but cannot be expired by this
// policy. Validate identity before any ID becomes part of an archive pathname.
func decodeCommunicationExpiryLink(raw []byte, filename, node string) (communicationLink, bool) {
	var link communicationLink
	if len(raw) > 128<<10 || !rotationSourceJSONUnambiguous(raw) || json.Unmarshal(raw, &link) != nil ||
		link.Version != 1 || node == "" || link.NodeID != node || len(link.Members) != 2 {
		return link, false
	}
	id, members, err := communicationPair(link.Members[0].PaneID, link.Members[1].PaneID)
	if err != nil || link.ID != id || filename != "link-"+id+".json" ||
		link.Members[0].PaneID != members[0] && link.Members[0].PaneID != members[1] ||
		link.Members[1].PaneID != members[0] && link.Members[1].PaneID != members[1] ||
		link.UpdatedAt.IsZero() {
		return link, false
	}
	return link, true
}

func communicationReadExpiryLink(path string) ([]byte, error) {
	if err := privateBindingObject(path, false); err != nil {
		return nil, err
	}
	f, err := OpenPrivateFile(path, os.O_RDONLY)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, (128<<10)+1))
	if err != nil || len(raw) > 128<<10 {
		return nil, errors.New("invalid saved communication link")
	}
	return raw, nil
}

// Called only with the communication flock held, after caller authorization.
// Preflight all files before making changes. Re-read the record AND catalogue
// before each archive so a changed pair or recovered worker cancels expiry.
// History and receipts are separate files and are never touched here.
func communicationMaintainLinks(root, node string, now time.Time, snapshot func() (CatalogSnapshot, error)) error {
	if err := privateBindingObject(root, true); err != nil {
		return err
	}
	paths, err := communicationLinkInventory(root, "", nil)
	if err != nil || len(paths) == 0 {
		return err
	}
	catalog, err := snapshot()
	if err != nil {
		// Catalogue outage is an expiry hold, not a failure to list or add links.
		return nil
	}
	type candidate struct {
		path string
		raw  []byte
		link communicationLink
	}
	work := make([]candidate, 0, len(paths))
	for _, path := range paths {
		raw, err := communicationReadExpiryLink(path)
		if err != nil {
			return err
		}
		link, eligible := decodeCommunicationExpiryLink(raw, filepath.Base(path), node)
		if eligible {
			work = append(work, candidate{path, raw, link})
		}
	}
	for _, item := range work {
		next, expire := communicationLinkExpiry(item.link, node, catalog.Panes, now)
		if expire {
			fresh, err := snapshot()
			if err != nil {
				continue
			}
			raw, err := communicationReadExpiryLink(item.path)
			if err != nil || !bytes.Equal(raw, item.raw) {
				continue
			}
			next, expire = communicationLinkExpiry(item.link, node, fresh.Panes, now)
			if expire {
				// No timestamp suffix: a crash/retry cannot create another archive
				// of the same byte revision. Rename retains its exact bytes.
				archive := filepath.Join(root, ".expired-"+item.link.ID+"-"+communicationExpiryDigest(item.raw)+".json")
				if err := os.Rename(item.path, archive); err != nil {
					return err
				}
				directory, err := os.Open(root)
				if err != nil {
					return err
				}
				err = directory.Sync()
				directory.Close()
				if err != nil {
					return err
				}
				if err := communicationEvent(root, node, "communication_pair_expired", []map[string]string{{"link_id": item.link.ID, "history": "retained", "message_receipts": "retained"}}); err != nil {
					return err
				}
				continue
			}
		}
		// Only lifecycle fields change; membership edits still own UpdatedAt.
		if !sameCommunicationExpiryTime(item.link.InactiveSince, next.InactiveSince) {
			encoded, err := json.Marshal(next)
			if err != nil {
				return err
			}
			if _, err := communicationLinkInventory(root, item.path, encoded); err != nil {
				// Lifecycle metadata must not overflow an existing bounded store.
				continue
			}
			if err := communicationAtomic(item.path, next); err != nil {
				return err
			}
		}
	}
	return nil
}

func communicationExpiryDigest(raw []byte) string {
	digest := sha256.Sum256(raw)
	return hex.EncodeToString(digest[:])
}

func sameCommunicationExpiryTime(a, b *time.Time) bool {
	return a == nil && b == nil || a != nil && b != nil && a.Equal(*b)
}
