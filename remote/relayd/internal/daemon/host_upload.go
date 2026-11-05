package daemon

// Upload acknowledgements describe durable bytes. Publication is a separate,
// journalled operation: an uncertain commit can only recover the same inode at
// the same destination, and can never select another name on retry.
import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

type uploadRecord struct {
	Format            int    `json:"format"`
	ID                string `json:"id"`
	Fingerprint       string `json:"fingerprint"`
	Directory         string `json:"directory"`
	DirectoryIdentity string `json:"directory_identity"`
	Name              string `json:"name"`
	Stage             string `json:"stage"`
	StageIdentity     string `json:"stage_identity"`
	Size              int64  `json:"size"`
	SHA256            string `json:"sha256"`
	Offset            int64  `json:"offset"`
	PrefixSHA256      string `json:"prefix_sha256"`
	State             string `json:"state"`
	Destination       string `json:"path,omitempty"`
}

func uploadIdentity(info os.FileInfo) string {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return ""
	}
	return fmt.Sprintf("%d:%d", stat.Dev, stat.Ino)
}

func uploadSyncDirectory(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}

func saveUpload(directory string, record uploadRecord) error {
	raw, err := json.Marshal(record)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(directory, ".checkpoint-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	_, err = f.Write(raw)
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err = os.Rename(f.Name(), filepath.Join(directory, record.ID+".json")); err != nil {
		return err
	}
	return uploadSyncDirectory(directory)
}

func uploadDigest(f *os.File, size int64) (string, error) {
	h := sha256.New()
	n, err := io.Copy(h, io.NewSectionReader(f, 0, size))
	if err != nil {
		return "", err
	}
	if n != size {
		return "", errors.New("upload bytes missing")
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func (s *Server) hostUploadRPC(r hostRequest) (any, error) {
	if !validSessionID.MatchString(r.JobID) {
		return nil, errors.New("stable upload job_id required")
	}
	switch r.Operation {
	case "file_upload_begin", "file_upload_status", "file_upload_chunk", "file_upload_commit", "file_upload_cancel":
	default:
		return nil, errors.New("unsupported upload operation")
	}
	root := filepath.Join(s.stateDir, "host-uploads")
	if info, err := os.Lstat(s.stateDir); err == nil {
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return nil, errors.New("upload catalog is not a real directory")
		}
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	if err := os.MkdirAll(s.stateDir, 0700); err != nil {
		return nil, err
	}
	if err := EnsurePrivateRuntimeDir(s.stateDir); err != nil {
		return nil, err
	}
	if err := EnsurePrivateRuntimeDir(root); err != nil {
		return nil, err
	}
	lock, err := OpenPrivateFile(filepath.Join(root, r.JobID+".lock"), os.O_CREATE|os.O_RDWR)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return nil, errors.New("upload is busy; query status later")
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	var record uploadRecord
	checkpoint, err := OpenPrivateFile(filepath.Join(root, r.JobID+".json"), os.O_RDONLY)
	if err == nil {
		raw, readErr := io.ReadAll(io.LimitReader(checkpoint, 16385))
		checkpoint.Close()
		if readErr != nil || len(raw) > 16384 || json.Unmarshal(raw, &record) != nil || record.Format != 1 || record.ID != r.JobID || record.Offset < 0 || record.Offset > record.Size || record.Size < 0 || !filepath.IsAbs(record.Directory) || filepath.Dir(record.Stage) != record.Directory || !strings.HasPrefix(filepath.Base(record.Stage), ".relay-upload-") || len(record.Fingerprint) != 64 || len(record.SHA256) != 64 || len(record.PrefixSHA256) != 64 {
			return nil, errors.New("invalid upload checkpoint")
		}
	} else if !os.IsNotExist(err) {
		return nil, err
	} else if r.Operation == "file_upload_cancel" {
		// Reserve an unseen ID as cancelled. A delayed begin can never recreate it.
		info, statErr := os.Stat(root)
		if statErr != nil {
			return nil, statErr
		}
		empty := sha256.Sum256(nil)
		digest := hex.EncodeToString(empty[:])
		record = uploadRecord{Format: 1, ID: r.JobID, Fingerprint: digest, Directory: root, DirectoryIdentity: uploadIdentity(info), Stage: filepath.Join(root, ".relay-upload-cancelled"), SHA256: digest, PrefixSHA256: digest, State: "cancelled"}
		if err := saveUpload(root, record); err != nil {
			return nil, err
		}
		return record, nil
	} else if r.Operation != "file_upload_begin" {
		return nil, errors.New("upload not found")
	}

	if r.Operation == "file_upload_begin" {
		if r.UploadSize < 0 || len(r.UploadSHA256) != 64 || r.UploadName == "" || len(r.UploadName) > 240 || r.UploadName == "." || r.UploadName == ".." || strings.ContainsAny(r.UploadName, "/\\\x00") || !validSessionID.MatchString(r.UploadPane) {
			return nil, errors.New("nonnegative upload size, SHA256, name and pane required")
		}
		decoded, decodeErr := hex.DecodeString(r.UploadSHA256)
		if decodeErr != nil || len(decoded) != 32 {
			return nil, errors.New("invalid upload SHA256")
		}
		requestedDirectory := r.Path
		if requestedDirectory == "" {
			parent, loadErr := loadManifest(s.manifestPath(r.UploadPane))
			if loadErr != nil || validateWorkerIdentity(parent) != nil {
				return nil, errors.New("exact live parent pane required to resolve upload directory")
			}
			requestedDirectory, err = processWorkingDirectory(parent.ShellPID)
			if err != nil {
				return nil, errors.New("cannot resolve live pane upload directory")
			}
		}
		workspace, err := ResolveWorkspace(r.UploadPane, requestedDirectory)
		if err != nil {
			return nil, err
		}
		dir, err := os.Stat(workspace.Path)
		if err != nil || !dir.IsDir() {
			return nil, errors.New("upload destination must be a directory")
		}
		identity, _ := json.Marshal([]any{r.UploadPane, workspace.Path, uploadIdentity(dir), r.UploadName, r.UploadSize, strings.ToLower(r.UploadSHA256)})
		sum := sha256.Sum256(identity)
		fingerprint := hex.EncodeToString(sum[:])
		if record.ID != "" {
			if record.Fingerprint != fingerprint {
				return nil, errors.New("upload ID already bound to different source or destination")
			}
		} else {
			stage, err := os.CreateTemp(workspace.Path, ".relay-upload-")
			if err != nil {
				return nil, err
			}
			info, statErr := stage.Stat()
			if statErr == nil {
				statErr = stage.Sync()
			}
			stage.Close()
			if statErr != nil {
				os.Remove(stage.Name())
				return nil, statErr
			}
			empty := sha256.Sum256(nil)
			record = uploadRecord{Format: 1, ID: r.JobID, Fingerprint: fingerprint, Directory: workspace.Path, DirectoryIdentity: uploadIdentity(dir), Name: r.UploadName, Stage: stage.Name(), StageIdentity: uploadIdentity(info), Size: r.UploadSize, SHA256: strings.ToLower(r.UploadSHA256), PrefixSHA256: hex.EncodeToString(empty[:]), State: "receiving"}
			if err = uploadSyncDirectory(workspace.Path); err != nil {
				os.Remove(stage.Name())
				return nil, err
			}
			if err = saveUpload(root, record); err != nil {
				return nil, err
			}
		}
	}
	if record.State == "committed" || record.State == "cancelled" {
		if r.Operation == "file_upload_chunk" {
			return nil, errors.New("upload is terminal")
		}
		return record, nil
	}
	if record.State != "receiving" && record.State != "committing" {
		return nil, errors.New("invalid upload state")
	}
	dir, err := os.Stat(record.Directory)
	if err != nil || !dir.IsDir() || uploadIdentity(dir) != record.DirectoryIdentity {
		return nil, errors.New("upload destination directory changed")
	}
	stage, err := OpenPrivateFile(record.Stage, os.O_RDWR)
	if err != nil {
		return nil, err
	}
	defer stage.Close()
	info, err := stage.Stat()
	if err != nil || uploadIdentity(info) != record.StageIdentity || info.Size() < record.Offset {
		return nil, errors.New("upload staging identity changed")
	}
	hasher, err := validatedUploadHash(stage, record.Offset, record.PrefixSHA256, r.Operation != "file_upload_chunk")
	if err != nil {
		return nil, errors.New("upload checkpoint bytes changed")
	}
	// A crash after data fsync but before checkpoint publication leaves a tail.
	if info.Size() != record.Offset {
		if record.State != "receiving" {
			return nil, errors.New("committing upload size changed")
		}
		if err = stage.Truncate(record.Offset); err != nil {
			return nil, err
		}
		if err = stage.Sync(); err != nil {
			return nil, err
		}
	}
	if record.State == "committing" {
		if r.Operation == "file_upload_cancel" || r.Operation == "file_upload_chunk" {
			return nil, errors.New("commit outcome pending; query status")
		}
		return finishUploadCommit(root, record, stage)
	}
	switch r.Operation {
	case "file_upload_cancel":
		record.State = "cancelled"
		if err = saveUpload(root, record); err != nil {
			return nil, err
		}
		if err = os.Remove(record.Stage); err != nil {
			return nil, err
		}
		if err = uploadSyncDirectory(record.Directory); err != nil {
			return nil, err
		}
	case "file_upload_chunk":
		if len(r.Data) == 0 || len(r.Data) > 4<<20 || r.Offset < 0 || r.Offset > record.Offset || int64(len(r.Data)) > record.Size-r.Offset {
			return nil, errors.New("bounded sequential upload chunk required")
		}
		if r.Offset < record.Offset {
			if int64(len(r.Data)) > record.Offset-r.Offset {
				return nil, errors.New("chunk crosses checkpoint")
			}
			old := make([]byte, len(r.Data))
			if _, err = stage.ReadAt(old, r.Offset); err != nil {
				return nil, err
			}
			if sha256.Sum256(old) != sha256.Sum256(r.Data) {
				return nil, errors.New("replayed chunk differs")
			}
			return record, nil
		}
		n, err := stage.WriteAt(r.Data, r.Offset)
		if err != nil {
			return nil, err
		}
		if n != len(r.Data) {
			return nil, io.ErrShortWrite
		}
		if err = stage.Sync(); err != nil {
			return nil, err
		}
		record.Offset += int64(n)
		hasher.Write(r.Data[:n])
		record.PrefixSHA256 = hex.EncodeToString(hasher.Sum(nil))
		if err = rememberUploadHash(stage, record.Offset, hasher); err != nil {
			return nil, err
		}
		if err = saveUpload(root, record); err != nil {
			return nil, err
		}
	case "file_upload_commit":
		if record.Offset != record.Size || record.PrefixSHA256 != record.SHA256 {
			return nil, errors.New("upload is incomplete or checksum differs")
		}
		for index := 0; index < 1000; index++ {
			name := record.Name
			if index > 0 {
				ext := filepath.Ext(name)
				name = fmt.Sprintf("%s (%d)%s", strings.TrimSuffix(name, ext), index, ext)
			}
			path := filepath.Join(record.Directory, name)
			if _, err := os.Lstat(path); os.IsNotExist(err) {
				record.Destination = path
				break
			} else if err != nil {
				return nil, err
			}
		}
		if record.Destination == "" {
			return nil, errors.New("upload name collision limit reached")
		}
		record.State = "committing"
		if err = saveUpload(root, record); err != nil {
			return nil, err
		}
		return finishUploadCommit(root, record, stage)
	}
	return record, nil
}

func finishUploadCommit(root string, record uploadRecord, stage *os.File) (any, error) {
	if filepath.Dir(record.Destination) != record.Directory || record.Destination == record.Stage {
		return nil, errors.New("invalid commit destination")
	}
	if err := os.Link(record.Stage, record.Destination); err != nil {
		if !os.IsExist(err) {
			return nil, err
		}
		published, statErr := os.Lstat(record.Destination)
		staged, stageErr := stage.Stat()
		if statErr != nil || stageErr != nil || !published.Mode().IsRegular() || !os.SameFile(published, staged) {
			return nil, errors.New("commit destination changed; outcome unknown, never replay to another name")
		}
	}
	if err := uploadSyncDirectory(record.Directory); err != nil {
		return nil, err
	}
	record.State = "committed"
	if err := saveUpload(root, record); err != nil {
		return nil, err
	}
	// Keep the receipt forever; removing the private stage never removes the file.
	if err := os.Remove(record.Stage); err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	if err := uploadSyncDirectory(record.Directory); err != nil {
		return nil, err
	}
	return record, nil
}
