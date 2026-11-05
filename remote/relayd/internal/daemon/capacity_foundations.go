package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/relay-terminal/relayd/internal/agentaccounts"
	"github.com/relay-terminal/relayd/internal/capacity"
)

// This route shares authenticated host settings transport with Miko/native
// account settings. It accepts policy/action data, never process/launch code,
// native capabilities, source identities, preservation flags or credentials.
type capacityRequest struct {
	V         int                `json:"v"`
	Operation string             `json:"operation"`
	ID        string             `json:"id,omitempty"`
	Expected  *uint64            `json:"expected_revision,omitempty"`
	Pane      string             `json:"pane_id,omitempty"`
	Settings  *capacity.Settings `json:"settings,omitempty"`
	Target    string             `json:"target_account,omitempty"`
}
type capacityReply struct {
	Managed            bool                  `json:"managed"`
	V                  int                   `json:"v"`
	Revision           uint64                `json:"revision"`
	Settings           capacity.Settings     `json:"settings"`
	State              string                `json:"state"`
	Reason             string                `json:"reason"`
	Source             *capacity.Source      `json:"source,omitempty"`
	Supported          bool                  `json:"supported"`
	Enabled            bool                  `json:"enabled"`
	Ready              bool                  `json:"ready"`
	Capabilities       capacity.Capabilities `json:"capabilities"`
	Decision           *capacity.Decision    `json:"decision,omitempty"`
	Entry              *capacity.Entry       `json:"entry,omitempty"`
	Operation          *capacity.Operation   `json:"operation,omitempty"`
	Accounts           []capacity.Account    `json:"accounts"`
	RegisteredAccounts []string              `json:"registered_accounts"`
}

