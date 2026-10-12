package daemon

import (
	"errors"
)

type folderChildStatus struct {
	Path         string `json:"path"`
	State        string `json:"state"`
	Size         int64  `json:"size"`
	SHA256       string `json:"sha256"`
	Offset       int64  `json:"offset"`
	PrefixSHA256 string `json:"prefix_sha256"`
}

// One requested child per response bounds status size independently of the
// whole manifest. No journal, inode, nonce or private stage name is serialized.
func (g *lockedFolderGroup) childStatus(relative string) (*folderChildStatus, error) {
	for _, entry := range g.record.Entries {
		if entry.Path != relative || entry.Kind != "file" {
			continue
		}
		upload, exists := g.record.Uploads[relative]
		result := &folderChildStatus{Path: relative, State: "pending", Size: entry.Size, SHA256: entry.SHA256, PrefixSHA256: folderEmptyDigest()}
		if exists {
			result.State, result.Offset, result.PrefixSHA256 = upload.State, upload.Offset, upload.PrefixSHA256
			if upload.State == "prepared" {
				result.State = "outcome_unknown"
			}
		}
		if receipt := g.record.Files[relative]; receipt.State != "" {
			result.State = receipt.State
		}
		if g.record.State == "cancelled" {
			result.State = "cancelled"
		}
		return result, nil
	}
	return nil, errors.New("exact manifest file required for child status")
}

func (s *Server) hostFolderRPC(r hostRequest) (any, error) {
	if r.Operation == "file_folder_destination" {
		if !validSessionID.MatchString(r.UploadPane) {
			return nil, errors.New("exact live pane required for folder destination")
		}
		parent, err := loadManifest(s.manifestPath(r.UploadPane))
		if err != nil || parent.SessionID != r.UploadPane || validateWorkerIdentity(parent) != nil {
			return nil, errors.New("exact live pane required for folder destination")
		}
		cwd, err := processWorkingDirectory(parent.ShellPID)
		if err != nil || validateWorkerIdentity(parent) != nil {
			return nil, errors.New("cannot resolve live pane folder destination")
		}
		workspace, err := ResolveWorkspace(r.UploadPane, cwd)
		if err != nil {
			return nil, err
		}
		return map[string]any{"pane": r.UploadPane, "path": workspace.Path}, nil
	}
	switch r.Operation {
	case "file_folder_begin", "file_folder_status", "file_folder_chunk", "file_folder_file_commit", "file_folder_commit", "file_folder_cancel", "file_folder_cleanup":
	default:
		return nil, errors.New("unsupported folder operation")
	}
	if r.FolderChild != "" && r.Operation != "file_folder_status" && r.Operation != "file_folder_chunk" && r.Operation != "file_folder_file_commit" {
		return nil, errors.New("child path is only valid for child operations or status")
	}
	g, err := lockFolderGroup(s.stateDir, r.JobID)
	if err != nil {
		return nil, err
	}
	defer g.Close()
	if r.Operation != "file_folder_begin" && r.Operation != "file_folder_cancel" && len(g.durable) == 0 {
		return nil, errors.New("folder group not found")
	}
	switch r.Operation {
	case "file_folder_begin":
		if r.Path == "" {
			return nil, errors.New("explicit folder destination required")
		}
		// Same authenticated host namespace as file uploads. Parent resolution
		// is performed once; later requests always use the journaled parent.
		workspace, err := ResolveWorkspace(r.UploadPane, r.Path)
		if err != nil {
			return nil, err
		}
		if err := g.begin(r.UploadPane, r.FolderSourceVersion, workspace.Path, r.UploadName, r.FolderManifest); err != nil {
			return nil, err
		}
		if g.record.State == "receiving" {
			if err := g.materializeDirectories(); err != nil {
				return nil, err
			}
		}
	case "file_folder_chunk":
		if err := g.childChunk(r.FolderChild, r.Offset, r.Data); err != nil {
			return nil, err
		}
	case "file_folder_file_commit":
		if err := g.commitChild(r.FolderChild); err != nil {
			return nil, err
		}
	case "file_folder_commit":
		if err := g.commit(); err != nil {
			return nil, err
		}
	case "file_folder_cancel":
		if err := g.cancel(); err != nil {
			return nil, err
		}
	case "file_folder_cleanup":
		if err := g.cleanupStaging(); err != nil {
			return nil, err
		}
	}
	result := g.status()
	if r.FolderChild != "" {
		result.Child, err = g.childStatus(r.FolderChild)
		if err != nil {
			return nil, err
		}
	}
	return result, nil
}
