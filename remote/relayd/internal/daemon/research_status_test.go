package daemon

import (
	"context"
	"encoding/json"
	"github.com/relay-terminal/relayd/internal/researchjob"
	"os"
	"path/filepath"
	"testing"
)

func TestResearchStatusFromOwnerLease(t *testing.T) {
	fx := newQuestionFixture(t, "codex")
	b, err := bindQuestionThread(context.Background(), fx.deps, "pane-1", "thread-a", "realm-1", 60)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	const id = "7cca9135-83ed-46f9-ad6b-32df6e580b03"
	const request = "7cca9135-83ed-46f9-ad6b-32df6e580b04"
	for _, dir := range []string{"jobs", "requests"} {
		if err := os.Mkdir(filepath.Join(root, dir), 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "jobs", id), []byte(request), 0600); err != nil {
		t.Fatal(err)
	}
	job := researchjob.Job{RequestID: request, JobID: id, State: researchjob.StateRunning}
	job.Binding.QuestionBindingID = b.Incarnation
	save := func() {
		t.Helper()
		raw, err := json.Marshal(job)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "requests", request+".json"), raw, 0600); err != nil {
			t.Fatal(err)
		}
	}
	save()
	got, err := researchStatusForPane(fx.deps, root, b.PaneID, id)
	if err != nil || got["job"].(researchjob.Job).State != researchjob.StateRunning {
		t.Fatalf("owner: %v %v", got, err)
	}
	job.Binding.QuestionBindingID = request
	save()
	if got, err := researchStatusForPane(fx.deps, root, b.PaneID, id); err == nil || got != nil {
		t.Fatal("foreign result disclosed")
	}
	job.Binding.QuestionBindingID = b.Incarnation
	save()
	fx.binding.SessionID = "replacement"
	if got, err := researchStatusForPane(fx.deps, root, b.PaneID, id); err == nil || got != nil {
		t.Fatal("replaced session could read")
	}
}