func nodeCapacityEnvelope(data []byte) bool {
	var e struct {
		Forward struct {
			Request struct {
				Operation string `json:"operation"`
			} `json:"request"`
		} `json:"host_accounts"`
	}
	return len(data) <= capacity.MaxJSON && json.Unmarshal(data, &e) == nil && strings.HasPrefix(e.Forward.Request.Operation, "capacity_")
}
func decodeCapacityEnvelope(data []byte) (string, capacityRequest, error) {
	var e struct {
		ID        string `json:"request_id"`
		Operation string `json:"operation"`
		Forward   *struct {
			Request capacityRequest `json:"request"`
		} `json:"host_accounts"`
	}
	var zero capacityRequest
	if capacity.Decode(data, &e) != nil || e.Operation != "host_accounts" || !validSessionID.MatchString(e.ID) || e.Forward == nil {
		return "", zero, errors.New("invalid capacity envelope")
	}
	r := e.Forward.Request
	if r.V != 1 {
		return "", zero, errors.New("unsupported capacity version")
	}
	switch r.Operation {
	case "capacity_status":
		if r.ID != "" || r.Expected != nil || r.Settings != nil || r.Target != "" {
			return "", zero, errors.New("read-only capacity status required")
		}
	case "capacity_configure":
		if !validPromptEditorID(r.ID) || r.Expected == nil || r.Settings == nil || !r.Settings.Valid() || r.Pane != "" || r.Target != "" {
			return "", zero, errors.New("native capacity settings invalid")
		}
	case "capacity_enroll", "capacity_pause", "capacity_resume", "capacity_pin", "capacity_unpin", "capacity_register_new", "capacity_observe", "capacity_manual_refresh", "capacity_manual_move", "capacity_user_release":
		if !validPromptEditorID(r.ID) || r.Expected == nil || !validSessionID.MatchString(r.Pane) || r.Settings != nil {
			return "", zero, errors.New("capacity action invalid")
		}
		if r.Operation != "capacity_manual_move" && r.Target != "" {
			return "", zero, errors.New("unexpected capacity target")
		}
	default:
		return "", zero, errors.New("unsupported capacity action")
	}
	if r.Pane != "" && !validSessionID.MatchString(r.Pane) {
		return "", zero, errors.New("invalid capacity pane")
	}
	return e.ID, r, nil
}
func handleNodeCapacityRequest(ctx context.Context, data []byte, root string, observe func(context.Context, string) (capacity.Source, capacity.Counters, error), accounts func(context.Context, capacity.Settings, capacity.Source, int64) ([]capacity.Account, []string, error)) ([]byte, error) {
	id, r, err := decodeCapacityEnvelope(data)
	if err != nil {
		return nil, err
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	j := capacity.Journal{Root: filepath.Join(root, "capacity")}
	disk, err := j.Load()
	if err != nil {
		return json.Marshal(map[string]any{"request_id": id, "error": "capacity journal requires review: " + err.Error()})
	}
	reply := capacityReply{V: 1, Revision: disk.Revision, Settings: disk.Settings, State: "not_enrolled", Reason: capacity.RetirementHold, Capabilities: capacity.Unsupported("native"), Accounts: []capacity.Account{}, RegisteredAccounts: []string{}}
	// Lane ownership survives missing process/ledger observations. A successful
	// held response must never send a managed pane back to the legacy executor.
	if entry, exists := disk.Entries[r.Pane]; exists {
		reply.Entry = &entry
		reply.Managed = entry.Managed
		reply.Enabled = entry.Enabled
	}
	var operationRevision uint64
	for _, operation := range disk.Operations {
		receipt := disk.Receipts["plan-"+operation.Plan.ID]
		if r.Pane != "" && operation.Plan.Source.Pane == r.Pane && receipt.Revision >= operationRevision {
			v := operation
			reply.Operation = &v
			operationRevision = receipt.Revision
		}
	}
	now := time.Now().UnixMilli()
	var source capacity.Source
	var counters capacity.Counters
	if r.Pane != "" {
		source, counters, err = observe(ctx, r.Pane)
		if err != nil {
			reply.State = "native_evidence_unavailable"
			reply.Reason = err.Error()
			if reply.Operation != nil {
				reply.State = "held_recovery_required"
				reply.Reason = "Native source evidence unavailable; original operation " + reply.Operation.Plan.ID + " is " + reply.Operation.State + " (" + reply.Operation.Reason + "). No exit/launch is replayed. " + err.Error()
			}
			if r.Operation != "capacity_status" && r.Operation != "capacity_pause" {
				return json.Marshal(map[string]any{"request_id": id, "error": err.Error()})
			}
			// Status and pause deliberately retain the durable lane owner while
			// exposing missing observations in the held reply above.
			err = nil
		} else {
			reply.Source = &source
			reply.Supported = source.Valid()
			reply.Capabilities = capacity.Unsupported(source.Provider)
		}
	}
	if r.Operation == "capacity_manual_move" {
		permitted := capacity.IsApproved(disk.Settings, source.Provider, r.Target)
		if r.Target == "" || !permitted {
			return json.Marshal(map[string]any{"request_id": id, "error": "target account is not explicitly approved"})
		}
	}
	requestBytes, _ := json.Marshal(r)
	hash := capacity.Hash(requestBytes)
	if old, ok := disk.Operations[r.ID]; ok && (r.Operation == "capacity_observe" || r.Operation == "capacity_manual_refresh" || r.Operation == "capacity_manual_move") {
		receipt, exists := disk.Receipts[r.ID]
		if !exists || receipt.Hash != hash {
			return json.Marshal(map[string]any{"request_id": id, "error": "capacity action ID conflicts with original request"})
		}
		reply.Operation = &old
		reply.State = old.State
		reply.Reason = old.Reason
		return json.Marshal(map[string]any{"request_id": id, "result": reply})
	}
	if r.Operation == "capacity_configure" {
		disk, err = j.Update(r.ID, hash, *r.Expected, func(d *capacity.Disk) error { d.Settings = *r.Settings; return nil })
	} else if r.Operation != "capacity_status" {
		// Only native observations supply the source. Requests cannot supply a PID,
		// account directory, turn, session, capability or complete-work assertion.
		disk, err = j.Update(r.ID, hash, *r.Expected, func(d *capacity.Disk) error {
			e, exists := d.Entries[r.Pane]
			switch r.Operation {
			case "capacity_enroll":
				if exists && (e.Takeover || e.OptOut || e.Pinned || e.Manual) {
					return errors.New("explicit user ownership/pause requires native review")
				}
				if exists && e.Source != source {
					return errors.New("native source changed; review before reenrollment")
				}
				if !exists {
					e = capacity.Entry{Source: source, Baseline: counters.Tokens, BaselineTurn: counters.Turn}
				}
				e.Managed = true
				e.Enabled = true
			case "capacity_register_new":
				if exists {
					return errors.New("existing pane is never default-enrolled or migrated")
				}
				// Actual providers have no supported lifecycle contract yet. A first-read
				// or client flag cannot manufacture default enrollment readiness.
				e = capacity.NewEntry(source, d.Settings, true, false)
			case "capacity_user_release":
				if !exists || e.Source != source || e.Pinned {
					return errors.New("current native identity and unpinned user review required")
				}
				e.Takeover = false
				e.UserGeneration++
				e.Enabled = !e.OptOut && !e.Pinned
			case "capacity_observe", "capacity_manual_refresh", "capacity_manual_move":
				if !exists {
					return errors.New("explicit capacity enrollment required")
				}
				if e.Source != source {
					return errors.New("source_changed_requires_native_review")
				}
			default:
				if !exists {
					return errors.New("capacity enrollment unavailable")
				}
				// Pausing is lawful even if native source changed; resuming never adopts it.
				if r.Operation != "capacity_pause" && e.Source != source {
					return errors.New("source_changed_requires_native_review")
				}
				var changeErr error
				e, changeErr = e.ApplyUserState(strings.TrimPrefix(r.Operation, "capacity_"))
				if changeErr != nil {
					return changeErr
				}
			}
			if e.Baseline == 0 && counters.Session == source.Session && counters.Turn > 0 && counters.Tokens > 0 && counters.ObservedMS > 0 && now >= counters.ObservedMS && now-counters.ObservedMS <= capacity.MaxAgeMS {
				e.Baseline = counters.Tokens
				e.BaselineTurn = counters.Turn
			}
			d.Entries[r.Pane] = e
			return nil
		})
	}
	if err != nil {
		return json.Marshal(map[string]any{"request_id": id, "error": err.Error()})
	}
	reply.Revision = disk.Revision
	reply.Settings = disk.Settings
	if entry, exists := disk.Entries[r.Pane]; exists {
		reply.Entry = &entry
		reply.Managed = entry.Managed
		reply.Enabled = entry.Enabled
	}
	if source.Valid() {
		as, registered, e := accounts(ctx, disk.Settings, source, now)
		if e == nil {
			for i := range as {
				if reservation, ok := disk.Reservations[as[i].Provider+":"+as[i].Label]; ok {
					as[i].Reserved = reservation.Pending || as[i].ObservedMS <= reservation.AfterMS
				}
			}
			reply.Accounts = as
			reply.RegisteredAccounts = registered
		}
		if entry, exists := disk.Entries[r.Pane]; exists {
			if entry.Source != source {
				reply.State = "source_changed_requires_native_review"
				reply.Reason = "Current native identity differs; previous intent cannot act. A past manual move is not an explicit pin in rebalance mode, but adopting its new source still needs current lawful admission."
			} else {
				decision := capacity.Decide(entry, disk.Settings, counters, reply.Accounts, now)
				reply.Decision = &decision
				reply.State = decision.State
				reply.Reason = strings.Join(decision.Reasons, "; ")
				if reply.Operation != nil {
					reply.State = reply.Operation.State
					reply.Reason = reply.Operation.Reason
				}
				if r.Operation == "capacity_manual_refresh" || r.Operation == "capacity_manual_move" || r.Operation == "capacity_observe" && (decision.ContextDue || decision.QuotaDue || decision.ReturnDue || decision.RebalanceDue) {
					target, targetConfig := decision.Target, decision.TargetConfig
					if r.Operation == "capacity_manual_refresh" {
						target = source.Account
						targetConfig = source.Config
					}
					if r.Target != "" {
						for _, a := range as {
							if a.Label == r.Target {
								target = a.Label
								targetConfig = a.Config
							}
						}
					}
					p := capacity.Plan{ID: r.ID, Source: source, Target: target, TargetConfig: targetConfig, NewSession: r.ID, Mode: "fresh_context", UserGeneration: entry.UserGeneration, PolicyRevision: disk.Revision, SettingsSHA256: capacity.SettingsHash(disk.Settings), Reasons: []string{strings.TrimPrefix(r.Operation, "capacity_")}, Turn: counters.Turn}
					p.Counters = counters
					p.Accounts = as
					p.ObservedMS = now
					for _, account := range as {
						if account.Label == source.Account {
							p.SourceQuota = account
						}
						if account.Label == target {
							p.TargetQuota = account
						}
					}
					p.TriggerResets = capacity.TriggerResets(p.SourceQuota, disk.Settings, now)
					p.Origin = "native_user"
					if r.Operation == "capacity_observe" {
						p.Origin = "automation"
						p.Reasons = []string{}
						if decision.ContextDue {
							p.Reasons = append(p.Reasons, "context")
						}
						if decision.QuotaDue {
							p.Reasons = append(p.Reasons, "quota")
						}
						if decision.ReturnDue {
							p.Reasons = append(p.Reasons, "return")
						}
						if decision.RebalanceDue {
							p.Reasons = append(p.Reasons, "rebalance")
						}
					}
					operation, opErr := (capacity.Coordinator{Journal: j, Adapter: capacity.NativeUnavailable{}}).Request(ctx, p)
					if opErr != nil {
						reply.State = "held"
						reply.Reason = opErr.Error()
					} else {
						reply.Operation = &operation
						reply.State = operation.State
						reply.Reason = operation.Reason
						updated, _ := j.Load()
						reply.Revision = updated.Revision
					}
				}
			}
		}
	}
	return json.Marshal(map[string]any{"request_id": id, "result": reply})
}

// Samples come from the existing host-native binding + canonical turn ledger.
// The old model is never asked for a new answer to produce a policy sample.
func capacityNativeObserve(ctx context.Context, pane string) (capacity.Source, capacity.Counters, error) {
	var source capacity.Source
	var c capacity.Counters
	candidate, err := readHostRotationNativeObservationCandidate(ctx, pane)
	if err != nil {
		return source, c, err
	}
	b := candidate.Binding
	manifest, err := loadManifest(NewServer().manifestPath(pane))
	if err != nil || validateWorkerIdentity(manifest) != nil {
		return source, c, errors.New("native worker identity unavailable")
	}
	config, err := agentConfigRoot(b.Producer.ProcessID, b.Producer.Provider)
	if err != nil {
		return source, c, errors.New("verified frontend config directory unavailable")
	}
	config, err = filepath.EvalSymlinks(config)
	if err != nil {
		return source, c, err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return source, c, err
	}
	registry, err := agentaccounts.Load(home)
	if err != nil {
		return source, c, err
	}
	label := ""
	for _, a := range registry.Accounts {
		if a.Provider != b.Producer.Provider {
			continue
		}
		root, e := filepath.EvalSymlinks(a.Root(home))
		if e == nil && root == config {
			if label != "" {
				return source, c, errors.New("native account mapping ambiguous")
			}
			label = a.Label
		}
	}
	if label == "" {
		return source, c, errors.New("native account is not registered")
	}
	host, _ := os.Hostname()
	source = capacity.Source{Host: host, Boot: manifest.NodeBootID, Pane: pane, WorkerPID: manifest.WorkerPID, WorkerStart: manifest.WorkerStartTime, Provider: b.Producer.Provider, Session: b.SessionID, PID: b.Producer.ProcessID, Start: b.Producer.ProcessStart, Account: label, Config: config, Binding: b.Revision, Root: candidate.CWD}

	enrollment := hostRotationEnrollment{SessionID: source.Session, Client: source.Provider, CWD: source.Root, PaneID: pane, AgentPID: source.PID, AgentStart: source.Start, WorkerPID: source.WorkerPID, WorkerStart: source.WorkerStart, NodeBootID: source.Boot}
	raw, err := readHostRotationLedgerStatus(ctx, enrollment)
	if err == nil {
		c = capacityCountersFromLedger(raw)
		source.Model = capacityModelFromLedger(raw)
	}
	if !source.Valid() {
		return source, c, errors.New("native capacity source/model evidence incomplete")
	}

	// Missing counters hold context decisions while retaining exact capability
	// diagnostics and quota observations. They are never replaced by estimates.
	after, err := ReadNativeAgentBinding(pane)
	if err != nil || !sameHostRotationNativeBinding(b, after) {
		return source, c, errors.New("native capacity source changed")
	}
	return source, c, nil
}
func capacityCountersFromLedger(raw []byte) (c capacity.Counters) {
	defer func() {
		if recover() != nil {
			c = capacity.Counters{}
		}
	}()
	doc, err := pyDecode(raw)
	if err != nil {
		return c
	}
	s := hostRotationPolicyUnwrap(doc)
	u, ok := s.Get("usage").(*pyObject)
	if !ok {
		return c
	}
	c.Session, _ = s.Get("session_id").(string)
	turn, _ := pyInt(s.Get("turn_seq"))
	if turn > 0 {
		c.Turn = uint64(turn)
	}
	tokens, okT := pyInt(u.Get("context_tokens"))
	window, okW := pyInt(u.Get("context_window"))
	if okT && okW {
		c.Tokens = tokens
		c.Window = window
	}
	observed, okO := pyInt(hostRotationPolicyObserved(u, "transcript_mtime_ms_at_stop"))
	if okO {
		c.ObservedMS = observed
	}
	flight, okF := hostRotationPolicyObserved(u, "in_flight_tool").(bool)
	fresh, okR := hostRotationPolicyObserved(u, "turn_id_fresh").(bool)
	request, okQ := pyInt(hostRotationPolicyObserved(u, "last_model_request_ms"))
	response, okS := pyInt(hostRotationPolicyObserved(u, "last_model_response_ms"))
	c.CompletedIdle = c.Session != "" && c.Turn > 0 && c.ObservedMS > 0 && okF && !flight && okR && fresh && okQ && okS && response >= request
	return c
}

var capacityUsageCache = struct {
	sync.Mutex
	at     time.Time
	key    string
	values []agentaccounts.Usage
	raw    map[string][]byte
}{}

// Usage responses do not establish target-model entitlement. Only the model
// already running in this exact native account/config has direct admission
// evidence here. A future target adapter must supply its actual model contract;
// a plan label, user weight or successful usage endpoint cannot substitute.
func capacityUsageModelScope(source capacity.Source, provider, label, config string, usageOK bool) (bool, string) {
	if !usageOK {
		return false, "fresh_usage_observation_unavailable"
	}
	if source.Valid() && source.Provider == provider && source.Account == label && source.Config == config {
		return true, "current_model_bound_to_exact_native_session_account"
	}
	return false, "target_model_admission_not_reported_by_usage_adapter"
}

func capacityNativeAccounts(ctx context.Context, s capacity.Settings, source capacity.Source, now int64) ([]capacity.Account, []string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, nil, err
	}
	registry, err := agentaccounts.Load(home)
	if err != nil {
		return nil, nil, err
	}
	wanted := map[string]bool{source.Account: true}
	for _, v := range capacity.ApprovedLabels(s, source.Provider) {
		wanted[v] = true
	}
	selected := []agentaccounts.Account{}
	registered := []string{}
	for _, a := range registry.Accounts {
		if a.Provider != source.Provider {
			continue
		}
		registered = append(registered, a.Label)
		if wanted[a.Label] {
			selected = append(selected, a)
		}
	}
	raw, _ := json.Marshal(selected)
	key := home + string(raw)
	capacityUsageCache.Lock()
	defer capacityUsageCache.Unlock()
	if capacityUsageCache.key != key || time.Since(capacityUsageCache.at) >= 60*time.Second {
		// Provider usage endpoints only, not a model request. Registry/source checks
		// and source-specific TTL keys prevent cross-account cache substitution.
		rawByAccount := map[string][]byte{}
		var rawMu sync.Mutex
		capacityUsageCache.values = agentaccounts.ReadUsage(home, selected, func(call context.Context, p, dir string) ([]byte, error) {
			child, cancel := context.WithTimeout(ctx, 6*time.Second)
			defer cancel()
			raw, err := agentaccounts.ProviderUsage(child, p, dir)
			rawMu.Lock()
			rawByAccount[p+":"+dir] = append([]byte{}, raw...)
			rawMu.Unlock()
			return raw, err
		}, time.UnixMilli(now))
		capacityUsageCache.raw = rawByAccount
		capacityUsageCache.key = key
		capacityUsageCache.at = time.Now()
	}
	out := []capacity.Account{}
	for _, u := range capacityUsageCache.values {
		a, ok := registry.Find(u.Provider, u.Label)
		if !ok {
			continue
		}
		root, e := filepath.EvalSymlinks(a.Root(home))
		if e != nil {
			continue
		}
		at, _ := time.Parse(time.RFC3339Nano, u.ReadAt)
		value := capacity.Account{Label: u.Label, Config: root, Provider: u.Provider, Compatible: false, ScopeKnown: u.Provider == "claude", Model: source.Model, Plan: u.Plan, CompatibilityReason: "same provider/user model scope; target model admission remains unverified", ObservedMS: at.UnixMilli(), Windows: []capacity.Window{}}
		value.Compatible, value.CompatibilityReason = capacityUsageModelScope(source, u.Provider, u.Label, root, u.Status == agentaccounts.UsageOK)
		for _, w := range u.Windows {
			reset, e := time.Parse(time.RFC3339Nano, w.ResetsAt)
			if e != nil {
				continue
			}
			value.Windows = append(value.Windows, capacity.Window{Name: w.Name, Used: w.UsedPercent, ResetMS: reset.UnixMilli(), DurationMinutes: int64(w.WindowMinutes)})
		}
		if u.Provider == "codex" {
			observed, plan, err := capacity.ParseCodexObservation(capacityUsageCache.raw[u.Provider+":"+a.Override(home)])
			if err == nil {
				value.Windows = observed
				value.ScopeKnown = true
				value.Plan = plan
			} else {
				value.ScopeKnown = false
				value.CompatibilityReason = err.Error()
			}
		}
		if a.ExpectPlan != "" && u.Plan != a.ExpectPlan {
			value.Compatible = false
			value.CompatibilityReason = "registered expected plan differs or is unavailable"
		}
		if a.ExpectKey != "" && u.WorkspaceKey != a.ExpectKey {
			value.Compatible = false
			value.CompatibilityReason = "registered expected workspace identity differs or is unavailable"
		}
		out = append(out, value)
	}
	return out, registered, nil
}

