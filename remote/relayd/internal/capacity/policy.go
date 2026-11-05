// Package capacity owns native policy, checked data preparation and the durable
// effect coordinator. Installed providers cannot acquire a retirement lease.
package capacity

import (
	"errors"
	"math"
	"path/filepath"
	"sort"
	"strings"
)

const Version = 1
const RetirementHold = "native_retirement_contract_unavailable"
const DefaultThreshold int64 = 100000
const MaxAgeMS int64 = 120000

// Percentages are provider observations, never absolute remaining tokens.
type Settings struct {
	Weights               []Weight `json:"weights"`
	CodexThreshold        float64  `json:"codex_limit_threshold"`
	AdoptInstalledUpdates bool     `json:"adopt_installed_updates"`
	RebalanceEnabled      bool     `json:"rebalance_enabled"`
	Hysteresis            float64  `json:"hysteresis_percent"`
	MinimumDwellMS        int64    `json:"minimum_dwell_ms"`
	ContextEnabled        bool     `json:"context_enabled"`
	QuotaEnabled          bool     `json:"quota_enabled"`
	NewPaneDefault        bool     `json:"new_pane_default"`
	Threshold             int64    `json:"threshold_tokens"`
	FiveHour              float64  `json:"five_hour_threshold"`
	Weekly                float64  `json:"weekly_threshold"`
	TargetCeiling         float64  `json:"target_ceiling"`
	Approved              []string `json:"approved_accounts"`
}

func Defaults() Settings {
	return Settings{RebalanceEnabled: true, Weights: []Weight{}, CodexThreshold: 90, ContextEnabled: true, NewPaneDefault: true, Threshold: DefaultThreshold, FiveHour: 90, Weekly: 90, TargetCeiling: 95, Approved: []string{}, Hysteresis: 10, MinimumDwellMS: 300000}
}

func identifier(s string) bool {
	return s != "" && len(s) <= 128 && !strings.ContainsAny(s, "/\\\x00\r\n\t")
}

// Same account-label domain as the existing native account registry/UI.
func accountLabel(s string) bool {
	if len(s) == 0 || len(s) > 24 {
		return false
	}
	for i, c := range s {
		if c >= 'a' && c <= 'z' || c >= '0' && c <= '9' {
			continue
		}
		if i > 0 && (c == '_' || c == '-') {
			continue
		}
		return false
	}
	return true
}
func (s Settings) Valid() bool {
	if s.Hysteresis < 1 || s.Hysteresis > 50 || math.IsNaN(s.Hysteresis) || math.IsInf(s.Hysteresis, 0) || s.MinimumDwellMS < 60000 || s.MinimumDwellMS > 86400000 {
		return false
	}
	if s.Threshold < 10000 || s.Threshold > 2000000 || len(s.Approved) > 32 {
		return false
	}
	for _, x := range []float64{s.FiveHour, s.Weekly, s.TargetCeiling, s.CodexThreshold} {
		if math.IsNaN(x) || math.IsInf(x, 0) || x <= 0 || x > 100 {
			return false
		}
	}
	if len(s.Weights) > 64 {
		return false
	}
	weightKeys := map[string]bool{}
	for _, w := range s.Weights {
		key := w.Provider + ":" + w.Account + ":" + w.Model
		if !w.Valid() || weightKeys[key] {
			return false
		}
		weightKeys[key] = true
	}
	seen := map[string]bool{}
	for _, x := range s.Approved {
		if !approvedKey(x) || seen[x] {
			return false
		}
		seen[x] = true
	}
	return true
}

type Source struct {
	Model       string `json:"model"`
	Host        string `json:"host"`
	Boot        string `json:"boot"`
	Pane        string `json:"pane"`
	WorkerPID   int    `json:"worker_pid"`
	WorkerStart uint64 `json:"worker_start"`
	Provider    string `json:"provider"`
	Session     string `json:"session"`
	PID         int    `json:"pid"`
	Start       uint64 `json:"start"`
	Account     string `json:"account"`
	Config      string `json:"config"`
	Binding     string `json:"binding"`
	Root        string `json:"root"`
}

func (s Source) Valid() bool {
	return s.Model != "" && len(s.Model) <= 256 && !strings.ContainsAny(s.Model, "\x00\r\n") && identifier(s.Host) && identifier(s.Boot) && identifier(s.Pane) && identifier(s.Session) &&
		(s.Provider == "claude" || s.Provider == "codex") && s.PID > 1 && s.Start > 0 && s.WorkerPID > 1 && s.WorkerStart > 0 &&
		accountLabel(s.Account) && filepath.IsAbs(s.Config) && filepath.Clean(s.Config) == s.Config &&
		filepath.IsAbs(s.Root) && filepath.Clean(s.Root) == s.Root && len(s.Binding) == 64 && hexDigest(s.Binding)
}

