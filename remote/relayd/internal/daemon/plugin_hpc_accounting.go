package daemon

import (
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Query the authenticated Unix user's accounting records, including steps. Step
// measurements are shown separately; allocation totals never double-count them.
func inspectHPCAccounting(root, id string, uid int, run func(string, string, ...string) (string, error)) (string, [][]string, error) {
	if id != "" && !hpcSingleJobID.MatchString(id) {
		return "", nil, errors.New("select one numeric job or array task")
	}
	start := time.Now().Add(-24 * time.Hour).Format("2006-01-02T15:04:05")
	if id != "" {
		start = time.Now().AddDate(0, 0, -7).Format("2006-01-02")
	}
	args := []string{"--uid", strconv.Itoa(uid), "--parsable2", "--noheader", "--starttime", start, "--format", "JobID,UID,JobName,State,Partition,ElapsedRaw,AllocCPUS,AllocNodes,TotalCPU,CPUTimeRAW,ReqMem,MaxRSS,ExitCode,Submit,Start,End,Account,ReqTRES,AllocTRES"}
	if id != "" {
		args = append(args, "--jobs", id)
	} else {
		args = append(args, "--allocations")
	}
	raw, err := run(root, "sacct", args...)
	if err != nil {
		return "", nil, fmt.Errorf("Slurm accounting unavailable: %w", err)
	}
	if len(raw) > 6<<20 {
		return "", nil, errors.New("accounting response exceeds 6 MiB; select a specific job")
	}
	var out strings.Builder
	window := "past 24 hours"
	if id != "" {
		window = "past 7 days"
	}
	out.WriteString("Accounting · " + window + "\n")
	count := 0
	records := [][]string{}
	owned := map[string]bool{}
	for _, line := range strings.Split(raw, "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		f := strings.Split(line, "|")
		if len(f) == 20 && f[19] == "" {
			f = f[:19]
		}
		if len(f) != 19 {
			return "", nil, errors.New("invalid accounting record")
		}
		parent := strings.SplitN(f[0], ".", 2)[0]
		// Older Slurm prints even a single array task with brackets.
		if strings.Contains(parent, "_[") && strings.HasSuffix(parent, "]") {
			normalized := strings.Replace(parent, "_[", "_", 1)
			normalized = strings.TrimSuffix(normalized, "]")
			if hpcSingleJobID.MatchString(normalized) {
				f[0] = strings.Replace(f[0], parent, normalized, 1)
				parent = normalized
			} else if id == "" {
				continue
			}
		}
		if !hpcSingleJobID.MatchString(parent) || (id != "" && parent != id) {
			return "", nil, errors.New("accounting returned a different job")
		}
		// Steps may omit UID; their parent must have appeared and been validated.
		if f[1] != strconv.Itoa(uid) && !(f[1] == "" && strings.Contains(f[0], ".") && owned[parent]) {
			return "", nil, errors.New("accounting record does not belong to the connected user")
		}
		for _, value := range f {
			if len(value) > 4096 || strings.ContainsAny(value, "\x00\r\x1b") {
				return "", nil, errors.New("invalid accounting field")
			}
		}
		if !strings.Contains(f[0], ".") {
			owned[parent] = true
		}
		records = append(records, f)
		count++
	}
	if count == 0 {
		out.WriteString("No accounting records available in this window.\n")
	}
	sort.SliceStable(records, func(i, j int) bool { return records[i][14] > records[j][14] })
	if len(records) > 500 {
		records = records[:500]
		out.WriteString("Latest 500 records shown.\n")
	}
	fmt.Fprintf(&out, "%d individual accounting records in the %s.\n", count, window)
	return out.String(), records, nil
}
