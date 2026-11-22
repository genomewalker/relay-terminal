package daemon

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestResearchConclusionReplayUsesExistingQuestion(t *testing.T) {
	for _, disposition := range []string{"answered", "inconclusive"} {
		t.Run(disposition, func(t *testing.T) {
			fx := newQuestionFixture(t, "codex")
			const pane = "f84f1c81-b9bd-4ebb-a804-de367230d51e"
			const q = "6fd184c4-5705-445c-b3b7-be1d5f951266"
			b, err := bindQuestionThread(context.Background(), fx.deps, pane, "thread-a", "realm-1", 60)
			if err != nil {
				t.Fatal(err)
			}
			b.ResearchQuestions = map[string]researchRegistration{q + "/1": {QuestionID: q, Revision: 1}}
			if err := fx.deps.store.save(b); err != nil {
				t.Fatal(err)
			}
			req := CommunicationRequest{ActorPaneID: pane, ResearchQuestionID: q, ResearchRevision: "1", DeliveryKey: strings.Repeat("a", 64), QuestionBindingID: b.Incarnation}
			notice := researchNotice{Schema: "research.conclusion_notice/1", QuestionID: q, Revision: 1, DeliveryKey: req.DeliveryKey, EvidenceSHA256: strings.Repeat("b", 64), Disposition: disposition, Question: "Which candidate passed?", Rationale: "Fixture result."}
			reads := 0
			receive := func(reg researchRegistration, key string) (researchNotice, error) {
				reads++
				if reg.QuestionID != q || reg.Revision != 1 || key != notice.DeliveryKey {
					t.Fatal("wrong Research input")
				}
				return notice, nil
			}
			for i := 0; i < 2; i++ {
				got, err := publishResearchConclusion(fx.deps, req, receive)
				if err != nil || got["status"] != "recorded" {
					t.Fatalf("%v %v", got, err)
				}
			}
			stored, _, err := fx.deps.store.load(pane)
			if err != nil || len(stored.ResearchConclusions) != 1 || stored.ResearchConclusions[q+"/1"] != notice {
				t.Fatal("durable notice mismatch")
			}
			notice.Rationale = "conflict"
			if _, err := publishResearchConclusion(fx.deps, req, receive); err == nil {
				t.Fatal("changed content accepted")
			}
			req.QuestionBindingID = q
			if _, err := publishResearchConclusion(fx.deps, req, receive); err == nil || reads != 3 {
				t.Fatal("foreign binding reached Research")
			}
		})
	}
}

func TestResearchReceiverUsesPinnedSteeringBytes(t *testing.T) {
	root := t.TempDir()
	raw := []byte(`{"revision":1}`)
	reg := researchRegistration{Workspace: root, SteeringPath: filepath.Join(root, "steering.json"), SteeringSHA256: fmt.Sprintf("%x", sha256.Sum256(raw)), Revision: 1, QuestionID: "6fd184c4-5705-445c-b3b7-be1d5f951266"}
	if err := os.WriteFile(reg.SteeringPath, raw, 0600); err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(root, "fixture-receiver")
	const script = `#!/bin/sh
set -eu
test "$1" = "--steering"
test "$3" = "--network-operation"
cmp "$2" ./steering.json
grep -q '"operation":"receive_conclusion_notice"' "$4"
echo '{"schema":"research.conclusion_notice/1","revision":1,"disposition":"inconclusive"}'
`
	if err := os.WriteFile(bin, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	got, err := receiveResearchNotice(bin, reg, strings.Repeat("a", 64))
	if err != nil || got.Disposition != "inconclusive" {
		t.Fatalf("receiver: %v %v", got, err)
	}
	if err := os.WriteFile(reg.SteeringPath, []byte("{}"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := receiveResearchNotice(bin, reg, strings.Repeat("a", 64)); err == nil {
		t.Fatal("receiver accepted changed steering")
	}
}