type Counters struct {
	Session       string `json:"session"`
	Turn          uint64 `json:"turn"`
	Tokens        int64  `json:"tokens"`
	Window        int64  `json:"window"`
	ObservedMS    int64  `json:"observed_ms"`
	CompletedIdle bool   `json:"completed_idle"`
}
type Entry struct {
	Managed        bool   `json:"managed"`
	Pinned         bool   `json:"pinned"`
	LastMoveMS     int64  `json:"last_move_ms"`
	UserGeneration uint64 `json:"user_generation"`
	Source         Source `json:"source"`
	Enabled        bool   `json:"enabled"`
	OptOut         bool   `json:"opt_out"`
	Takeover       bool   `json:"human_takeover"`
	Manual         bool   `json:"manual_owner"`
	Baseline       int64  `json:"baseline"`
	BaselineTurn   uint64 `json:"baseline_turn"`
	Away           *Away  `json:"quota_away"`
}
type Away struct {
	OriginalAccount string `json:"original_account"`
	OriginalConfig  string `json:"original_config"`
	Owner           string `json:"owner"`
	// Every triggering window retains its independent source reset fence.
	Resets map[string]int64 `json:"trigger_resets"`
}

// NewEntry is for an authenticated new-pane creation event, not a read or
// reconnect. Unsupported installed providers remain ineligible for enrollment.
// LifecycleSupported must be native evidence; quiescence remains unavailable.
func NewEntry(s Source, settings Settings, verified, lifecycleSupported bool) Entry {
	enabled := settings.Valid() && settings.NewPaneDefault && s.Valid() && verified && lifecycleSupported
	return Entry{Source: s, Managed: enabled, Enabled: enabled}
}
func (e Entry) Valid() bool {
	if (e.Enabled && !e.Managed) || !e.Source.Valid() || e.Baseline < 0 || e.Baseline > 2000000 || e.LastMoveMS < 0 || (e.Enabled && (e.OptOut || e.Takeover || e.Pinned)) {
		return false
	}
	if e.Away != nil {
		if !identifier(e.Away.Owner) || !identifier(e.Away.OriginalAccount) || !filepath.IsAbs(e.Away.OriginalConfig) || len(e.Away.Resets) == 0 || len(e.Away.Resets) > 64 {
			return false
		}
		for n, r := range e.Away.Resets {
			if !windowName(n) || r <= 0 || r > 1<<53 {
				return false
			}
		}
	}
	return true
}

// ApplyUserState never lifts a human takeover or manual ownership implicitly.
func (e Entry) ApplyUserState(action string) (Entry, error) {
	e.UserGeneration++
	switch action {
	case "pause":
		e.Enabled = false
		e.OptOut = true
	case "resume":
		if !e.Managed || e.Takeover || e.Pinned {
			return e, errors.New("user ownership requires native review")
		}
		e.Enabled = true
		e.OptOut = false
	case "human_input":
		e.Enabled = false
		e.Takeover = true
	case "pin":
		e.Enabled = false
		e.Pinned = true
	case "unpin":
		e.Pinned = false // this does not lift pause or takeover
	case "manual_move":
		e.Enabled = false
		e.Manual = true
	default:
		return e, errors.New("unsupported policy action")
	}
	return e, nil
}

type Window struct {
	DurationMinutes int64   `json:"duration_minutes"`
	Name            string  `json:"name"`
	Used            float64 `json:"used_percent"`
	ResetMS         int64   `json:"reset_ms"`
}
type Account struct {
	Reserved            bool     `json:"reserved"`
	ScopeKnown          bool     `json:"scope_known"`
	Model               string   `json:"model"`
	Plan                string   `json:"observed_plan"`
	CompatibilityReason string   `json:"compatibility_reason"`
	Label               string   `json:"label"`
	Config              string   `json:"config"`
	Provider            string   `json:"provider"`
	Compatible          bool     `json:"compatible"`
	ObservedMS          int64    `json:"observed_ms"`
	Windows             []Window `json:"windows"`
}

var weekly = map[string]bool{"seven_day": true, "seven_day_opus": true, "seven_day_sonnet": true, "seven_day_oauth_apps": true, "seven_day_cowork": true, "seven_day_omelette": true}

