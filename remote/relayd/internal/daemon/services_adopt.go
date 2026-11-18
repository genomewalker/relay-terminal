package daemon

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"runtime"
	"strconv"
)

func readServiceLedgerRecord(stateDir, jobID string) (hostJobRecord, error) {
	var record hostJobRecord
	if !validSessionID.MatchString(jobID) {
		return record, errors.New("invalid job ID")
	}
	if stateDir == "" {
		stateDir = defaultWorkerStateDir()
	}
	raw, _, err := readHostJobFolder(stateDir, jobID)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return record, fmt.Errorf("job %s is not in this host's ledger", jobID)
		}
		return record, err
	}
	if json.Unmarshal(raw, &record) != nil || record.JobID != jobID {
		return record, fmt.Errorf("job %s has an invalid ledger record", jobID)
	}
	return record, nil
}

// ServiceJobState is a one-line view of a bound job from the ledger.
func ServiceJobState(stateDir, jobID string) (pid int, state string) {
	if jobID == "" {
		return 0, "unbound"
	}
	record, err := readServiceLedgerRecord(stateDir, jobID)
	if err != nil {
		return 0, "not in ledger"
	}
	if record.State == "exited" || record.State == "failed" {
		return record.PID, record.State
	}
	process := hostJobProcessState(record)
	if process == "alive" {
		return record.PID, "running"
	}
	return record.PID, record.State + ", process " + process
}

// RequireLiveServiceJob checks that a job to be bound is live.
func RequireLiveServiceJob(stateDir, jobID string) error {
	record, err := readServiceLedgerRecord(stateDir, jobID)
	if err != nil {
		return err
	}
	if record.Kind != "" {
		return fmt.Errorf("job %s is a %s, not a service command", jobID, record.Kind)
	}
	if hostJobProcessState(record) != "alive" {
		return fmt.Errorf("job %s is not running (%s)", jobID, record.State)
	}
	return nil
}

// AdoptedServiceCommand recovers a running job's command and cwd from Linux
// /proc after checking the recorded process incarnation. A `/bin/sh -lc X`
// job yields the command X; anything else its argv. The environment is never
// read: it holds the supervisor's whole environment, not the declared one.
func AdoptedServiceCommand(stateDir, jobID string) (command string, argv []string, cwd string, err error) {
	if runtime.GOOS != "linux" {
		return "", nil, "", errors.New("--from-job reads /proc and works on Linux only; pass --command or argv and --cwd")
	}
	if err := RequireLiveServiceJob(stateDir, jobID); err != nil {
		return "", nil, "", err
	}
	record, err := readServiceLedgerRecord(stateDir, jobID)
	if err != nil {
		return "", nil, "", err
	}
	pid := strconv.Itoa(record.PID)
	raw, err := os.ReadFile("/proc/" + pid + "/cmdline")
	if err != nil {
		return "", nil, "", err
	}
	cwd, err = os.Readlink("/proc/" + pid + "/cwd")
	if err != nil {
		return "", nil, "", err
	}
	// Read after the files: the process must still be the recorded one.
	if start, err := processStartIdentity(record.PID); err != nil || start != record.ProcessStart {
		return "", nil, "", fmt.Errorf("job %s process changed while reading it", jobID)
	}
	parts := bytes.Split(bytes.TrimSuffix(raw, []byte{0}), []byte{0})
	for _, part := range parts {
		argv = append(argv, string(part))
	}
	if len(argv) == 3 && argv[0] == "/bin/sh" && argv[1] == "-lc" {
		return argv[2], nil, cwd, nil
	}
	if len(argv) == 0 || argv[0] == "" {
		return "", nil, "", fmt.Errorf("job %s has no readable command line", jobID)
	}
	return "", argv, cwd, nil
}
