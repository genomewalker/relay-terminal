package daemon

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var hpcActionID = regexp.MustCompile(`^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$`)

// Execute at most once per approved action ID. An on-disk intent is fsynced
// BEFORE calling Slurm. A timeout/crash therefore cannot cause a replay to
// submit a duplicate job. Unknown outcomes require scheduler reconciliation.
func performHPCAction(request PluginRequest, ledger string, run func(string, string, string, ...string) (string, error), details func(string, string) (*PluginHPCDetail, error)) (string, error) {
	if !request.Confirmed || !hpcActionID.MatchString(request.ActionID) {
		return "", errors.New("an explicitly confirmed action ID is required")
	}
	request.ActionID = strings.ToLower(request.ActionID)
	var name, input string
	var args []string
	switch request.Operation {
	case "projectRun":
		invocation, err := parseProjectInvocation(request.Script)
		if err != nil {
			return "", err
		}
		name, input = invocation.Argv[0], request.Script
	case "hpcSubmit":
		if len(request.Script) == 0 || len(request.Script) > 8192 || !strings.HasPrefix(request.Script, "#!") || strings.ContainsRune(request.Script, 0) {
			return "", errors.New("review a complete batch script with a shebang, at most 8 KiB")
		}
		name, input, args = "sbatch", request.Script, []string{"--parsable", "--export=NIL", "--chdir=" + request.Root}
	case "hpcCancel":
		if !hpcSingleJobID.MatchString(request.JobID) {
			return "", errors.New("select one job")
		}
		detail, err := details(request.Root, request.JobID)
		if err != nil {
			return "", err
		}
		if detail.Array {
			return "", errors.New("array cancellation is not supported in this version; use Slurm directly after reviewing its array semantics")
		}
		name, args = "scancel", []string{"--user=" + strconv.Itoa(os.Getuid()), request.JobID}
	default:
		return "", errors.New("unsupported mutation")
	}
	if err := os.MkdirAll(ledger, 0700); err != nil {
		return "", err
	}
	info, err := os.Lstat(ledger)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return "", errors.New("action journal must be a private directory")
	}
	root, err := os.OpenRoot(ledger)
	if err != nil {
		return "", err
	}
	defer root.Close()
	// A hard ceiling prevents an unattended client filling the filesystem.
	listing, err := os.Open(ledger)
	if err != nil {
		return "", err
	}
	entries, err := listing.ReadDir(10001)
	listing.Close()
	if err != nil && err != io.EOF {
		return "", err
	}
	if len(entries) >= 10000 {
		return "", errors.New("action journal is full; review archived outcomes before removing old receipts")
	}
	file, err := root.OpenFile(request.ActionID+".jsonl", os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if os.IsExist(err) {
		return "", errors.New("action already attempted; inspect its receipt and external state before creating a new request")
	}
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.Sum256([]byte(request.Script))
	host, _ := os.Hostname()
	receipt := map[string]any{"action_id": request.ActionID, "operation": request.Operation, "host": host, "directory": request.Root, "job_id": request.JobID, "script_sha256": hex.EncodeToString(hash[:]), "created_at": time.Now().UTC(), "outcome": "unknown"}
	if err := json.NewEncoder(file).Encode(receipt); err != nil {
		return "", err
	}
	if err := file.Sync(); err != nil {
		return "", err
	}
	directory, err := os.Open(ledger)
	if err != nil {
		return "", err
	}
	err = directory.Sync()
	directory.Close()
	if err != nil {
		return "", err
	}
	output, err := run(request.Root, name, input, args...)
	outcome := "confirmed"
	if err != nil {
		outcome = "unknown"
	}
	if name == "sbatch" && err == nil {
		value := strings.TrimSpace(output)
		job := strings.Split(value, ";")[0]
		if !regexp.MustCompile(`^[0-9]+$`).MatchString(job) {
			outcome = "unknown"
			err = errors.New("unrecognized scheduler receipt")
		}
	}
	// Append rather than replacing the original durable intent.
	_ = json.NewEncoder(file).Encode(map[string]string{"outcome": outcome, "response": output})
	_ = file.Sync()
	if err != nil {
		return "", fmt.Errorf("outcome unknown for action %s; DO NOT retry automatically. Inspect external state and the private action receipt: %w", request.ActionID, err)
	}
	verb := "accepted"
	if request.Operation == "projectRun" {
		verb = "completed"
	}
	return fmt.Sprintf("%s %s. Action %s\n%s", name, verb, request.ActionID, strings.TrimSpace(output)), nil
}

func pluginMutationCommand(root, name, input string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = root
	cmd.Stdin = strings.NewReader(input)
	cmd.WaitDelay = time.Second
	// Scheduler client environment must not silently override reviewed options.
	for _, item := range os.Environ() {
		if !strings.HasPrefix(item, "SBATCH_") && !strings.HasPrefix(item, "SCANCEL_") && !strings.HasPrefix(item, "SLURM_CLUSTERS=") {
			cmd.Env = append(cmd.Env, item)
		}
	}
	cmd.Env = append(cmd.Env, "LC_ALL=C")
	var out, diagnostic pluginBuffer
	cmd.Stdout, cmd.Stderr = &out, &diagnostic
	if err := cmd.Run(); err != nil {
		return out.String(), fmt.Errorf("%s failed or timed out: %w", name, err)
	}
	return out.String(), nil
}

func pluginActionLedger() (string, error) {
	home, err := os.UserHomeDir()
	return filepath.Join(home, ".local", "state", "relay", "plugin-actions"), err
}
