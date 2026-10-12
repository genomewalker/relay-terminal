package daemon

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

func TestHPCLegacySlurmFallback(t *testing.T) {
	raw := "JobId=123 JobName=test with spaces UserId=alice(1000) GroupId=group(1000) JobState=RUNNING Account=project Partition=batch WorkDir=/tmp/job with spaces StdOut=/tmp/job with spaces/output StdErr=/tmp/job with spaces/error"
	calls := 0
	detail, err := inspectHPCDetail("/", "123", 1000, func(root, name string, args ...string) (string, error) {
		calls++
		if calls == 1 {
			return "", errors.New("unrecognized option '--json'")
		}
		if !reflect.DeepEqual(args, []string{"--oneliner", "show", "job", "123"}) {
			t.Fatal(args)
		}
		return raw, nil
	})
	if err != nil || detail.Directory != "/tmp/job with spaces" || calls != 2 {
		t.Fatal(detail, err, calls)
	}
	for _, bad := range []string{raw + " UserId=bob(1001)", raw + "\nJobId=456", strings.Replace(raw, "UserId=alice(1000)", "UserId=alice", 1), strings.Replace(raw, "StdErr=", "Unexpected=", 1)} {
		if _, err := legacyHPCJSON(bad); err == nil {
			t.Fatal("accepted ambiguous legacy response")
		}
	}
}

func detailFixture(t *testing.T, id string, changes map[string]any) (*PluginHPCDetail, error) {
	t.Helper()
	job := map[string]any{"job_id": 123, "user_id": 1000, "name": "job", "job_state": []string{"RUNNING"}, "current_working_directory": "/tmp", "standard_output": "/tmp/output"}
	for key, value := range changes {
		job[key] = value
	}
	data, _ := json.Marshal(map[string]any{"jobs": []any{job}})
	return inspectHPCDetail("/", id, 1000, func(root, name string, args ...string) (string, error) {
		if root != "/" || name != "scontrol" || !reflect.DeepEqual(args, []string{"--json", "show", "job", id}) {
			t.Fatal("unsafe invocation", name, args)
		}
		return string(data), nil
	})
}

func TestHPCDetailsIdentityOwnershipAndVersions(t *testing.T) {
	d, err := detailFixture(t, "123", nil)
	if err != nil || d.State != "RUNNING" {
		t.Fatal(d, err)
	}
	for _, changes := range []map[string]any{{"array_job_id": 120, "array_task_id": 4}, {"array_job_id": 120, "array_task_id": map[string]any{"set": true, "number": 4}}} {
		if _, err := detailFixture(t, "120_4", changes); err != nil {
			t.Fatal(err)
		}
	}
	for _, changes := range []map[string]any{{"user_id": 1001}, {"user_id": nil}, {"job_id": 124}, {"name": strings.Repeat("x", 4097)}} {
		if _, err := detailFixture(t, "123", changes); err == nil {
			t.Fatal("accepted invalid identity/field", changes)
		}
	}
	if _, err := detailFixture(t, "120_4", map[string]any{"array_job_id": 120, "array_task_id": 5}); err == nil {
		t.Fatal("accepted wrong array task")
	}
	for _, id := range []string{"", "--all", "1,2", "1_[1-4]", "1;touch /tmp/pwn", "000123"} {
		if _, err := detailFixture(t, id, nil); err == nil {
			t.Fatal("accepted", id)
		}
	}
}

func TestHPCPublicDetailsRetainLogOwnership(t *testing.T) {
	data := `{"jobs":[{"job_id":123,"user_id":1001,"name":"other user's job","job_state":"RUNNING"}]}`
	run := func(string, string, ...string) (string, error) { return data, nil }
	if detail, err := inspectHPCDetail("/", "123", 1000, run, true); err != nil || detail.Name != "other user's job" {
		t.Fatal(detail, err)
	}
	if _, err := inspectHPCDetail("/", "123", 1000, run, false); err == nil {
		t.Fatal("allowed another user's log lookup")
	}
	if _, err := inspectHPCDetail("/", "124", 1000, run, true); err == nil {
		t.Fatal("public details accepted wrong identity")
	}
}

func TestHPCDetailsMalformedAndDisappeared(t *testing.T) {
	for _, data := range []string{"{}", `{"jobs":[]}`, `{"jobs":[{},{}]}`, `{"jobs":[],"errors":[{}]}`, "not JSON", strings.Repeat("x", 1<<20+1)} {
		if _, err := inspectHPCDetail("/", "123", 1000, func(string, string, ...string) (string, error) { return data, nil }); err == nil {
			t.Fatal("accepted invalid response")
		}
	}
}

func TestHPCLogsBoundedAndRooted(t *testing.T) {
	root := t.TempDir()
	content := strings.Repeat("x", 100000) + "last line"
	if err := os.WriteFile(filepath.Join(root, "stdout"), []byte(content), 0600); err != nil {
		t.Fatal(err)
	}
	d := &PluginHPCDetail{Directory: root, Stdout: filepath.Join(root, "stdout"), Stderr: "empty"}
	if err := os.WriteFile(filepath.Join(root, "empty"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	text, partial, err := readHPCLog(d, "stdout")
	if err != nil || !partial || len(text) != 64<<10 || !strings.HasSuffix(text, "last line") {
		t.Fatal(len(text), partial, err)
	}
	text, partial, err = readHPCLog(d, "stderr")
	if err != nil || partial || text != "" {
		t.Fatal(text, partial, err)
	}
	outside := filepath.Join(t.TempDir(), "secret")
	if err := os.WriteFile(outside, []byte("secret"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{outside, "escape", "../secret", "missing", "slurm-%j.out", "."} {
		d.Stdout = path
		if _, _, err := readHPCLog(d, "stdout"); err == nil {
			t.Fatal("accepted unsafe log", path)
		}
	}
	if _, _, err := readHPCLog(d, "other"); err == nil {
		t.Fatal("accepted invalid stream")
	}
}

func BenchmarkHPCQueue1500(b *testing.B) {
	var data strings.Builder
	for i := 0; i < 1500; i++ {
		data.WriteString(strings.ReplaceAll("ID\x1fp\x1fn\x1fRUNNING\x1f0\x1f1\x1fn\n", "ID", fmtJobID(i)))
	}
	raw := data.String()
	b.ReportAllocs()
	for b.Loop() {
		if _, err := inspectHPCJobs("/", hpcFixture(raw)); err != nil {
			b.Fatal(err)
		}
	}
}

func fmtJobID(i int) string { return strconv.Itoa(i) }
