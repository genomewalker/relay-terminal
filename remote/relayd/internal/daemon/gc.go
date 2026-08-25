package daemon

import (
	"errors"
	"os"
	"path/filepath"
	"sort"
	"time"
)

const maxGarbageCollectionBatch = 128

// CollectGarbage removes only exited or unvalidated panes older than the
// retention window. A live running shell is never selected based on age.
func (server *Server) CollectGarbage(olderThan time.Duration, dryRun bool) ([]string, error) {
	cutoff := time.Now().UTC().Add(-olderThan)
	server.mu.Lock()
	catalog, err := loadStoredCatalog(server.catalogPath())
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		server.mu.Unlock()
		return nil, err
	}
	if catalog.Panes == nil {
		server.mu.Unlock()
		return nil, nil
	}
	type candidate struct {
		id      string
		updated time.Time
	}
	candidates := make([]candidate, 0)
	for id, pane := range catalog.Panes {
		state := pane.State
		updated := pane.UpdatedAt
		if manifest, loadErr := loadManifest(server.manifestPath(id)); loadErr == nil {
			if validateWorkerIdentity(manifest) == nil {
				state = manifest.State
			} else {
				state = "stale"
			}
			updated = manifest.UpdatedAt
		} else if errors.Is(loadErr, os.ErrNotExist) {
			state = "missing"
		}
		if updated.After(cutoff) || state == "running" {
			continue
		}
		if state == "exited" || state == "stale" || state == "missing" {
			candidates = append(candidates, candidate{id: id, updated: updated})
		}
	}
	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].updated.Equal(candidates[j].updated) {
			return candidates[i].id < candidates[j].id
		}
		return candidates[i].updated.Before(candidates[j].updated)
	})
	if len(candidates) > maxGarbageCollectionBatch {
		candidates = candidates[:maxGarbageCollectionBatch]
	}
	server.mu.Unlock()

	removed := make([]string, 0, len(candidates))
	for _, candidate := range candidates {
		manifestPath := server.manifestPath(candidate.id)
		if manifest, loadErr := loadManifest(manifestPath); loadErr == nil {
			if validateWorkerIdentity(manifest) == nil {
				if manifest.State != "exited" {
					continue
				}
				if dryRun {
					removed = append(removed, candidate.id)
					continue
				}
				server.stopValidatedWorker(manifest)
			} else if !dryRun {
				server.cleanStaleWorker(manifestPath, manifest)
			}
		}
		if dryRun {
			removed = append(removed, candidate.id)
			continue
		}
		server.mu.Lock()
		latest, loadErr := loadStoredCatalog(server.catalogPath())
		if loadErr == nil {
			pane, exists := latest.Panes[candidate.id]
			eligible := exists && !pane.UpdatedAt.After(cutoff) && pane.State != "running"
			if manifest, manifestErr := loadManifest(server.manifestPath(candidate.id)); manifestErr == nil {
				if validateWorkerIdentity(manifest) == nil {
					eligible = manifest.State == "exited" && !manifest.UpdatedAt.After(cutoff)
				} else {
					eligible = !manifest.UpdatedAt.After(cutoff)
				}
			} else if errors.Is(manifestErr, os.ErrNotExist) {
				eligible = exists && !pane.UpdatedAt.After(cutoff)
			}
			if eligible {
				delete(latest.Panes, candidate.id)
				latest.Revision++
				if storeCatalog(server.catalogPath(), latest) == nil {
					removed = append(removed, candidate.id)
				}
			}
		}
		server.mu.Unlock()
	}
	if !dryRun {
		server.removeOrphanedWorkspaceStates(cutoff)
	}
	return removed, nil
}

func (server *Server) removeOrphanedWorkspaceStates(cutoff time.Time) {
	catalog, err := loadStoredCatalog(server.catalogPath())
	if err != nil {
		return
	}
	live := make(map[string]bool)
	for _, pane := range catalog.Panes {
		if pane.WorkspaceID != "" {
			live[pane.WorkspaceID] = true
		}
	}
	paths, _ := filepath.Glob(filepath.Join(server.workspaceStateDirectory(), "*.json"))
	for _, path := range paths {
		info, statErr := os.Stat(path)
		id := filepath.Base(path)
		id = id[:len(id)-len(filepath.Ext(id))]
		if statErr == nil && info.ModTime().Before(cutoff) && !live[id] {
			_ = os.Remove(path)
		}
	}
}