// The existing supervisor calls this same Go policy entry. Opted-in capacity
// sessions use the measured threshold; legacy Python parity remains unchanged
// for other sessions. Policy due is descriptive and cannot enable retirement.
func capacityHostPolicy(status *pyObject, now int64) (*pyObject, bool) {
	root := filepath.Join(defaultWorkerStateDir(), "capacity")
	if _, err := os.Lstat(root); errors.Is(err, os.ErrNotExist) {
		return nil, false
	}
	disk, err := (capacity.Journal{Root: root}).Load()
	if err != nil {
		return pyObj("v", int64(1), "decision", "hold", "reasons", pyListOf("capacity_journal_requires_review"), "signal", nil), true
	}
	session, _ := status.Get("session_id").(string)
	for _, entry := range disk.Entries {
		if !entry.Managed || entry.Source.Session != session {
			continue
		}
		raw := pyEncode(status, pyDumpsDefault)
		sample := capacityCountersFromLedger(raw)
		due, reason := capacity.Context(entry, disk.Settings, sample, now)
		return pyObj("v", int64(1), "decision", "hold", "reasons", pyListOf(reason, capacity.RetirementHold), "signal", nil, "context_due", due, "threshold_tokens", disk.Settings.Threshold, "retirement", capacity.RetirementHold), true
	}
	return nil, false
}

