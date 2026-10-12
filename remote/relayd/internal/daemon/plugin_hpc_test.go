package daemon

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func hpcFixture(output string) func(string, ...string) (string, error) {
	return func(string, ...string) (string, error) { return output, nil }
}

func TestHPCJobsStructuredAndReadOnly(t *testing.T) {
	page, err := inspectHPCJobs("/approved", func(root string, args ...string) (string, error) {
		if root != "/approved" || !reflect.DeepEqual(args, []string{"--me", "--noheader", "--format=" + pluginHPCFormat}) {
			t.Fatalf("unexpected invocation: %q %q", root, args)
		}
		return "123_4\x1fbatch\x1fjob with spaces | quotes ' 🧬\x1fRUNNING\x1f2:04\x1f1\x1fnode01\n456\x1fgpu\x1ftrain\x1fPENDING\x1f0:00\x1f2\x1f(Resources)\n", nil
	})
	if err != nil || page.Total != 2 || page.Truncated || page.Jobs[0].ID != "123_4" || page.Jobs[1].Reason != "(Resources)" {
		t.Fatalf("%+v %v", page, err)
	}
}

func TestHPCQueueUserScopes(t *testing.T) {
	for _, request := range []PluginRequest{{AllUsers: true}, {AllUsers: true, User: "alice"}} {
		page, err := inspectHPCJobs("/tmp", func(_ string, args ...string) (string, error) {
			expected := []string{"--noheader", "--format=" + pluginHPCFormat}
			if request.User != "" {
				expected = append([]string{"--user=alice"}, expected...)
			}
			if !reflect.DeepEqual(args, expected) {
				t.Fatalf("unexpected args: %q", args)
			}
			return "12\x1fbatch\x1ftest\x1fRUNNING\x1f1:00\x1f2\x1fnode\x1falice\x1f64\n", nil
		}, request)
		if err != nil || len(page.Jobs) != 1 || page.Jobs[0].Username != "alice" || page.Jobs[0].CPUs != "64" {
			t.Fatal(page, err)
		}
	}
	for _, user := range []string{"-x", "alice,bob", "a\nb", strings.Repeat("a", 65)} {
		if _, err := inspectHPCJobs("/tmp", func(string, ...string) (string, error) { t.Fatal("invalid user reached scheduler"); return "", nil }, PluginRequest{User: user}); err == nil {
			t.Fatal("accepted invalid username")
		}
	}
}

func TestHPCEmptyMalformedAndFailures(t *testing.T) {
	page, err := inspectHPCJobs("/tmp", hpcFixture("\n"))
	if err != nil || page.Total != 0 || len(page.Jobs) != 0 {
		t.Fatal(page, err)
	}
	for _, bad := range []string{"warning: cannot connect", "1\x1fp\x1fname\x1f\x1f0\x1f1\x1fn", strings.Repeat("x", 1<<20+1), strings.Repeat("1\x1fp\x1fname\x1fRUNNING\x1f0\x1f1\x1fn\n", 2)} {
		if _, err := inspectHPCJobs("/tmp", hpcFixture(bad)); err == nil {
			t.Fatal("accepted malformed output")
		}
	}
	sentinel := errors.New("scheduler offline")
	_, err = inspectHPCJobs("/tmp", func(string, ...string) (string, error) { return "", sentinel })
	if !errors.Is(err, sentinel) {
		t.Fatal("query failure was hidden")
	}
}

func TestHPCLargeQueueIsExplicitlyPartial(t *testing.T) {
	var output strings.Builder
	for i := 0; i < 1500; i++ {
		fmt.Fprintf(&output, "%d\x1fp\x1fn\x1fRUNNING\x1f0\x1f1\x1fnode\n", i)
	}
	page, err := inspectHPCJobs("/tmp", hpcFixture(output.String()))
	if err != nil || len(page.Jobs) != 500 || page.Total != 1500 || !page.Truncated {
		t.Fatal(page.Total, len(page.Jobs), err)
	}
}

func TestHPCMissingSlurmIsActionable(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	_, err := pluginHPCCommand(t.TempDir(), "--me")
	if err == nil || !strings.Contains(err.Error(), "not installed") {
		t.Fatal(err)
	}
}

func TestHPCWarningsNeverBecomeJobRows(t *testing.T) {
	directory := t.TempDir()
	script := "#!/bin/sh\nprintf 'scheduler warning\\n' >&2\nprintf '7\\037batch\\037example\\037RUNNING\\0370:01\\0371\\037node\\n'\n"
	if err := os.WriteFile(filepath.Join(directory, "squeue"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory)
	page, err := inspectHPCJobs(directory, pluginHPCCommand)
	if err != nil || page.Total != 1 || page.Jobs[0].ID != "7" {
		t.Fatal(page, err)
	}
}

func TestHPCSchedulerTimeoutIsBounded(t *testing.T) {
	directory := t.TempDir()
	if err := os.WriteFile(filepath.Join(directory, "squeue"), []byte("#!/bin/sh\nexec /bin/sleep 30\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory)
	start := time.Now()
	_, err := pluginHPCCommand(directory, "--me")
	if err == nil || !strings.Contains(err.Error(), "within 8 seconds") || time.Since(start) > 11*time.Second {
		t.Fatal(err, time.Since(start))
	}
}
