package capacity

import (
	"bytes"
	"encoding/json"
	"errors"
	"path/filepath"
)

// These are descriptive references to the canonical Chitta capsule and exact
// external job evidence. They are never lifecycle authorization or commands.
type Canonical struct {
	Session      string `json:"session"`
	Revision     uint64 `json:"revision"`
	SHA256       string `json:"sha256"`
	LedgerSeq    uint64 `json:"ledger_seq"`
	SourceSHA256 string `json:"source_sha256"`
}
type Job struct {
	ID             string `json:"id"`
	Host           string `json:"host"`
	Boot           string `json:"boot"`
	PID            int    `json:"pid"`
	Start          uint64 `json:"start"`
	State          string `json:"state"`
	EvidenceSHA256 string `json:"evidence_sha256"`
	Log            string `json:"log"`
	Brief          string `json:"brief"`
	Output         string `json:"output"`
	NextAction     string `json:"next_action"`
}
type Preparation struct {
	CanonicalJSON       json.RawMessage `json:"canonical_json"`
	LinkState           string          `json:"link_state"`
	Source              Source          `json:"source"`
	Capsule             Canonical       `json:"capsule"`
	Jobs                []Job           `json:"jobs"`
	InventoryComplete   bool            `json:"inventory_complete"`
	ScheduledTasksKnown bool            `json:"scheduled_tasks_known"`
	Falsifiers          string          `json:"falsifiers"`
}

// ValidatePreparation permits only exact source-bound canonical references and
// attested surviving/completed jobs. Unknown scheduled tasks fail independently
// of whether an OS child exists. No task/command recreation is provided.
func ValidatePreparation(p Preparation, source Source, sourceHash string, turn uint64) error {
	if !source.Valid() || p.Source != source || !hexDigest(sourceHash) || p.Capsule.Session != source.Session || p.Capsule.Revision == 0 || !hexDigest(p.Capsule.SHA256) || p.Capsule.SourceSHA256 != sourceHash || p.Capsule.LedgerSeq != turn {
		return errors.New("canonical_source_coverage_unavailable")
	}
	if len(p.CanonicalJSON) == 0 || len(p.CanonicalJSON) > 4096 || Hash(p.CanonicalJSON) != p.Capsule.SHA256 {
		return errors.New("canonical_exact_bytes_hash_unavailable")
	}
	canonical, err := canonicalWireObject(p.CanonicalJSON)
	if err != nil {
		return err
	}
	allowed := map[string]bool{}
	for _, k := range []string{"version", "revision", "saved_at", "source", "ledger_seq", "objective", "repository", "project_dir", "session_id", "stream_id", "branch", "code_head", "next_action", "state", "constraints", "dirty_paths", "blockers", "gates", "jobs"} {
		allowed[k] = true
	}
	for k := range canonical {
		if !allowed[k] {
			return errors.New("canonical_capsule_unknown_field")
		}
	}
	var version int
	var revision, sequence uint64
	var session, origin string
	var constraints []string
	if json.Unmarshal(canonical["version"], &version) != nil || version != 2 || json.Unmarshal(canonical["revision"], &revision) != nil || revision != p.Capsule.Revision || json.Unmarshal(canonical["ledger_seq"], &sequence) != nil || sequence != p.Capsule.LedgerSeq || json.Unmarshal(canonical["session_id"], &session) != nil || session != source.Session || json.Unmarshal(canonical["source"], &origin) != nil || origin != "explicit" || json.Unmarshal(canonical["constraints"], &constraints) != nil || len(constraints) > 4 {
		return errors.New("canonical_capsule_binding_unavailable")
	}
	manifest, err := PreparationManifestHash(p)
	if err != nil {
		return err
	}
	sourceLinked, jobsLinked := false, false
	for _, claim := range constraints {
		sourceLinked = sourceLinked || claim == "relay.source.sha256="+sourceHash
		jobsLinked = jobsLinked || claim == "relay.jobs.sha256="+manifest
	}
	if !sourceLinked || !jobsLinked {
		return errors.New("canonical_source_or_job_manifest_reference_unavailable")
	}
	if !p.InventoryComplete {
		return errors.New("complete_job_inventory_unavailable")
	}
	if !p.ScheduledTasksKnown {
		return errors.New("scheduled_task_inventory_unavailable")
	}
	if p.LinkState != "user_reviewed_exact_lineage" {
		return errors.New("links_require_user_review")
	}
	if p.Falsifiers != "confirmed" {
		return errors.New("required_falsifier_unconfirmed")
	}
	if len(p.Jobs) > 128 {
		return errors.New("job_manifest_bound")
	}
	seen := map[string]bool{}
	for _, j := range p.Jobs {
		if !identifier(j.ID) || seen[j.ID] || j.Host != source.Host || !identifier(j.Boot) || j.PID <= 1 || j.Start == 0 || !hexDigest(j.EvidenceSHA256) || len(j.NextAction) > 400 {
			return errors.New("job_identity_or_evidence_unavailable")
		}
		seen[j.ID] = true
		if j.State != "independent" && j.State != "checkpointed" && j.State != "finished" {
			return errors.New("job_preservation_unavailable")
		}
		for _, path := range []string{j.Log, j.Brief, j.Output} {
			if !filepath.IsAbs(path) || len(path) > 4096 {
				return errors.New("job_artifact_unavailable")
			}
		}
	}
	return nil
}
func DecodePreparation(raw []byte) (Preparation, error) {
	var p Preparation
	if err := Decode(raw, &p); err != nil {
		return p, err
	}
	_, err := canonicalWireObject(p.CanonicalJSON)
	return p, err
}

// The capsule is SHA-bound exact evidence. Never silently normalize it:
// RawMessage is compacted/HTML-escaped by the outer JSON encoder.
func canonicalWireObject(raw json.RawMessage) (map[string]json.RawMessage, error) {
	var canonical map[string]json.RawMessage
	if len(raw) == 0 || len(raw) > 4096 || Decode(raw, &canonical) != nil || canonical == nil {
		return nil, errors.New("canonical_capsule_object_required")
	}
	wire, err := json.Marshal(raw)
	if err != nil || !bytes.Equal(wire, raw) {
		return nil, errors.New("canonical_capsule_exact_wire_bytes_required")
	}
	return canonical, nil
}
func CanonicalHash(value any) (string, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	return Hash(data), nil
}

// This is a hash of external descriptive evidence, not another canonical task
// store. The existing canonical capsule must reference these exact bytes/hash.
func PreparationManifestHash(p Preparation) (string, error) {
	type evidence struct {
		Source     Source `json:"source"`
		Jobs       []Job  `json:"jobs"`
		Complete   bool   `json:"complete"`
		Scheduled  bool   `json:"scheduled"`
		Falsifiers string `json:"falsifiers"`
		Links      string `json:"links"`
	}
	raw, err := json.Marshal(evidence{p.Source, p.Jobs, p.InventoryComplete, p.ScheduledTasksKnown, p.Falsifiers, p.LinkState})
	if err != nil {
		return "", err
	}
	return Hash(raw), nil
}
