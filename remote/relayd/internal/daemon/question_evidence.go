package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"time"
)

const questionEvidenceLimit = 16

type questionEvidenceRow struct {
	EntryID          string          `json:"entry_id"`
	ThreadID         string          `json:"thread_id"`
	Kind             string          `json:"kind"`
	Text             string          `json:"text"`
	Body             string          `json:"body,omitempty"`
	Revision         uint64          `json:"revision"`
	Assessment       string          `json:"assessment,omitempty"`
	Verification     string          `json:"verification"`
	Check            json.RawMessage `json:"check,omitempty"`
	Refs             json.RawMessage `json:"refs"`
	Freshness        json.RawMessage `json:"freshness"`
	Subject          json.RawMessage `json:"subject,omitempty"`
	SubjectFreshness json.RawMessage `json:"subject_freshness,omitempty"`
}

func communicationQuestionEvidence(r CommunicationRequest) (map[string]any, error) {
	// Only the desktop's existing owner channel can request evidence. No policy
	// import, lease, notice, or host job is needed to answer this read.
	if r.ActorPaneID != "" || r.ClientToken != "" || r.SourcePaneID != "" {
		return nil, errors.New("owner question evidence request required")
	}
	deps, err := questionThreadDepsFromEnv()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	return readQuestionEvidence(ctx, deps, r)
}

func readQuestionEvidence(ctx context.Context, deps questionThreadDeps, r CommunicationRequest) (map[string]any, error) {
	if !validSessionID.MatchString(r.PaneID) {
		return nil, errors.New("invalid question evidence pane")
	}
	metadataOnly := r.ThreadID == "" && r.Realm == "" && r.QuestionBindingID == ""
	if !metadataOnly && (!questionThreadID.MatchString(r.ThreadID) || !questionRealm.MatchString(r.Realm) ||
		!validSessionID.MatchString(r.QuestionBindingID)) {
		return nil, errors.New("invalid question evidence attachment")
	}
	status := func(value string) map[string]any { return map[string]any{"status": value} }
	// Binding records are replaced atomically. Reading without the mutation
	// lock avoids creating state on an unbound host. Recheck after I/O below.
	load := func() (questionThreadBinding, string) {
		b, found, err := deps.store.load(r.PaneID)
		if err != nil {
			return b, "unavailable"
		}
		if !found || b.Phase != "" || b.ReleaseStage != "" || b.LeasePending {
			return b, "unattached"
		}
		if !validSessionID.MatchString(b.Incarnation) || !questionThreadID.MatchString(b.ThreadID) || !questionRealm.MatchString(b.Realm) {
			return b, "unavailable"
		}
		if !metadataOnly && (b.ThreadID != r.ThreadID || b.Realm != r.Realm || b.Incarnation != r.QuestionBindingID) {
			return b, "attachment_changed"
		}
		live, err := questionBindingLive(deps, b)
		if err != nil || !live {
			return b, "unavailable"
		}
		return b, ""
	}
	b, unavailable := load()
	if unavailable != "" {
		return status(unavailable), nil
	}
	result := map[string]any{"status": "attached", "attachment": map[string]string{
		"pane_id": b.PaneID, "thread_id": b.ThreadID, "realm": b.Realm, "binding_id": b.Incarnation,
	}}
	if metadataOnly {
		return result, nil
	}
	if realm, ok := questionStateRealm(ctx, deps, b.ThreadID); !ok || realm != b.Realm {
		return status("unavailable"), nil
	}
	raw, err := questionCall(ctx, deps, "evidence_get", map[string]any{"thread_id": b.ThreadID})
	var payload struct {
		Rows []questionEvidenceRow `json:"rows"`
	}
	if err != nil || len(raw) > 256<<10 || json.Unmarshal(raw, &payload) != nil || payload.Rows == nil {
		return status("unavailable"), nil
	}
	for _, row := range payload.Rows {
		if row.ThreadID != b.ThreadID || row.EntryID == "" || row.Kind == "" {
			return status("unavailable"), nil
		}
	}
	if b, unavailable = load(); unavailable != "" {
		return status(unavailable), nil
	}
	sort.SliceStable(payload.Rows, func(i, j int) bool { return payload.Rows[i].Revision > payload.Rows[j].Revision })
	result["status"] = "ready"
	result["total"] = len(payload.Rows)
	result["rows"] = payload.Rows[:min(len(payload.Rows), questionEvidenceLimit)]
	notices := make([]researchNotice, 0, len(b.ResearchConclusions))
	for _, notice := range b.ResearchConclusions {
		notices = append(notices, notice)
	}
	sort.Slice(notices, func(i, j int) bool {
		if notices[i].QuestionID == notices[j].QuestionID {
			return notices[i].Revision < notices[j].Revision
		}
		return notices[i].QuestionID < notices[j].QuestionID
	})
	result["research_conclusions"] = notices
	return result, nil
}
