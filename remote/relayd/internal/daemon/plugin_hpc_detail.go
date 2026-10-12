package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
)

var hpcSingleJobID = regexp.MustCompile(`^[0-9]{1,20}(_[0-9]{1,20})?$`)

// Scheduler fields are retained only after exact identity validation.
type PluginHPCDetail struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	State     string `json:"state"`
	Account   string `json:"account"`
	Partition string `json:"partition"`
	Directory string `json:"directory"`
	Stdout    string `json:"stdout"`
	Stderr    string `json:"stderr"`
	Array     bool   `json:"array"`
	Scheduler string `json:"scheduler,omitempty"`
}

func inspectHPCDetail(root, id string, uid int, run func(string, string, ...string) (string, error), publicDetails ...bool) (*PluginHPCDetail, error) {
	if !hpcSingleJobID.MatchString(id) {
		return nil, errors.New("select one numeric job or individual array task; ranges are not supported")
	}
	output, err := run(root, "scontrol", "--json", "show", "job", id)
	if err != nil && strings.Contains(err.Error(), "unrecognized option") && strings.Contains(err.Error(), "json") {
		legacy, legacyErr := run(root, "scontrol", "--oneliner", "show", "job", id)
		if legacyErr != nil {
			return nil, legacyErr
		}
		output, err = legacyHPCJSON(legacy)
	}
	if err != nil {
		return nil, fmt.Errorf("job details unavailable (the job may have finished or this Slurm lacks JSON support): %w", err)
	}
	if len(output) > 1<<20 {
		return nil, errors.New("job details exceed 1 MiB")
	}
	var response struct {
		Jobs   []map[string]json.RawMessage `json:"jobs"`
		Errors []json.RawMessage            `json:"errors"`
	}
	if err := json.Unmarshal([]byte(output), &response); err != nil {
		return nil, errors.New("Slurm returned invalid JSON job details")
	}
	if len(response.Errors) != 0 || len(response.Jobs) != 1 {
		return nil, errors.New("job is unavailable or expanded to multiple tasks; select one live job")
	}
	j := response.Jobs[0]
	var owner int
	if json.Unmarshal(j["user_id"], &owner) != nil {
		return nil, errors.New("missing job owner")
	}
	if owner != uid && !(len(publicDetails) == 1 && publicDetails[0]) {
		return nil, errors.New("job does not belong to the connected user")
	}
	var jobID, arrayID uint64
	if json.Unmarshal(j["job_id"], &jobID) != nil {
		return nil, errors.New("missing job identity")
	}
	if strings.Contains(id, "_") {
		var task uint64
		// Slurm data-parser versions use either a number or {set,number}.
		if json.Unmarshal(j["array_task_id"], &task) != nil {
			var value struct {
				Set    bool   `json:"set"`
				Number uint64 `json:"number"`
			}
			if json.Unmarshal(j["array_task_id"], &value) != nil || !value.Set {
				return nil, errors.New("unsupported array task identity")
			}
			task = value.Number
		}
		if json.Unmarshal(j["array_job_id"], &arrayID) != nil || fmt.Sprintf("%d_%d", arrayID, task) != id {
			return nil, errors.New("scheduler returned a different array task")
		}
	} else if strconv.FormatUint(jobID, 10) != id {
		return nil, errors.New("scheduler returned a different job")
	}
	read := func(key string) string { var value string; _ = json.Unmarshal(j[key], &value); return value }
	state := read("job_state")
	if state == "" {
		var states []string
		_ = json.Unmarshal(j["job_state"], &states)
		state = strings.Join(states, ", ")
	}
	_ = json.Unmarshal(j["array_job_id"], &arrayID)
	detail := &PluginHPCDetail{id, read("name"), state, read("account"), read("partition"), read("current_working_directory"), read("standard_output"), read("standard_error"), arrayID != 0, ""}
	for _, field := range []string{detail.Name, detail.State, detail.Account, detail.Partition, detail.Directory, detail.Stdout, detail.Stderr} {
		if len(field) > 4096 || strings.ContainsRune(field, 0) {
			return nil, errors.New("invalid or oversized job detail field")
		}
	}
	formatted, _ := json.MarshalIndent(j, "", "  ")
	detail.Scheduler = string(formatted)
	return detail, nil
}