func windowName(n string) bool { return n == "five_hour" || weekly[n] || codexWindowName(n) }
func fresh(at, now int64) bool { return at > 0 && now >= at && now-at <= MaxAgeMS }
func (a Account) ObservationCurrent(now int64) bool {
	if !accountLabel(a.Label) || !filepath.IsAbs(a.Config) || !fresh(a.ObservedMS, now) || len(a.Windows) == 0 || len(a.Windows) > 64 {
		return false
	}
	if a.Provider != "claude" && a.Provider != "codex" {
		return false
	}
	if a.Provider == "claude" && len(a.Windows) > 7 {
		return false
	}
	five, week := false, false
	seen := map[string]bool{}
	for _, w := range a.Windows {
		valid := windowName(w.Name)
		if a.Provider == "claude" {
			valid = w.Name == "five_hour" || weekly[w.Name]
		} else {
			valid = codexWindowName(w.Name) && ((w.DurationMinutes > 0 && w.DurationMinutes < 1<<20) || strings.HasSuffix(w.Name, ":spend_control"))
		}
		if !valid || seen[w.Name] || math.IsNaN(w.Used) || math.IsInf(w.Used, 0) || w.Used < 0 || w.Used > 100 || w.ResetMS <= now || w.ResetMS > 1<<53 {
			return false
		}
		seen[w.Name] = true
		five = five || w.Name == "five_hour"
		week = week || weekly[w.Name]
	}
	return a.Provider == "codex" || (five && week)
}
func (a Account) Current(now int64) bool {
	return !a.Reserved && a.Compatible && a.ScopeKnown && a.ObservationCurrent(now)
}
func codexWindowName(n string) bool {
	if n == "primary" || n == "secondary" {
		return true
	}
	parts := strings.Split(n, ":")
	return len(parts) == 3 && parts[0] == "codex" && identifier(parts[1]) && (parts[2] == "primary" || parts[2] == "secondary" || parts[2] == "spend_control")
}

func triggers(a Account, s Settings) map[string]int64 {
	out := map[string]int64{}
	for _, w := range a.Windows {
		limit := s.Weekly
		if a.Provider == "codex" {
			limit = s.CodexThreshold
		}
		if w.Name == "five_hour" {
			limit = s.FiveHour
		}
		if w.Used >= limit {
			out[w.Name] = w.ResetMS
		}
	}
	return out
}
func approvedKey(key string) bool {
	parts := strings.Split(key, ":")
	return len(parts) == 2 && (parts[0] == "claude" || parts[0] == "codex") && accountLabel(parts[1])
}
func approved(s Settings, provider, label string) bool {
	for _, key := range s.Approved {
		if key == provider+":"+label {
			return true
		}
	}
	return false
}
func IsApproved(s Settings, provider, label string) bool { return approved(s, provider, label) }
func ApprovedLabels(s Settings, provider string) []string {
	out := []string{}
	for _, key := range s.Approved {
		parts := strings.Split(key, ":")
		if len(parts) == 2 && parts[0] == provider {
			out = append(out, parts[1])
		}
	}
	return out
}

func canReturn(e Entry, a Account, s Settings, now int64) bool {
	if e.Away == nil || a.Label != e.Away.OriginalAccount || a.Config != e.Away.OriginalConfig || !a.Current(now) || len(triggers(a, s)) != 0 {
		return false
	}
	for n, reset := range e.Away.Resets {
		found := false
		for _, w := range a.Windows {
			if w.Name == n && now >= reset+1000 && a.ObservedMS >= reset+1000 {
				found = true
			}
		}
		if !found {
			return false
		}
	}
	return true
}
func margin(a Account, s Settings) float64 {
	v := 100.0
	for _, w := range a.Windows {
		v = math.Min(v, s.TargetCeiling-w.Used)
	}
	return v
}

type Decision struct {
	Ranking        string   `json:"ranking"`
	Scores         []Score  `json:"scores"`
	RebalanceDue   bool     `json:"rebalance_due"`
	ReturnDue      bool     `json:"return_due"`
	V              int      `json:"v"`
	State          string   `json:"state"`
	ContextDue     bool     `json:"context_due"`
	QuotaDue       bool     `json:"quota_due"`
	Target         string   `json:"target_account"`
	TargetConfig   string   `json:"target_config"`
	Mode           string   `json:"mode"`
	Reasons        []string `json:"reasons"`
	Limiting       []string `json:"limiting_windows"`
	NextMS         int64    `json:"next_observation_ms"`
	MeasuredTokens *int64   `json:"measured_tokens"`
	Retirement     string   `json:"retirement"`
	Ready          bool     `json:"ready"`
}

