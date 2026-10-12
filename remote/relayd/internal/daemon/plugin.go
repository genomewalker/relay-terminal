package daemon

// Plugins select core-owned operations; manifests never supply executable code.
import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

type PluginRequest struct {
	AllUsers  bool                   `json:"all_users,omitempty"`
	User      string                 `json:"user,omitempty"`
	Cluster   bool                   `json:"cluster,omitempty"`
	Operation string                 `json:"operation"`
	Root      string                 `json:"root"`
	Path      string                 `json:"path,omitempty"`
	JobID     string                 `json:"job_id,omitempty"`
	Stream    string                 `json:"stream,omitempty"`
	Script    string                 `json:"script,omitempty"`
	ActionID  string                 `json:"action_id,omitempty"`
	Confirmed bool                   `json:"confirmed,omitempty"`
	Transfer  *PluginTransferRequest `json:"transfer,omitempty"`
}

type PluginResult struct {
	Root         string              `json:"root"`
	Text         string              `json:"text"`
	Entries      []string            `json:"entries"`
	Content      *string             `json:"content,omitempty"`
	SHA256       string              `json:"sha256,omitempty"`
	Truncated    bool                `json:"truncated"`
	Jobs         []PluginHPCJob      `json:"jobs,omitempty"`
	JobCount     *int                `json:"job_count,omitempty"`
	Accounting   [][]string          `json:"accounting,omitempty"`
	JobDetail    *PluginHPCDetail    `json:"job_detail,omitempty"`
	Directory    *string             `json:"directory,omitempty"`
	Transfer     *PluginTransferInfo `json:"transfer,omitempty"`
	Cluster      *PluginHPCCluster   `json:"cluster,omitempty"`
	ClusterError string              `json:"cluster_error,omitempty"`
}

const pluginFileLimit = 8 << 20

// Resolve both sides before checking containment, including symlinked parents.
func pluginPath(root, name string) (string, error) {
	if filepath.IsAbs(name) {
		return "", errors.New("use a path relative to the approved directory")
	}
	path, err := filepath.EvalSymlinks(filepath.Join(root, name))
	if err != nil {
		return "", err
	}
	rel, err := filepath.Rel(root, path)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return "", errors.New("path leaves the approved directory")
	}
	return path, nil
}

