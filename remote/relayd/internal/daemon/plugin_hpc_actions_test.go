package daemon

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

const testHPCAction = "01234567-0123-0123-0123-012345678901"

func ownedJob(string, string) (*PluginHPCDetail, error) { return &PluginHPCDetail{ID: "123"}, nil }

func TestHPCSubmissionIntentAndNoReplay(t *testing.T) {
	ledger := filepath.Join(t.TempDir(), "receipts")
	req := PluginRequest{Operation: "hpcSubmit", Root: "/reviewed", Script: "#!/bin/bash\necho test\n", ActionID: testHPCAction, Confirmed: true}
	calls := 0
	run := func(root, name, input string, args ...string) (string, error) {
		calls++
		if root != "/reviewed" || name != "sbatch" || input != req.Script || !reflect.DeepEqual(args, []string{"--parsable", "--export=NIL", "--chdir=/reviewed"}) {
			t.Fatal("unreviewed command", root, name, args)
		}
		data, err := os.ReadFile(filepath.Join(ledger, testHPCAction+".jsonl"))
		if err != nil || !strings.Contains(string(data), `"outcome":"unknown"`) {
			t.Fatal("intent not durable before dispatch", err)
		}
		if strings.Contains(string(data), "echo test") {
			t.Fatal("script leaked into receipt")
		}
		return "456;cluster\n", nil
	}
	if _, err := performHPCAction(req, ledger, run, ownedJob); err != nil {
		t.Fatal(err)
	}
	if _, err := performHPCAction(req, ledger, run, ownedJob); err == nil {
		t.Fatal("replayed submission")
	}
	if calls != 1 {
		t.Fatal(calls)
	}
}

func TestHPCUnknownOutcomeIsNeverRetried(t *testing.T) {
	for _, bad := range []bool{false, true} {
		ledger := filepath.Join(t.TempDir(), "receipts")
		req := PluginRequest{Operation: "hpcSubmit", Root: "/", Script: "#!/bin/sh\ntrue\n", ActionID: testHPCAction, Confirmed: true}
		calls := 0
		run := func(string, string, string, ...string) (string, error) {
			calls++
			if bad {
				return "unexpected output", nil
			}
			return "", errors.New("connection lost")
		}
		if _, err := performHPCAction(req, ledger, run, ownedJob); err == nil || !strings.Contains(err.Error(), "outcome unknown") {
			t.Fatal(err)
		}
		if _, err := performHPCAction(req, ledger, run, ownedJob); err == nil {
			t.Fatal("retried unknown outcome")
		}
		if calls != 1 {
			t.Fatal(calls)
		}
	}
}

func TestHPCCancelRequiresOwnershipAndExplicitConfirmation(t *testing.T) {
	req := PluginRequest{Operation: "hpcCancel", Root: "/", JobID: "123", ActionID: testHPCAction, Confirmed: true}
	calls := 0
	run := func(root, name, input string, args ...string) (string, error) {
		calls++
		if name != "scancel" || input != "" || !reflect.DeepEqual(args, []string{"--user=" + strconv.Itoa(os.Getuid()), "123"}) {
			t.Fatal(name, args)
		}
		return "", nil
	}
	for _, details := range []func(string, string) (*PluginHPCDetail, error){
		func(string, string) (*PluginHPCDetail, error) { return nil, errors.New("not owned") },
		func(string, string) (*PluginHPCDetail, error) { return &PluginHPCDetail{Array: true}, nil },
	} {
		if _, err := performHPCAction(req, filepath.Join(t.TempDir(), "receipts"), run, details); err == nil {
			t.Fatal("unsafe cancel accepted")
		}
	}
	req.Confirmed = false
	if _, err := performHPCAction(req, t.TempDir(), run, ownedJob); err == nil {
		t.Fatal("unconfirmed")
	}
	if calls != 0 {
		t.Fatal("dispatched unauthorized cancellation")
	}
	req.Confirmed = true
	if _, err := performHPCAction(req, filepath.Join(t.TempDir(), "receipts"), run, ownedJob); err != nil {
		t.Fatal(err)
	}
	if calls != 1 {
		t.Fatal(calls)
	}
}

func TestHPCConcurrentSubmissionDispatchesOnce(t *testing.T) {
	ledger := filepath.Join(t.TempDir(), "receipts")
	req := PluginRequest{Operation: "hpcSubmit", Root: "/", Script: "#!/bin/sh\ntrue\n", ActionID: testHPCAction, Confirmed: true}
	var count atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _ = performHPCAction(req, ledger, func(string, string, string, ...string) (string, error) { count.Add(1); return "123", nil }, ownedJob)
		}()
	}
	wg.Wait()
	if count.Load() != 1 {
		t.Fatal(count.Load())
	}
}

func TestHPCMutationSubprocessUsesStdinAndDropsSchedulerOverrides(t *testing.T) {
	directory := t.TempDir()
	fixture := "#!/bin/sh\n[ -z \"$SBATCH_PARTITION$SCANCEL_USER$SLURM_CLUSTERS\" ] || exit 41\nIFS= read -r first\n[ \"$first\" = '#!/bin/bash' ] || exit 42\nprintf '321\\n'\n"
	if err := os.WriteFile(filepath.Join(directory, "sbatch"), []byte(fixture), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory)
	t.Setenv("SBATCH_PARTITION", "unreviewed")
	t.Setenv("SCANCEL_USER", "someone-else")
	t.Setenv("SLURM_CLUSTERS", "elsewhere")
	output, err := pluginMutationCommand(directory, "sbatch", "#!/bin/bash\necho fixture\n", "--parsable", "--export=NIL", "--chdir="+directory)
	if err != nil || output != "321\n" {
		t.Fatal(output, err)
	}
}