func held(reason string, now int64) Decision {
	return Decision{V: Version, State: "held", Mode: "fresh_context", Reasons: []string{reason}, Limiting: []string{}, Retirement: RetirementHold, NextMS: now + 60000}
}

// Context applies the configured threshold only to a fresh, completed native
// sample for this exact session. At least 10% of the measured window is reserved.
func Context(e Entry, s Settings, c Counters, now int64) (bool, string) {
	if !s.Valid() || !s.ContextEnabled {
		return false, "context_disabled"
	}
	if !e.Valid() || !e.Enabled || e.OptOut || e.Takeover || e.Pinned || (e.Manual && !s.RebalanceEnabled) {
		return false, "pane_policy_paused"
	}
	if c.Session != e.Source.Session || !fresh(c.ObservedMS, now) || !c.CompletedIdle || c.Turn == 0 || c.Turn <= e.BaselineTurn {
		return false, "fresh_completed_session_sample_required"
	}
	if c.Window <= 0 || c.Window > 2000000 || c.Tokens < 0 || c.Tokens > c.Window {
		return false, "measured_window_required"
	}
	// Baseline and useful growth are independent of the configured threshold.
	if e.Baseline <= 0 || s.Threshold < e.Baseline+10000 || s.Threshold > c.Window-c.Window/10 {
		return false, "threshold_baseline_headroom_conflict"
	}
	if c.Tokens >= c.Window-c.Window/10 {
		return false, "preparation_headroom_unavailable"
	}
	if c.Tokens >= s.Threshold {
		return true, "measured_context_threshold"
	}
	return false, "below_context_threshold"
}

