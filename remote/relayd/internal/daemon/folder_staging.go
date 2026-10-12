package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
)

func folderStagingName(id string) string {
	sum := sha256.Sum256([]byte(id))
	return ".relay-folder-stage-" + hex.EncodeToString(sum[:16])
}

// A private sibling directory shares the destination parent filesystem while
// keeping partial bytes outside the manifest tree. Its exact name is journaled
// before reservation and collisions never choose another hidden name.
// Caller keeps the group lock through all child operations using the returned
// descriptor. Stage lifetime/cleanup is separate from committed file lifetime.
func (g *lockedFolderGroup) openStagingDirectory() (*os.File, error) {
	if g.lock == nil || g.uncertain || g.record.State != "receiving" {
		return nil, errors.New("receiving folder group and active lock required for staging")
	}
	root, err := g.openReservedDirectory()
	if err != nil {
		return nil, err
	}
	root.Close()
	r := g.record.Reservation
	if g.record.Staging == nil {
		g.record.Staging = &folderReservation{Format: 1, ID: r.ID, Fingerprint: r.Fingerprint, Parent: r.Parent, ParentIdentity: r.ParentIdentity, Name: folderStagingName(r.ID), State: "prepared"}
		if err := g.save(); err != nil {
			return nil, err
		}
	}
	catalog := filepath.Join(g.root, "staging-reservations")
	if g.record.Staging.State == "prepared" {
		stage := g.record.Staging
		reserved, err := reserveFolder(catalog, stage.ID, stage.Parent, stage.Name, stage.Fingerprint, stage.ParentIdentity)
		if err != nil {
			return nil, err
		}
		g.record.Staging = &reserved
		if err := g.save(); err != nil {
			return nil, err
		}
	}
	return openVerifiedFolderReservation(catalog, *g.record.Staging)
}