var hpcLegacyKey = regexp.MustCompile(`(?:^|[ \t])([A-Za-z][A-Za-z0-9_]*)=`)
var hpcLegacyOwner = regexp.MustCompile(`^.*\(([0-9]+)\)$`)

// Old Slurm lacks JSON. Reject ambiguous/duplicate keys and multiple records
// rather than trusting unescaped user-controlled job names or path strings.
func legacyHPCJSON(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if len(raw) > 1<<20 || strings.ContainsAny(raw, "\r\n\x00") {
		return "", errors.New("ambiguous legacy job details")
	}
	matches := hpcLegacyKey.FindAllStringSubmatchIndex(raw, -1)
	fields := map[string]string{}
	for i, m := range matches {
		key := raw[m[2]:m[3]]
		if _, exists := fields[key]; exists {
			return "", errors.New("duplicate key in legacy job details")
		}
		end := len(raw)
		if i+1 < len(matches) {
			end = matches[i+1][0]
		}
		fields[key] = strings.TrimSpace(raw[m[1]:end])
	}
	for _, key := range []string{"JobId", "UserId", "JobName", "JobState", "Account", "Partition", "WorkDir", "StdOut", "StdErr"} {
		if _, ok := fields[key]; !ok {
			return "", fmt.Errorf("legacy Slurm omitted %s", key)
		}
	}
	owner := hpcLegacyOwner.FindStringSubmatch(fields["UserId"])
	if len(owner) != 2 {
		return "", errors.New("invalid legacy job owner")
	}
	uid, err := strconv.ParseUint(owner[1], 10, 32)
	if err != nil {
		return "", err
	}
	id, err := strconv.ParseUint(fields["JobId"], 10, 64)
	if err != nil {
		return "", err
	}
	job := map[string]any{"job_id": id, "user_id": uid, "name": fields["JobName"], "job_state": fields["JobState"], "account": fields["Account"], "partition": fields["Partition"], "current_working_directory": fields["WorkDir"], "standard_output": fields["StdOut"], "standard_error": fields["StdErr"]}
	if value, ok := fields["ArrayJobId"]; ok {
		array, err := strconv.ParseUint(value, 10, 64)
		if err != nil {
			return "", err
		}
		task, err := strconv.ParseUint(fields["ArrayTaskId"], 10, 64)
		if err != nil {
			return "", errors.New("select one expanded array task")
		}
		job["array_job_id"] = array
		job["array_task_id"] = task
	}
	encoded, err := json.Marshal(map[string]any{"jobs": []any{job}})
	return string(encoded), err
}

// Reads only the controller-advertised file inside the job's working directory.
// This intentionally fails closed for logs outside that directory or unresolved
// Slurm filename substitutions, rather than widening access to arbitrary files.
func readHPCLog(detail *PluginHPCDetail, stream string) (string, bool, error) {
	path := detail.Stdout
	if stream == "stderr" {
		path = detail.Stderr
	} else if stream != "stdout" {
		return "", false, errors.New("choose stdout or stderr")
	}
	if path == "" || strings.Contains(path, "%") || !filepath.IsAbs(detail.Directory) {
		return "", false, errors.New("scheduler has not provided a resolved log path")
	}
	if filepath.IsAbs(path) {
		var err error
		path, err = filepath.Rel(detail.Directory, path)
		if err != nil {
			return "", false, err
		}
	}
	root, err := os.OpenRoot(detail.Directory)
	if err != nil {
		return "", false, err
	}
	defer root.Close()
	file, err := root.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return "", false, fmt.Errorf("log unavailable (it may not exist yet or lies outside the job directory): %w", err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return "", false, err
	}
	if !info.Mode().IsRegular() {
		return "", false, errors.New("log must be a regular file")
	}
	const limit = 64 << 10
	start := max(int64(0), info.Size()-limit)
	data, err := io.ReadAll(io.NewSectionReader(file, start, info.Size()-start))
	if err != nil {
		return "", false, err
	}
	return strings.ToValidUTF8(string(data), "�"), start > 0, nil
}
