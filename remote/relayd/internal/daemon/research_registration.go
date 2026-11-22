package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
)

type researchRegistration struct {
	QuestionID     string `json:"question_id"`
	Revision       uint64 `json:"revision"`
	Workspace      string `json:"workspace"`
	SteeringPath   string `json:"steering_path"`
	SteeringSHA256 string `json:"steering_sha256"`
}

func communicationResearchRegister(r CommunicationRequest) (map[string]any, error) {
	if !communicationSourceVerified(r) || r.ClientToken == "" {
		return nil, errors.New("authenticated research owner required")
	}
	deps, err := questionThreadDepsFromEnv()
	if err != nil {
		return nil, err
	}
	return registerResearchQuestion(deps, r)
}

func registerResearchQuestion(deps questionThreadDeps, r CommunicationRequest) (map[string]any, error) {
	b, found, err := deps.loadQuestionState(r.ActorPaneID)
	if err != nil || !found || b.Incarnation == "" || b.Incarnation != r.QuestionBindingID {
		return nil, errors.New("question binding changed")
	}
	live, err := questionBindingLive(deps, b)
	if err != nil || !live {
		return nil, errors.New("question owner is unavailable")
	}
	cwd, err := deps.cwd(b.PaneID)
	if err != nil {
		return nil, err
	}
	workspace, err := filepath.EvalSymlinks(cwd)
	if err != nil || !filepath.IsAbs(workspace) || !filepath.IsAbs(r.SteeringPath) {
		return nil, errors.New("absolute workspace and steering paths required")
	}
	path, err := filepath.EvalSymlinks(r.SteeringPath)
	if err != nil {
		return nil, err
	}
	rel, err := filepath.Rel(workspace, path)
	if err != nil || !filepath.IsLocal(rel) {
		return nil, errors.New("steering must belong to the owner workspace")
	}
	root, err := os.OpenRoot(workspace)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	f, err := root.OpenFile(rel, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return nil, errors.New("regular steering file required")
	}
	const limit = 4 << 20
	raw, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil || len(raw) > limit {
		return nil, errors.New("cannot read bounded steering file")
	}
	sum := sha256.Sum256(raw)
	if hex.EncodeToString(sum[:]) != r.SteeringSHA256 {
		return nil, errors.New("reviewed steering digest changed")
	}
	var steering struct {
		Revision  uint64
		Workspace string
		Pane      string `json:"relay_pane"`
		Network   struct {
			Binding struct {
				QuestionID string `json:"question_id"`
			} `json:"question_binding"`
		}
	}
	if json.Unmarshal(raw, &steering) != nil || steering.Revision == 0 || !validHostNativeUUID(steering.Network.Binding.QuestionID) || steering.Pane != b.PaneID {
		return nil, errors.New("invalid research question or pane declaration")
	}
	declared, err := filepath.EvalSymlinks(steering.Workspace)
	if err != nil || declared != workspace {
		return nil, errors.New("research workspace mismatch")
	}
	registration := researchRegistration{steering.Network.Binding.QuestionID, steering.Revision, workspace, path, r.SteeringSHA256}
	key := registration.QuestionID + "/" + strconv.FormatUint(registration.Revision, 10)
	err = deps.withQuestionState(func() error {
		current, found, err := deps.store.load(b.PaneID)
		if err != nil || !found || !sameQuestionBinding(b, current) || current.Phase != "" || current.LeasePending || current.ReleaseStage != "" || !deps.now().Before(current.RenewAt) {
			return errors.New("confirmed owner lease required")
		}
		if prior, ok := current.ResearchQuestions[key]; ok {
			if prior != registration {
				return errors.New("research question already registered with different steering")
			}
			return nil
		}
		if current.ResearchQuestions == nil {
			current.ResearchQuestions = make(map[string]researchRegistration)
		}
		current.ResearchQuestions[key] = registration
		return deps.store.save(current)
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{"status": "registered", "question_id": registration.QuestionID, "revision": registration.Revision, "question_binding_id": b.Incarnation, "steering_sha256": registration.SteeringSHA256}, nil
}