// The existing Session invokes hostRotation.humanInput before writing human
// bytes. Capacity enrollment has an independent durable takeover tombstone,
// including when legacy context monitoring was never enrolled.
func capacityRevokeHumanInput(root, pane string) error {
	directory := filepath.Join(root, "capacity")
	if _, err := os.Lstat(directory); errors.Is(err, os.ErrNotExist) {
		return nil
	}
	j := capacity.Journal{Root: directory}
	id := "human-" + capacity.Hash([]byte(pane + time.Now().UTC().Format(time.RFC3339Nano)))[:32]
	_, err := j.NativeEvent(id, capacity.Hash([]byte(id)), func(d *capacity.Disk) error {
		current, ok := d.Entries[pane]
		if !ok || !current.Managed || current.Takeover {
			return capacity.ErrNoChange
		}
		next, err := current.ApplyUserState("human_input")
		if err != nil {
			return err
		}
		d.Entries[pane] = next
		return nil
	})
	return err
}

func capacityModelFromLedger(raw []byte) (model string) {
	defer func() {
		if recover() != nil {
			model = ""
		}
	}()
	doc, err := pyDecode(raw)
	if err != nil {
		return ""
	}
	status := hostRotationPolicyUnwrap(doc)
	usage, ok := status.Get("usage").(*pyObject)
	if !ok {
		return ""
	}
	value, ok := usage.Get("model").(string)
	if !ok || len(value) > 256 || strings.ContainsAny(value, "\x00\r\n") {
		return ""
	}
	return value
}
