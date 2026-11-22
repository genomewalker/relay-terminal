package daemon

import (
	"errors"
	"path/filepath"

	"github.com/relay-terminal/relayd/internal/researchjob"
)

func communicationResearchStatus(root string, r CommunicationRequest) (map[string]any, error) {
	if !communicationSourceVerified(r) || r.ClientToken == "" || r.QuestionBindingID != "" {
		return nil, errors.New("research status requires an authenticated owner pane")
	}
	deps, err := questionThreadDepsFromEnv()
	if err != nil {
		return nil, err
	}
	return researchStatusForPane(deps, filepath.Join(root, "research-jobs"), r.ActorPaneID, r.ResearchJobID)
}

func researchStatusForPane(deps questionThreadDeps, jobsRoot, pane, jobID string) (map[string]any, error) {
	binding, found, err := deps.loadQuestionState(pane)
	if err != nil || !found {
		return nil, errors.New("confirmed question binding required")
	}
	live, err := questionBindingLive(deps, binding)
	if err != nil || !live {
		return nil, errors.New("question owner session unavailable")
	}
	var job researchjob.Job
	err = deps.withQuestionState(func() error {
		current, found, err := deps.store.load(pane)
		if err != nil || !found || current.Incarnation == "" || !sameQuestionBinding(current, binding) || current.Incarnation != binding.Incarnation || current.Phase != "" || current.ReleaseStage != "" || current.LeasePending || !deps.now().Before(current.RenewAt) {
			return errors.New("current confirmed question binding required")
		}
		job, err = researchjob.ReadForQuestion(jobsRoot, jobID, current.Incarnation)
		return err
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{"job": job, "authority": "relayd"}, nil
}
