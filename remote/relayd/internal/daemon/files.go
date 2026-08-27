package daemon

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const maxEditorFileBytes = 16 << 20
const maxImportedFileBytes = 64 << 20

type WorkspaceInfo struct {
	Path string `json:"path"`
}

type FileEntry struct {
	Name           string `json:"name"`
	Path           string `json:"path"`
	Directory      bool   `json:"directory"`
	SymbolicLink   bool   `json:"symbolic_link"`
	Size           int64  `json:"size"`
	ModificationNS int64  `json:"modification_ns"`
}

type FileDocument struct {
	Path           string `json:"path"`
	ContentBase64  string `json:"content_base64"`
	ModificationNS int64  `json:"modification_ns"`
	Mode           uint32 `json:"mode"`
}

type FileDiff struct {
	OriginalLabel  string       `json:"original_label"`
	OriginalBase64 string       `json:"original_base64"`
	Modified       FileDocument `json:"modified"`
}

func ResolveWorkspace(parentSessionID, requested string) (WorkspaceInfo, error) {
	path := strings.TrimSpace(requested)
	if path == "" && validSessionID.MatchString(parentSessionID) {
		manifestPath := filepath.Join(defaultWorkerStateDir(), parentSessionID+".json")
		if parent, err := loadManifest(manifestPath); err == nil && validateWorkerIdentity(parent) == nil {
			if directory, cwdErr := processWorkingDirectory(parent.ShellPID); cwdErr == nil {
				path = directory
			} else {
				path = parent.WorkingDirectory
			}
		}
	}
	resolved, err := resolveUserPath(path, true)
	if err != nil {
		return WorkspaceInfo{}, err
	}
	return WorkspaceInfo{Path: resolved}, nil
}

func ListDirectory(path string) ([]FileEntry, error) {
	resolved, err := resolveUserPath(path, true)
	if err != nil {
		return nil, err
	}
	items, err := os.ReadDir(resolved)
	if err != nil {
		return nil, err
	}
	entries := make([]FileEntry, 0, len(items))
	for _, item := range items {
		info, infoErr := item.Info()
		if infoErr != nil {
			continue
		}
		entryPath := filepath.Join(resolved, item.Name())
		entries = append(entries, FileEntry{
			Name: item.Name(), Path: entryPath, Directory: item.IsDir(),
			SymbolicLink: item.Type()&os.ModeSymlink != 0,
			Size:         info.Size(), ModificationNS: info.ModTime().UnixNano(),
		})
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Directory != entries[j].Directory {
			return entries[i].Directory
		}
		return strings.ToLower(entries[i].Name) < strings.ToLower(entries[j].Name)
	})
	return entries, nil
}

func ReadEditorFile(path string) (FileDocument, error) {
	resolved, err := resolveUserPath(path, false)
	if err != nil {
		return FileDocument{}, err
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return FileDocument{}, err
	}
	if !info.Mode().IsRegular() {
		return FileDocument{}, errors.New("editor path is not a regular file")
	}
	if info.Size() > maxEditorFileBytes {
		return FileDocument{}, errors.New("editor file exceeds 16 MiB")
	}
	data, err := os.ReadFile(resolved)
	if err != nil {
		return FileDocument{}, err
	}
	if strings.IndexByte(string(data), 0) >= 0 {
		return FileDocument{}, errors.New("binary files cannot be opened in the text editor")
	}
	return FileDocument{
		Path: resolved, ContentBase64: base64.StdEncoding.EncodeToString(data),
		ModificationNS: info.ModTime().UnixNano(), Mode: uint32(info.Mode().Perm()),
	}, nil
}

