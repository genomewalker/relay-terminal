package daemon

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

const catalogSchemaVersion = 1

// CatalogSnapshot is safe to return to an untrusted local client: worker
// tokens and private socket paths never leave relayd's state directory.
type CatalogSnapshot struct {
	Schema      int           `json:"schema"`
	Revision    uint64        `json:"revision"`
	NodeID      string        `json:"node_id"`
	NodeName    string        `json:"node_name"`
	GeneratedAt time.Time     `json:"generated_at"`
	Panes       []CatalogPane `json:"panes"`
}

type CatalogPane struct {
	NodeID            string    `json:"node_id"`
	PaneID            string    `json:"pane_id"`
	WorkspaceID       string    `json:"workspace_id,omitempty"`
	TabID             string    `json:"tab_id,omitempty"`
	ParentPaneID      string    `json:"parent_pane_id,omitempty"`
	Title             string    `json:"title,omitempty"`
	ContentKind       string    `json:"content_kind"`
	Command           string    `json:"command,omitempty"`
	Directory         string    `json:"directory,omitempty"`
	State             string    `json:"state"`
	WorkerPID         int       `json:"worker_pid,omitempty"`
	ShellPID          int       `json:"shell_pid,omitempty"`
	LastSequence      uint64    `json:"last_sequence"`
	LastEventSequence uint64    `json:"last_event_sequence"`
	CreatedAt         time.Time `json:"created_at"`
	UpdatedAt         time.Time `json:"updated_at"`
	Recoverable       bool      `json:"recoverable"`
	Unfiled           bool      `json:"unfiled"`
}

type storedCatalog struct {
	Schema   int                    `json:"schema"`
	Revision uint64                 `json:"revision"`
	Panes    map[string]CatalogPane `json:"panes"`
}

func (server *Server) catalogPath() string {
	nodeID, _ := currentNodeIdentity()
	return filepath.Join(filepath.Dir(server.stateDir), "catalog-"+nodeID+".json")
}

func (server *Server) recordCatalogEntry(hello protocol.HelloPayload, manifest workerManifest) error {
	server.mu.Lock()
	defer server.mu.Unlock()
	catalog, err := loadStoredCatalog(server.catalogPath())
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if catalog.Panes == nil {
		catalog = storedCatalog{Schema: catalogSchemaVersion, Panes: make(map[string]CatalogPane)}
	}
	entry := catalog.Panes[manifest.SessionID]
	entry = mergeManifest(entry, manifest)
	entry.NodeID, _ = currentNodeIdentity()
	if hello.WorkspaceID != "" {
		entry.WorkspaceID = hello.WorkspaceID
	}
	if hello.TabID != "" {
		entry.TabID = hello.TabID
	}
	if hello.ParentSessionID != "" {
		entry.ParentPaneID = hello.ParentSessionID
	}
	if hello.PaneTitle != "" {
		entry.Title = hello.PaneTitle
	}
	if hello.ContentKind != "" {
		entry.ContentKind = hello.ContentKind
	}
	entry.Unfiled = entry.WorkspaceID == "" || entry.TabID == ""
	catalog.Panes[manifest.SessionID] = entry
	catalog.Schema = catalogSchemaVersion
	catalog.Revision++
	return storeCatalog(server.catalogPath(), catalog)
}

func (server *Server) CatalogSnapshot() (CatalogSnapshot, error) {
	nodeID, nodeName := currentNodeIdentity()
	catalog, err := loadStoredCatalog(server.catalogPath())
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return CatalogSnapshot{}, err
	}
	if catalog.Panes == nil {
		catalog = storedCatalog{Schema: catalogSchemaVersion, Panes: make(map[string]CatalogPane)}
	}

	manifestPaths, err := filepath.Glob(filepath.Join(server.stateDir, "*.json"))
	if err != nil {
		return CatalogSnapshot{}, err
	}
	seen := make(map[string]bool, len(manifestPaths))
	for _, path := range manifestPaths {
		manifest, loadErr := loadManifest(path)
		if loadErr != nil {
			continue
		}
		entry := mergeManifest(catalog.Panes[manifest.SessionID], manifest)
		entry.Recoverable = validateWorkerIdentity(manifest) == nil
		if !entry.Recoverable && entry.NodeID != nodeID {
			continue
		}
		entry.NodeID = nodeID
		if !entry.Recoverable && entry.State == "running" {
			entry.State = "stale"
		}
		entry.Unfiled = entry.WorkspaceID == "" || entry.TabID == ""
		catalog.Panes[manifest.SessionID] = entry
		seen[manifest.SessionID] = true
	}

	panes := make([]CatalogPane, 0, len(catalog.Panes))
	for id, pane := range catalog.Panes {
		if !seen[id] {
			pane.Recoverable = false
			if pane.State == "running" {
				pane.State = "missing"
			}
		}
		panes = append(panes, pane)
	}
	sort.Slice(panes, func(i, j int) bool {
		if panes[i].UpdatedAt.Equal(panes[j].UpdatedAt) {
			return panes[i].PaneID < panes[j].PaneID
		}
		return panes[i].UpdatedAt.After(panes[j].UpdatedAt)
	})
	return CatalogSnapshot{
		Schema: catalogSchemaVersion, Revision: catalog.Revision, NodeID: nodeID, NodeName: nodeName,
		GeneratedAt: time.Now().UTC(), Panes: panes,
	}, nil
}

func currentNodeIdentity() (string, string) {
	hostname, err := os.Hostname()
	if err != nil || strings.TrimSpace(hostname) == "" {
		hostname = "unknown-node"
	}
	hostname = strings.ToLower(strings.TrimSpace(hostname))
	digest := sha256.Sum256([]byte(hostname + ":" + strconv.Itoa(os.Getuid())))
	return fmt.Sprintf("%x", digest[:8]), hostname
}

func mergeManifest(entry CatalogPane, manifest workerManifest) CatalogPane {
	entry.PaneID = manifest.SessionID
	if entry.ContentKind == "" {
		entry.ContentKind = "terminal"
	}
	entry.Command = manifest.Command
	entry.Directory = manifest.WorkingDirectory
	entry.State = manifest.State
	entry.WorkerPID = manifest.WorkerPID
	entry.ShellPID = manifest.ShellPID
	entry.LastSequence = manifest.LastSequence
	entry.LastEventSequence = manifest.LastEventSequence
	if entry.CreatedAt.IsZero() {
		entry.CreatedAt = manifest.CreatedAt
	}
	entry.UpdatedAt = manifest.UpdatedAt
	return entry
}

func loadStoredCatalog(path string) (storedCatalog, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return storedCatalog{}, err
	}
	var catalog storedCatalog
	if err := json.Unmarshal(data, &catalog); err != nil {
		return storedCatalog{}, err
	}
	if catalog.Schema != catalogSchemaVersion {
		return storedCatalog{}, errors.New("unsupported Relay catalog schema")
	}
	return catalog, nil
}

func storeCatalog(path string, catalog storedCatalog) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(catalog, "", "  ")
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".catalog-*.json")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	remove := true
	defer func() {
		_ = temporary.Close()
		if remove {
			_ = os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(0o600); err != nil {
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		return err
	}
	if err := temporary.Sync(); err != nil {
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return err
	}
	remove = false
	return nil
}