// Decide is deterministic native policy. It never grants an effect capability.
// Quota-only and simultaneous decisions use fresh-context mode. QF2 manual
// resume semantics remain in the legacy lane for unmanaged panes.
func Decide(e Entry, s Settings, c Counters, accounts []Account, now int64) Decision {
	d := held(RetirementHold, now)
	if !s.Valid() || !e.Valid() {
		d.Reasons = []string{"invalid_policy_or_source"}
		return d
	}
	if !e.Enabled || e.OptOut || e.Takeover || e.Pinned || (e.Manual && !s.RebalanceEnabled) {
		d.Reasons = []string{"pane_policy_paused"}
		return d
	}
	if len(accounts) > 32 {
		d.Reasons = []string{"account_observation_bound"}
		return d
	}
	d.Ranking = "legacy_percent_headroom"
	if s.RebalanceEnabled {
		d.Ranking = "relative_capacity_weighted_headroom_estimate"
	}
	d.Scores = []Score{}
	scores := map[string]Score{}
	for _, account := range accounts {
		score := ScoreAccount(account, s, e.Source.Model, now)
		scores[account.Label] = score
		d.Scores = append(d.Scores, score)
	}
	due, contextReason := Context(e, s, c, now)
	d.ContextDue = due
	if fresh(c.ObservedMS, now) && c.Session == e.Source.Session && c.Tokens >= 0 {
		v := c.Tokens
		d.MeasuredTokens = &v
	}
	byLabel := map[string]Account{}
	dirs := map[string]bool{}
	for _, a := range accounts {
		if _, exists := byLabel[a.Label]; exists || dirs[a.Config] {
			d.Reasons = []string{"ambiguous_account_mapping"}
			return d
		}
		byLabel[a.Label] = a
		dirs[a.Config] = true
	}
	current, known := byLabel[e.Source.Account]
	if known && (current.Config != e.Source.Config || current.Provider != e.Source.Provider || current.Model != e.Source.Model) {
		d.Reasons = []string{"source_account_identity_changed"}
		return d
	}
	if s.QuotaEnabled {
		if !known || !current.Current(now) {
			d.Reasons = []string{"fresh_source_windows_required"}
			return d
		}
		ts := triggers(current, s)
		d.QuotaDue = len(ts) > 0
		for n := range ts {
			d.Limiting = append(d.Limiting, n)
		}
		sort.Strings(d.Limiting)
	}
	if s.QuotaEnabled && e.Away != nil && !s.RebalanceEnabled {
		if original, ok := byLabel[e.Away.OriginalAccount]; ok && canReturn(e, original, s, now) {
			d.ReturnDue = true
		}
	}
	if s.RebalanceEnabled && known && current.Current(now) && now >= e.LastMoveMS && now-e.LastMoveMS >= s.MinimumDwellMS {
		for _, a := range accounts {
			if a.Provider == e.Source.Provider && a.Label != current.Label && approved(s, e.Source.Provider, a.Label) && a.Current(now) && weightedImprovement(scores[current.Label], scores[a.Label], s) {
				if e.Away != nil && a.Label == e.Away.OriginalAccount && !canReturn(e, a, s, now) {
					continue
				}
				d.RebalanceDue = true
			}
		}
	}
	if !d.ContextDue && !d.QuotaDue && !d.ReturnDue && !d.RebalanceDue {
		d.State = "observing"
		d.Reasons = []string{contextReason}
		return d
	}
	if !c.CompletedIdle || !fresh(c.ObservedMS, now) || c.Session != e.Source.Session {
		d.Reasons = []string{"fresh_completed_session_sample_required"}
		return d
	}
	d.Target = e.Source.Account
	d.TargetConfig = e.Source.Config
	if d.QuotaDue || d.ReturnDue || d.RebalanceDue {
		type ranked struct {
			a      Account
			margin float64
			reset  int64
			order  int
		}
		choices := []ranked{}
		weighted := s.RebalanceEnabled
		if weighted {
			knownTarget := false
			for _, account := range accounts {
				score := scores[account.Label]
				knownTarget = knownTarget || (account.Provider == e.Source.Provider && account.Label != e.Source.Account && approved(s, e.Source.Provider, account.Label) && score.Known && score.Eligible)
			}
			if !knownTarget && d.QuotaDue {
				weighted = false
				d.Ranking = "quota_safety_percent_headroom_fallback_weights_unknown"
			}
		}

		for i, label := range ApprovedLabels(s, e.Source.Provider) {
			a, ok := byLabel[label]
			if !ok || a.Label == e.Source.Account || !approved(s, e.Source.Provider, a.Label) || !a.Current(now) || a.Provider != e.Source.Provider || a.Model != e.Source.Model {
				continue
			}
			if d.ReturnDue && !d.QuotaDue && !d.RebalanceDue && (e.Away == nil || a.Label != e.Away.OriginalAccount) {
				continue
			}
			if d.RebalanceDue && !d.QuotaDue && !d.ReturnDue && !weightedImprovement(scores[current.Label], scores[a.Label], s) {
				continue
			}
			// Returning to a source account must honor every old triggering reset,
			// even after a context/session change. Ownership is not keyed by session.
			if e.Away != nil && a.Label == e.Away.OriginalAccount {
				if a.Config != e.Away.OriginalConfig || len(triggers(a, s)) > 0 {
					continue
				}
				returned := true
				for n, reset := range e.Away.Resets {
					found := false
					for _, w := range a.Windows {
						if w.Name == n && now >= reset+1000 && a.ObservedMS >= reset+1000 {
							found = true
						}
					}
					returned = returned && found
				}
				if !returned {
					continue
				}
			}
			margin := 100.0
			reset := int64(math.MaxInt64)
			eligible := true
			for _, w := range a.Windows {
				if w.Used >= s.TargetCeiling {
					eligible = false
				}
				margin = math.Min(margin, s.TargetCeiling-w.Used)
				if w.ResetMS < reset {
					reset = w.ResetMS
				}
			}
			if weighted {
				score := scores[a.Label]
				if !score.Known || !score.Eligible || score.Value == nil {
					continue
				}
				margin = *score.Value
			}
			if eligible {
				choices = append(choices, ranked{a, margin, reset, i})
			}
		}
		sort.SliceStable(choices, func(i, j int) bool {
			if choices[i].margin != choices[j].margin {
				return choices[i].margin > choices[j].margin
			}
			if choices[i].reset != choices[j].reset {
				return choices[i].reset < choices[j].reset
			}
			return choices[i].order < choices[j].order
		})
		if len(choices) == 0 {
			d.Target = ""
			d.TargetConfig = ""
			d.Reasons = []string{"all_approved_accounts_constrained_or_unknown"}
			return d
		}
		d.Target = choices[0].a.Label
		d.TargetConfig = choices[0].a.Config
	}
	d.State = "policy_due_capability_held"
	d.Reasons = []string{RetirementHold, "scheduled_task_inventory_unavailable", "canonical_pickup_unavailable"}
	return d
}

// TriggerResets is only a fresh native observation projection; it is not an
// operation or authorization and never supplies replenishment from a clock.
func TriggerResets(a Account, s Settings, now int64) map[string]int64 {
	if !a.Current(now) {
		return nil
	}
	return triggers(a, s)
}