func InspectPlugin(request PluginRequest) (PluginResult, error) {
	result := PluginResult{Entries: []string{}}
	if !filepath.IsAbs(request.Root) {
		return result, errors.New("an absolute approved directory is required")
	}
	root, err := filepath.EvalSymlinks(request.Root)
	if err != nil {
		return result, err
	}
	info, err := os.Stat(root)
	if err != nil || !info.IsDir() {
		return result, errors.New("approved directory is unavailable")
	}
	result.Root = root
	access, err := os.OpenRoot(root)
	if err != nil {
		return result, err
	}
	defer access.Close()
	switch request.Operation {
	case "hpcSubmit", "hpcCancel", "projectRun":
		var ledger string
		ledger, err = pluginActionLedger()
		if err == nil {
			runner := pluginMutationCommand
			if request.Operation == "projectRun" {
				runner = pluginProjectCommand
			}
			result.Text, err = performHPCAction(request, ledger, runner, func(root, id string) (*PluginHPCDetail, error) {
				return inspectHPCDetail(root, id, os.Getuid(), pluginSchedulerCommand)
			})
		}
	case "hpcAccounting":
		result.Text, result.Accounting, err = inspectHPCAccounting(root, request.JobID, os.Getuid(), pluginSchedulerCommand)
	case "hpcDetails", "hpcLogs":
		result.JobDetail, err = inspectHPCDetail(root, request.JobID, os.Getuid(), pluginSchedulerCommand, request.Operation == "hpcDetails")
		if err == nil && request.Operation == "hpcLogs" {
			result.Text, result.Truncated, err = readHPCLog(result.JobDetail, request.Stream)
		}
	case "hpcJobs":
		var page PluginHPCPage
		page, err = inspectHPCJobs(root, pluginHPCCommand, request)
		result.Jobs = page.Jobs
		result.JobCount = &page.Total
		result.Truncated = page.Truncated
		if err == nil && request.Cluster {
			var clusterErr error
			result.Cluster, clusterErr = inspectHPCCluster(root, pluginSchedulerCommand)
			if clusterErr != nil {
				result.ClusterError = clusterErr.Error()
			}
		}
		result.Text = "Slurm jobs owned by the connected user. This is a snapshot across projects, not just the selected directory."
	case "gitReview":
		err = pluginGitReview(&result, root, request.Path)
	case "projectActions":
		// Suggestions are data. The UI never executes repository-provided scripts.
		result.Entries = pluginProjectActions(access)
		result.Text = "Suggested commands only. Inspect the README and project scripts before running anything. Builds and even dry-run tools can execute project code."
	case "artifacts", "transfers":
		if request.Transfer != nil {
			if request.Operation != "transfers" {
				return result, errors.New("transfer protocol requires transfers operation")
			}
			err = pluginTransfer(access, request, &result)
			break
		}
		if request.Path == "" {
			var dir *os.File
			dir, err = access.Open(".")
			if err != nil {
				break
			}
			defer dir.Close()
			err = pluginListDirectory(&result, dir, "")
		} else {
			var file *os.File
			// Check the user path, then retain descriptor-relative confinement for
			// the actual open (including a concurrent symlink replacement).
			if _, err = pluginPath(root, request.Path); err != nil {
				break
			}
			file, err = access.OpenFile(filepath.Clean(request.Path), os.O_RDONLY|syscall.O_NONBLOCK, 0)
			if err != nil {
				break
			}
			defer file.Close()
			info, e := file.Stat()
			if e == nil && info.IsDir() {
				err = pluginListDirectory(&result, file, filepath.Clean(request.Path))
				break
			}
			if e != nil || !info.Mode().IsRegular() || info.Size() > pluginFileLimit {
				return result, errors.New("only regular files up to 8 MiB are supported")
			}
			data, e := io.ReadAll(io.LimitReader(file, pluginFileLimit+1))
			if e != nil {
				return result, e
			}
			if len(data) > pluginFileLimit {
				return result, errors.New("file grew beyond 8 MiB")
			}
			after, e := file.Stat()
			if e != nil || after.Size() != info.Size() || !after.ModTime().Equal(info.ModTime()) {
				return result, errors.New("file changed while reading; retry")
			}
			hash := sha256.Sum256(data)
			encoded := base64.StdEncoding.EncodeToString(data)
			result.Content = &encoded
			result.SHA256 = hex.EncodeToString(hash[:])
			result.Text = request.Path
		}
	default:
		return result, errors.New("unsupported plugin operation; update Relay and relayd together")
	}
	if len(result.Text) > 128<<10 {
		result.Text = result.Text[:128<<10]
		for !utf8.ValidString(result.Text) {
			result.Text = result.Text[:len(result.Text)-1]
		}
		result.Truncated = true
	}
	return result, err
}

// Read only the directory the user opens, never walk the tree or follow listed
// symlinks. OpenRoot enforces containment when the next entry is opened.
func pluginListDirectory(result *PluginResult, dir *os.File, path string) error {
	items, err := dir.ReadDir(501)
	if err != nil && err != io.EOF {
		return err
	}
	result.Truncated = len(items) > 500
	if len(items) > 500 {
		items = items[:500]
	}
	result.Directory = &path
	for _, item := range items {
		if item.Type().IsRegular() || item.IsDir() {
			name := filepath.Join(path, item.Name())
			if item.IsDir() {
				name += "/"
			}
			result.Entries = append(result.Entries, name)
		}
	}
	sort.Strings(result.Entries)
	result.Text = "Files and folders inside the approved directory. Open a folder to browse; open a file to preview or download (8 MiB maximum). Symlinks are omitted."
	return nil
}

type pluginBuffer struct {
	bytes.Buffer
	limit int
}

func (b *pluginBuffer) Write(p []byte) (int, error) {
	limit := b.limit
	if limit == 0 {
		limit = 1 << 20
	}
	if b.Len()+len(p) > limit {
		return 0, errors.New("plugin output exceeds 1 MiB; narrow the request")
	}
	return b.Buffer.Write(p)
}

func pluginCommand(root, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = root
	// A parent agent may itself run inside another worktree or inject Git config.
	// Never let its environment retarget the approved project or load helpers.
	for _, entry := range os.Environ() {
		if strings.HasPrefix(entry, "GIT_") || strings.HasPrefix(entry, "LC_ALL=") {
			continue
		}
		cmd.Env = append(cmd.Env, entry)
	}
	cmd.Env = append(cmd.Env, "GIT_OPTIONAL_LOCKS=0", "GIT_TERMINAL_PROMPT=0", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "LC_ALL=C")
	cmd.WaitDelay = time.Second
	var output pluginBuffer
	cmd.Stdout, cmd.Stderr = &output, &output
	if err := cmd.Run(); err != nil {
		return "", errors.New(name + " failed: " + err.Error() + "\n" + output.String())
	}
	return output.String(), nil
}