func WriteEditorFile(path string, expectedModificationNS int64, reader io.Reader) (FileDocument, error) {
	resolved, err := resolveUserPath(path, false)
	if err != nil {
		return FileDocument{}, err
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return FileDocument{}, err
	}
	if !info.Mode().IsRegular() {
		return FileDocument{}, errors.New("editor path is not a regular file")
	}
	if expectedModificationNS != 0 && info.ModTime().UnixNano() != expectedModificationNS {
		return FileDocument{}, errors.New("file changed on the remote node; reload before saving")
	}
	data, err := io.ReadAll(io.LimitReader(reader, maxEditorFileBytes+1))
	if err != nil {
		return FileDocument{}, err
	}
	if len(data) > maxEditorFileBytes {
		return FileDocument{}, errors.New("editor file exceeds 16 MiB")
	}
	temporary, err := os.CreateTemp(filepath.Dir(resolved), ".relay-save-*")
	if err != nil {
		return FileDocument{}, err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(info.Mode().Perm()); err != nil {
		temporary.Close()
		return FileDocument{}, err
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return FileDocument{}, err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return FileDocument{}, err
	}
	if err := temporary.Close(); err != nil {
		return FileDocument{}, err
	}
	if err := os.Rename(temporaryPath, resolved); err != nil {
		return FileDocument{}, err
	}
	return ReadEditorFile(resolved)
}

// ImportFile copies a local desktop file into an existing remote directory.
// It never overwrites: repeated drops receive a numbered filename instead.
func ImportFile(directory, name string, reader io.Reader) (FileEntry, error) {
	resolvedDirectory, err := resolveUserPath(directory, true)
	if err != nil {
		return FileEntry{}, err
	}
	name = strings.TrimSpace(name)
	if name == "" || filepath.Base(name) != name || name == "." || name == ".." {
		return FileEntry{}, errors.New("import filename is invalid")
	}

	extension := filepath.Ext(name)
	stem := strings.TrimSuffix(name, extension)
	var destination string
	var destinationFile *os.File
	for attempt := 0; attempt < 1000; attempt++ {
		candidateName := name
		if attempt > 0 {
			candidateName = stem + "-" + strconv.Itoa(attempt+1) + extension
		}
		candidate := filepath.Join(resolvedDirectory, candidateName)
		destinationFile, err = os.OpenFile(candidate, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if err == nil {
			destination = candidate
			break
		}
		if !os.IsExist(err) {
			return FileEntry{}, err
		}
	}
	if destinationFile == nil {
		return FileEntry{}, errors.New("could not choose an unused import filename")
	}
	keep := false
	defer func() {
		_ = destinationFile.Close()
		if !keep {
			_ = os.Remove(destination)
		}
	}()

	written, err := io.Copy(destinationFile, io.LimitReader(reader, maxImportedFileBytes+1))
	if err != nil {
		return FileEntry{}, err
	}
	if written > maxImportedFileBytes {
		return FileEntry{}, errors.New("import file exceeds 64 MiB")
	}
	if err := destinationFile.Sync(); err != nil {
		return FileEntry{}, err
	}
	if err := destinationFile.Close(); err != nil {
		return FileEntry{}, err
	}
	info, err := os.Stat(destination)
	if err != nil {
		return FileEntry{}, err
	}
	keep = true
	return FileEntry{
		Name: filepath.Base(destination), Path: destination, Size: info.Size(),
		ModificationNS: info.ModTime().UnixNano(),
	}, nil
}

func ReadGitDiff(path string) (FileDiff, error) {
	modified, err := ReadEditorFile(path)
	if err != nil {
		return FileDiff{}, err
	}
	directory := filepath.Dir(modified.Path)
	rootCommand := exec.Command("git", "-C", directory, "rev-parse", "--show-toplevel")
	rootOutput, err := rootCommand.Output()
	if err != nil {
		return FileDiff{}, errors.New("file is not inside a Git worktree")
	}
	root := strings.TrimSpace(string(rootOutput))
	relative, err := filepath.Rel(root, modified.Path)
	if err != nil || relative == ".." || filepath.IsAbs(relative) || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return FileDiff{}, errors.New("file is outside the Git worktree")
	}
	show := exec.Command("git", "-C", root, "show", "HEAD:"+filepath.ToSlash(relative))
	original, err := show.Output()
	if err != nil {
		return FileDiff{}, errors.New("file does not exist in Git HEAD")
	}
	if len(original) > maxEditorFileBytes {
		return FileDiff{}, errors.New("Git version exceeds 16 MiB")
	}
	return FileDiff{
		OriginalLabel:  "HEAD · " + relative,
		OriginalBase64: base64.StdEncoding.EncodeToString(original),
		Modified:       modified,
	}, nil
}

func EncodeJSON(writer io.Writer, value any) error {
	encoder := json.NewEncoder(writer)
	encoder.SetEscapeHTML(false)
	return encoder.Encode(value)
}

func DecodePath(value string) (string, error) {
	if value == "" {
		return "", errors.New("path is required")
	}
	decoded, err := base64.StdEncoding.DecodeString(value)
	if err != nil {
		return "", errors.New("invalid base64 path")
	}
	return string(decoded), nil
}

func resolveUserPath(path string, requireDirectory bool) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	path = strings.TrimSpace(path)
	if path == "" || path == "~" {
		path = home
	} else if strings.HasPrefix(path, "~/") {
		path = filepath.Join(home, strings.TrimPrefix(path, "~/"))
	}
	if !filepath.IsAbs(path) {
		return "", errors.New("remote file path must be absolute")
	}
	resolved, err := filepath.EvalSymlinks(filepath.Clean(path))
	if err != nil {
		return "", err
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", err
	}
	if requireDirectory && !info.IsDir() {
		return "", fmt.Errorf("%s is not a directory", resolved)
	}
	return resolved, nil
}

func editorTimestamp() int64 { return time.Now().UnixNano() }
