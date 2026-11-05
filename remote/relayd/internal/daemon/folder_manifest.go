package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"path"
	"sort"
	"strings"
	"unicode/utf8"
)

// Directories, including empty directories, are explicit entries. Symlinks and
// special files are deliberately absent from this protocol.
type folderEntry struct {
	Path   string `json:"path"`
	Kind   string `json:"kind"`
	Size   int64  `json:"size,omitempty"`
	SHA256 string `json:"sha256,omitempty"`
}

const folderOwnerMarker = ".relay-folder-owner"

func folderChildName(name string) bool {
	return name != "" && name != "." && name != ".." && len(name) <= 240 && utf8.ValidString(name) && !strings.ContainsAny(name, "/\\\x00")
}

// Canonical order makes resume independent of filesystem enumeration order.
// Parents must be declared so materialization never invents a directory tree.
func canonicalFolderManifest(entries []folderEntry) ([]folderEntry, string, error) {
	if len(entries) > 1024 {
		return nil, "", errors.New("folder manifest exceeds 1024 entries")
	}
	result := append([]folderEntry{}, entries...)
	seen := make(map[string]string, len(result))
	var total int64
	for i := range result {
		e := &result[i]
		parts := strings.Split(e.Path, "/")
		if len(e.Path) > 1024 || len(parts) > 32 || parts[0] == folderOwnerMarker {
			return nil, "", errors.New("folder path exceeds bounds or uses reserved marker")
		}
		for _, component := range parts {
			if !folderChildName(component) {
				return nil, "", errors.New("folder manifest requires relative child paths")
			}
		}
		if _, exists := seen[e.Path]; exists {
			return nil, "", errors.New("duplicate folder path")
		}
		switch e.Kind {
		case "directory":
			if e.Size != 0 || e.SHA256 != "" {
				return nil, "", errors.New("directory entry cannot contain file metadata")
			}
		case "file":
			digest, err := hex.DecodeString(e.SHA256)
			if err != nil || len(digest) != 32 || e.Size < 0 {
				return nil, "", errors.New("nonnegative file size and SHA256 required")
			}
			e.SHA256 = strings.ToLower(e.SHA256)
			if e.Size > maximumStreamedFileBytes-total {
				return nil, "", errors.New("folder total length overflows file offsets")
			}
			total += e.Size
		default:
			return nil, "", errors.New("folder entry must be a file or directory")
		}
		seen[e.Path] = e.Kind
	}
	for _, e := range result {
		if parent := path.Dir(e.Path); parent != "." && seen[parent] != "directory" {
			return nil, "", errors.New("folder parent directory missing from manifest")
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Path < result[j].Path })
	raw, err := json.Marshal(result)
	if err != nil {
		return nil, "", err
	}
	sum := sha256.Sum256(raw)
	return result, hex.EncodeToString(sum[:]), nil
}
