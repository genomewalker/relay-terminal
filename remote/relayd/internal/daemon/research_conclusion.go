package daemon

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
)

type researchNotice struct {
	Schema         string `json:"schema"`
	QuestionID     string `json:"question_id"`
	Revision       uint64 `json:"revision"`
	DeliveryKey    string `json:"delivery_key"`
	EvidenceSHA256 string `json:"evidence_sha256"`
	Question       string `json:"question"`
	Disposition    string `json:"disposition"`
	Rationale      string `json:"rationale"`
}

func communicationResearchPublish(r CommunicationRequest) (map[string]any, error) {
	if !communicationSourceVerified(r) || r.ClientToken == "" {
		return nil, errors.New("authenticated research owner required")
	}
	deps, err := questionThreadDepsFromEnv()
	if err != nil {
		return nil, err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	return publishResearchConclusion(deps, r, func(reg researchRegistration, key string) (researchNotice, error) {
		return receiveResearchNotice(filepath.Join(home, ".local", "bin", "cresearch"), reg, key)
	})
}

// Run the installed Research verifier with the exact steering bytes registered by the owner.
func receiveResearchNotice(binary string, reg researchRegistration, key string) (researchNotice, error) {
	var notice researchNotice
	root, err := os.OpenRoot(reg.Workspace)
	if err != nil {
		return notice, err
	}
	defer root.Close()
	rel, err := filepath.Rel(reg.Workspace, reg.SteeringPath)
	if err != nil || !filepath.IsLocal(rel) {
		return notice, errors.New("invalid registered steering path")
	}
	f, err := root.OpenFile(rel, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return notice, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return notice, errors.New("invalid steering file")
	}
	raw, err := io.ReadAll(io.LimitReader(f, (4<<20)+1))
	sum := sha256.Sum256(raw)
	if err != nil || len(raw) > 4<<20 || hex.EncodeToString(sum[:]) != reg.SteeringSHA256 {
		return notice, errors.New("registered steering changed")
	}
	tmp, err := os.MkdirTemp("", "relay-research-receive-")
	if err != nil {
		return notice, err
	}
	defer os.RemoveAll(tmp)
	steering := filepath.Join(tmp, "steering.json")
	op := filepath.Join(tmp, "operation.json")
	args, err := json.Marshal(map[string]any{"operation": "receive_conclusion_notice", "revision": reg.Revision, "question_id": reg.QuestionID, "delivery_key": key})
	if err != nil {
		return notice, err
	}
	if err = os.WriteFile(steering, raw, 0600); err != nil {
		return notice, err
	}
	if err = os.WriteFile(op, args, 0600); err != nil {
		return notice, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, "--steering", steering, "--network-operation", op)
	cmd.Dir = reg.Workspace
	output, err := cmd.StdoutPipe()
	if err != nil {
		return notice, err
	}
	if err = cmd.Start(); err != nil {
		return notice, err
	}
	data, err := io.ReadAll(io.LimitReader(output, (64<<10)+1))
	if err != nil || len(data) > 64<<10 {
		cancel()
	}
	waitErr := cmd.Wait()
	if err != nil || len(data) > 64<<10 || waitErr != nil {
		return notice, errors.New("Research receiver could not verify this committed conclusion")
	}
	if err = json.Unmarshal(data, &notice); err != nil {
		return notice, err
	}
	return notice, nil
}

func publishResearchConclusion(deps questionThreadDeps, r CommunicationRequest, receive func(researchRegistration, string) (researchNotice, error)) (map[string]any, error) {
	revision, err := strconv.ParseUint(r.ResearchRevision, 10, 64)
	if err != nil || revision == 0 || strconv.FormatUint(revision, 10) != r.ResearchRevision || !validHostNativeUUID(r.ResearchQuestionID) || !folderDigestValid(r.DeliveryKey) {
		return nil, errors.New("invalid conclusion identity")
	}
	key := r.ResearchQuestionID + "/" + r.ResearchRevision
	load := func() (questionThreadBinding, researchRegistration, error) {
		b, found, err := deps.store.load(r.ActorPaneID)
		reg, registered := b.ResearchQuestions[key]
		if err != nil || !found || !registered || b.Incarnation == "" || b.Incarnation != r.QuestionBindingID || b.Phase != "" || b.LeasePending || b.ReleaseStage != "" || !deps.now().Before(b.RenewAt) {
			return b, reg, errors.New("active registered research question required")
		}
		return b, reg, nil
	}
	b, reg, err := load()
	if err != nil {
		return nil, err
	}
	live, err := questionBindingLive(deps, b)
	if err != nil || !live {
		return nil, errors.New("owner session unavailable")
	}
	notice, err := receive(reg, r.DeliveryKey)
	if err != nil {
		return nil, err
	}
	if notice.Schema != "research.conclusion_notice/1" || notice.QuestionID != reg.QuestionID || notice.Revision != reg.Revision || notice.DeliveryKey != r.DeliveryKey || !folderDigestValid(notice.EvidenceSHA256) || (notice.Disposition != "answered" && notice.Disposition != "inconclusive") {
		return nil, errors.New("committed notice identity mismatch")
	}
	live, err = questionBindingLive(deps, b)
	if err != nil || !live {
		return nil, errors.New("owner session changed")
	}
	err = deps.withQuestionState(func() error {
		current, saved, err := load()
		if err != nil {
			return err
		}
		if !sameQuestionBinding(current, b) || saved != reg {
			return errors.New("registration changed")
		}
		if prior, ok := current.ResearchConclusions[key]; ok {
			if prior != notice {
				return errors.New("conflicting conclusion")
			}
			return nil
		}
		if current.ResearchConclusions == nil {
			current.ResearchConclusions = map[string]researchNotice{}
		}
		current.ResearchConclusions[key] = notice
		return deps.store.save(current)
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{"status": "recorded", "question_id": reg.QuestionID, "revision": reg.Revision, "delivery_key": notice.DeliveryKey, "question_binding_id": b.Incarnation}, nil
}
