package daemon

import (
	"encoding/json"
	"errors"
	"os"
	"strings"
)

// PreserveCatalogSnapshot durably retains safe metadata from an earlier helper.
// The upgrade coordinator must exclude every other catalog writer while calling
// this offline operation. It never adopts PIDs, creates workers or changes an
// existing entry. CatalogSnapshot independently validates live worker manifests.
func ValidateCatalogSnapshot(snapshot CatalogSnapshot) error {
	nodeID, _ := currentNodeIdentity()
	if snapshot.Schema != catalogSchemaVersion || snapshot.NodeID != nodeID || len(snapshot.Panes) > 4096 {
		return errors.New("bounded same-node catalog snapshot required")
	}
	encoded, err := json.Marshal(snapshot)
	if err != nil || len(encoded) > 8<<20 {
		return errors.New("bounded catalog metadata required")
	}
	seen := make(map[string]bool, len(snapshot.Panes))
	for _, pane := range snapshot.Panes {
		if pane.NodeID != nodeID || !validSessionID.MatchString(pane.PaneID) || seen[pane.PaneID] || pane.WorkerPID < 0 || pane.ShellPID < 0 || pane.CreatedAt.IsZero() || pane.UpdatedAt.IsZero() {
			return errors.New("valid unique same-node pane receipt required")
		}
		for _, value := range []string{pane.WorkspaceID, pane.TabID, pane.ParentPaneID, pane.Title, pane.ContentKind, pane.Command, pane.Directory, pane.State} {
			if len(value) > 65536 || strings.ContainsRune(value, 0) {
				return errors.New("bounded pane metadata required")
			}
		}
		seen[pane.PaneID] = true
	}
	return nil
}

func (server *Server) PreserveCatalogSnapshot(snapshot CatalogSnapshot) error {
	if err := ValidateCatalogSnapshot(snapshot); err != nil {
		return err
	}
	server.mu.Lock()
	defer server.mu.Unlock()
	catalog, err := loadStoredCatalog(server.catalogPath())
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if catalog.Panes == nil {
		catalog = storedCatalog{Schema: catalogSchemaVersion, Panes: make(map[string]CatalogPane)}
	}
	changed := false
	for _, pane := range snapshot.Panes {
		if current, exists := catalog.Panes[pane.PaneID]; exists {
			if !current.Retained {
				current.Retained = true
				catalog.Panes[pane.PaneID] = current
				changed = true
			}
			continue
		}
		// Saved PID values are historical metadata, never proof of recoverability.
		pane.Recoverable = false
		pane.Retained = true
		if pane.State == "running" {
			pane.State = "missing"
		}
		pane.Unfiled = pane.WorkspaceID == "" || pane.TabID == ""
		catalog.Panes[pane.PaneID] = pane
		changed = true
	}
	if !changed {
		return nil
	}
	merged, err := json.Marshal(catalog)
	if err != nil || len(catalog.Panes) > 4096 || len(merged) > 8<<20 {
		return errors.New("merged catalog exceeds bound")
	}
	if catalog.Revision == ^uint64(0) {
		return errors.New("catalog revision exhausted")
	}
	catalog.Revision++
	return storeCatalog(server.catalogPath(), catalog)
}
