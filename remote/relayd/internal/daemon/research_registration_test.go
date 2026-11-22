package daemon

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestResearchRegistrationPinsOwnerAndReviewedRevision(t *testing.T) {
	fx := newQuestionFixture(t, "codex")
	root := t.TempDir()
	fx.deps.cwd = func(string) (string, error) { return root, nil }
	const pane = "f84f1c81-b9bd-4ebb-a804-de367230d51e"
	const q = "6fd184c4-5705-445c-b3b7-be1d5f951266"
	b, err := bindQuestionThread(context.Background(), fx.deps, pane, "thread-a", "realm-1", 60)
	if err != nil {
		t.Fatal(err)
	}
	raw := []byte(fmt.Sprintf(`{"revision":1,"relay_pane":%q,"workspace":%q,"network":{"question_binding":{"question_id":%q,"checkpoint":"checkpoint.json"}}}`, pane, root, q))
	path := filepath.Join(root, "steering.json")
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	r := CommunicationRequest{ActorPaneID: pane, QuestionBindingID: b.Incarnation, SteeringPath: path, SteeringSHA256: fmt.Sprintf("%x", sha256.Sum256(raw))}
	if _, err := communicationResearchRegister(r); err == nil {
		t.Fatal("unproven request accepted")
	}
	for i := 0; i < 2; i++ {
		got, err := registerResearchQuestion(fx.deps, r)
		if err != nil || got["question_id"] != q {
			t.Fatalf("register %d: %v %v", i, got, err)
		}
	}
	stored, _, err := fx.deps.store.load(pane)
	if err != nil || len(stored.ResearchQuestions) != 1 || stored.ResearchQuestions[q+"/1"].SteeringSHA256 != r.SteeringSHA256 {
		t.Fatal("registration missing after reload")
	}
	bad := r
	bad.QuestionBindingID = q
	if _, err := registerResearchQuestion(fx.deps, bad); err == nil {
		t.Fatal("stale binding accepted")
	}
	if err := os.WriteFile(path, append(raw, ' '), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := registerResearchQuestion(fx.deps, r); err == nil {
		t.Fatal("changed bytes accepted with previous digest")
	}
	r.SteeringSHA256 = fmt.Sprintf("%x", sha256.Sum256(append(raw, ' ')))
	if _, err := registerResearchQuestion(fx.deps, r); err == nil {
		t.Fatal("same revision replaced")
	}
}
