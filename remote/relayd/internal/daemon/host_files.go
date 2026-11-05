package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
)

// File operations share the authenticated node transport. Read operations never
// launch a shell; writes require the exact prior version or explicit creation.
var hostFileWrites sync.Mutex

func (s *Server) hostFileRPC(r hostRequest) (any, error) {
	if strings.HasPrefix(r.Operation, "file_folder_") {
		return s.hostFolderRPC(r)
	}
	if strings.HasPrefix(r.Operation, "file_upload_") {
		return s.hostUploadRPC(r)
	}
	if r.Operation != "file_write" {
		return s.hostFileOperation(r)
	}
	if !validSessionID.MatchString(r.JobID) {
		return nil, errors.New("stable job_id required for writes")
	}
	identity := r
	identity.RequestID = ""
	raw, err := json.Marshal(identity)
	if err != nil {
		return nil, err
	}
	hash := sha256.Sum256(raw)
	fingerprint := hex.EncodeToString(hash[:])
	hostFileWrites.Lock()
	defer hostFileWrites.Unlock()
	dir := filepath.Join(s.stateDir, "host-writes")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	path := filepath.Join(dir, r.JobID+".json")
	if data, err := os.ReadFile(path); err == nil {
		var receipt struct {
			Fingerprint string `json:"fingerprint"`
			Result      any    `json:"result"`
		}
		if json.Unmarshal(data, &receipt) != nil || receipt.Fingerprint != fingerprint {
			return nil, errors.New("write ID already reserved")
		}
		if receipt.Result == nil {
			return nil, errors.New("write outcome unknown; inspect destination, never replay")
		}
		return receipt.Result, nil
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	reservation, _ := json.Marshal(map[string]any{"fingerprint": fingerprint})
	_, err = file.Write(reservation)
	if err == nil {
		err = file.Sync()
	}
	file.Close()
	if err != nil {
		return nil, err
	}
	directory, err := os.Open(dir)
	if err != nil {
		return nil, err
	}
	defer directory.Close()
	if err = directory.Sync(); err != nil {
		return nil, err
	}
	result, err := s.hostFileOperation(r)
	if err != nil {
		return nil, err
	}
	receipt, err := json.Marshal(map[string]any{"fingerprint": fingerprint, "result": result})
	if err != nil {
		return nil, err
	}
	temp, err := os.CreateTemp(dir, ".receipt-")
	if err != nil {
		return nil, err
	}
	defer os.Remove(temp.Name())
	_, err = temp.Write(receipt)
	if err == nil {
		err = temp.Sync()
	}
	temp.Close()
	if err != nil {
		return nil, err
	}
	if err = os.Rename(temp.Name(), path); err != nil {
		return nil, err
	}
	if err = directory.Sync(); err != nil {
		return nil, err
	}
	return result, nil
}

func (s *Server) hostFileOperation(r hostRequest) (any, error) {
	if r.Operation == "capabilities" {
		home, _ := os.UserHomeDir()
		tools := map[string]bool{}
		for _, name := range []string{"squeue", "scontrol", "python3", "node", "chromium", "chromium-browser", "google-chrome"} {
			_, err := exec.LookPath(name)
			tools[name] = err == nil
		}
		return map[string]any{"platform": runtime.GOOS, "architecture": runtime.GOARCH, "home": home,
			"operations": []string{"exec", "status", "input", "cancel", "file_stat", "file_list", "file_read", "file_write", "file_verify", "file_upload_begin", "file_upload_status", "file_upload_chunk", "file_upload_commit", "file_upload_cancel", "file_folder_destination", "file_folder_begin", "file_folder_status", "file_folder_chunk", "file_folder_file_commit", "file_folder_commit", "file_folder_cancel", "file_folder_cleanup", "process_list", "process_signal", "agent_accounts"}, "tools": tools,
			"file_upload_protocol": 2, "file_upload_unbounded": true, "file_upload_chunk_bytes": 4 << 20, "folder_upload_protocol": 1, "folder_upload_limits": map[string]any{"max_entries": 1024, "max_file_bytes": maximumStreamedFileBytes, "max_total_bytes": maximumStreamedFileBytes, "max_chunk_bytes": 4 << 20}, "folder_atomic_visibility": false}, nil
	}
	if r.Path == "" || len(r.Path) > 4096 || strings.ContainsRune(r.Path, 0) {
		return nil, errors.New("bounded path required")
	}
	path := r.Path
	if path == "~" || strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		path = filepath.Join(home, strings.TrimPrefix(path, "~/"))
		if r.Path == "~" {
			path = home
		}
	}
	if !filepath.IsAbs(path) {
		if !filepath.IsAbs(r.Cwd) {
			return nil, errors.New("absolute cwd required for relative paths")
		}
		path = filepath.Join(r.Cwd, path)
	}
	path = filepath.Clean(path)
	if r.Operation == "file_list" {
		directory, err := os.Open(path)
		if err != nil {
			return nil, err
		}
		defer directory.Close()
		entries, err := directory.ReadDir(501)
		if err != nil && err != io.EOF {
			return nil, err
		}
		truncated := len(entries) > 500
		if truncated {
			entries = entries[:500]
		}
		rows := []map[string]any{}
		for _, entry := range entries {
			info, err := entry.Info()
			if err != nil {
				continue
			}
			rows = append(rows, map[string]any{"name": entry.Name(), "directory": entry.IsDir(), "symlink": entry.Type()&os.ModeSymlink != 0, "size": info.Size(), "version": transferVersion(info)})
		}
		return map[string]any{"path": path, "entries": rows, "truncated": truncated}, nil
	}
	if r.Operation == "file_write" {
		if len(r.Data) > 4<<20 || r.Version == "" {
			return nil, errors.New("bounded data and expected version required")
		}
		if info, err := os.Lstat(path); err == nil {
			if !info.Mode().IsRegular() || transferVersion(info) != r.Version {
				return nil, errors.New("destination changed or is not a regular file")
			}
		} else if !os.IsNotExist(err) || r.Version != "missing" {
			return nil, errors.New("destination version is not missing")
		}
		temp, err := os.CreateTemp(filepath.Dir(path), ".relay-write-")
		if err != nil {
			return nil, err
		}
		defer os.Remove(temp.Name())
		defer temp.Close()
		if _, err = temp.Write(r.Data); err != nil {
			return nil, err
		}
		if err = temp.Sync(); err != nil {
			return nil, err
		}
		if info, err := os.Lstat(path); err == nil {
			if !info.Mode().IsRegular() || transferVersion(info) != r.Version {
				return nil, errors.New("destination changed before commit")
			}
			if err = temp.Chmod(info.Mode().Perm()); err != nil {
				return nil, err
			}
		} else if !os.IsNotExist(err) || r.Version != "missing" {
			return nil, errors.New("destination changed before commit")
		}
		if r.Version == "missing" {
			if err = os.Link(temp.Name(), path); err != nil {
				return nil, err
			}
		} else if err = os.Rename(temp.Name(), path); err != nil {
			return nil, err
		}
		info, err := os.Stat(path)
		if err != nil {
			return nil, err
		}
		return map[string]any{"path": path, "size": info.Size(), "version": transferVersion(info)}, nil
	}
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	version := transferVersion(info)
	result := map[string]any{"path": path, "size": info.Size(), "directory": info.IsDir(), "version": version}
	if r.Operation == "file_stat" {
		return result, nil
	}
	if !info.Mode().IsRegular() || r.Version == "" || r.Version != version {
		return nil, errors.New("regular file and matching version required")
	}
	if r.Operation == "file_read" {
		if r.Offset < 0 || r.Offset > info.Size() || r.Length < 1 || r.Length > 4<<20 {
			return nil, errors.New("bounded file range required")
		}
		length := int64(r.Length)
		if length > info.Size()-r.Offset {
			length = info.Size() - r.Offset
		}
		data := make([]byte, int(length))
		n, err := file.ReadAt(data, r.Offset)
		if err != nil && err != io.EOF {
			return nil, err
		}
		data = data[:n]
		sum := sha256.Sum256(data)
		result["data"] = data
		result["offset"] = r.Offset
		result["next_offset"] = r.Offset + int64(n)
		result["sha256"] = hex.EncodeToString(sum[:])
	} else if r.Operation == "file_verify" {
		if info.Size() > 512<<20 {
			return nil, errors.New("use a durable checksum job for files over 512 MiB")
		}
		hash := sha256.New()
		if _, err := io.Copy(hash, file); err != nil {
			return nil, err
		}
		result["sha256"] = hex.EncodeToString(hash.Sum(nil))
	} else {
		return nil, errors.New("unsupported file operation")
	}
	after, err := file.Stat()
	if err != nil || transferVersion(after) != version {
		return nil, errors.New("source changed during read")
	}
	return result, nil
}
