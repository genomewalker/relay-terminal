package capacity

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
)

const clock int64 = 1000000

func source() Source {
	return Source{Model: "observed-model", Host: "host", Boot: "boot", Pane: "pane", WorkerPID: 12, WorkerStart: 20, Provider: "claude", Session: "session", PID: 30, Start: 40, Account: "team", Config: "/team", Binding: strings.Repeat("a", 64), Root: "/project"}
}
func entry() Entry {
	return Entry{Managed: true, Source: source(), Enabled: true, Baseline: 56000, BaselineTurn: 1}
}
func sample() Counters {
	return Counters{Session: "session", Turn: 3, Tokens: 100000, Window: 200000, ObservedMS: clock, CompletedIdle: true}
}
func quota(label, dir string, five, week float64) Account {
	return Account{Label: label, Config: dir, Provider: "claude", Compatible: true, ScopeKnown: true, Model: "observed-model", ObservedMS: clock, Windows: []Window{{Name: "five_hour", Used: five, ResetMS: clock + 10000}, {Name: "seven_day", Used: week, ResetMS: clock + 20000}}}
}
func policy() Settings {
	s := Defaults()
	s.Approved = []string{"claude:team", "claude:personal", "claude:third"}
	for _, label := range []string{"team", "personal", "third"} {
		s.Weights = append(s.Weights, Weight{Provider: "claude", Account: label, Model: "observed-model", Value: 1, AsOfMS: clock - 1000, ExpiresMS: clock + 86400000, Provenance: "user_assumption", Note: "disposable fixture assumption"})
	}
	return s
}
func TestCapacityContextThreshold(t *testing.T) {
	e, s, c := entry(), policy(), sample()
	for _, tokens := range []int64{99999, 100000, 100001} {
		c.Tokens = tokens
		got, _ := Context(e, s, c, clock)
		if got != (tokens >= 100000) {
			t.Fatalf("THRESHOLD_BOUNDARY tokens=%d due=%v", tokens, got)
		}
	}
	c = sample()
	c.ObservedMS = clock - MaxAgeMS - 1
	if due, _ := Context(e, s, c, clock); due {
		t.Fatal("STALE_COUNTER_AUTHORIZED")
	}
	c = sample()
	c.Session = "other"
	if due, _ := Context(e, s, c, clock); due {
		t.Fatal("WRONG_SESSION_COUNTER")
	}
	c = sample()
	c.Turn = e.BaselineTurn
	if due, _ := Context(e, s, c, clock); due {
		t.Fatal("PICKUP_TURN_REARMED")
	}
	c = sample()
	s.Threshold = 60000
	if due, why := Context(e, s, c, clock); due || why != "threshold_baseline_headroom_conflict" {
		t.Fatal("BASELINE_LOOP_FENCE", due, why)
	}
	s = policy()
	c.Window = 105000
	if due, _ := Context(e, s, c, clock); due {
		t.Fatal("HEADROOM_FENCE")
	}
	c = sample()
	c.CompletedIdle = false
	if due, _ := Context(e, s, c, clock); due {
		t.Fatal("BUSY_CONTEXT_AUTHORIZED")
	}
}
func TestCapacityRankingAndRebalance(t *testing.T) {
	e, s, c := entry(), policy(), sample()
	s.QuotaEnabled = true
	accounts := []Account{quota("team", "/team", 90, 30), quota("personal", "/personal", 20, 90), quota("third", "/third", 40, 40)}
	d := Decide(e, s, c, accounts, clock)
	if !d.QuotaDue || !d.ContextDue || d.Target != "third" || d.Ready || d.Retirement != RetirementHold {
		t.Fatal("DYNAMIC_LIMITING_WINDOW", d)
	}
	accounts[2].Windows[1].Used = 95
	d = Decide(e, s, c, accounts, clock)
	if d.Target != "personal" {
		t.Fatal("TARGET_ALL_WINDOW_CEILING", d)
	}
	accounts[1].ObservedMS = clock - MaxAgeMS - 1
	d = Decide(e, s, c, accounts, clock)
	if d.Target != "" || d.Reasons[0] != "all_approved_accounts_constrained_or_unknown" {
		t.Fatal("STALE_ACCOUNT_RANKED", d)
	}
	accounts = []Account{quota("team", "/team", 60, 60), quota("personal", "/personal", 40, 40), quota("third", "/third", 40, 40)}
	s.RebalanceEnabled = true
	s.QuotaEnabled = false
	c.Tokens = 90000
	d = Decide(e, s, c, accounts, clock)
	if !d.RebalanceDue || d.Target != "personal" {
		t.Fatal("STABLE_APPROVED_ORDER", d)
	}
	e.LastMoveMS = clock - 1000
	d = Decide(e, s, c, accounts, clock)
	if d.RebalanceDue {
		t.Fatal("MINIMUM_DWELL_IGNORED", d)
	}
	e.LastMoveMS = 0
	accounts[1].Windows[0].Used = 57
	accounts[1].Windows[1].Used = 57
	accounts[2] = accounts[1]
	accounts[2].Label = "third"
	accounts[2].Config = "/third"
	if Decide(e, s, c, accounts, clock).RebalanceDue {
		t.Fatal("HYSTERESIS_IGNORED")
	}
	e.Pinned = true
	e.Enabled = false
	if Decide(e, s, c, accounts, clock).State != "held" {
		t.Fatal("EXPLICIT_PIN_IGNORED")
	}
}
func TestCapacityEveryResetAndOwnership(t *testing.T) {
	e, s, c := entry(), policy(), sample()
	s.QuotaEnabled = true
	s.RebalanceEnabled = true
	e.Source.Account = "personal"
	e.Source.Config = "/personal"
	e.Away = &Away{OriginalAccount: "team", OriginalConfig: "/team", Owner: "owned", Resets: map[string]int64{"five_hour": clock - 2000, "seven_day": clock + 1000}}
	accounts := []Account{quota("personal", "/personal", 91, 91), quota("team", "/team", 10, 10)}
	d := Decide(e, s, c, accounts, clock)
	if d.Target == "team" {
		t.Fatal("EARLY_WEEKLY_RETURN", d)
	}
	e.Away.Resets["seven_day"] = clock - 2000
	d = Decide(e, s, c, accounts, clock)
	if d.Target != "team" {
		t.Fatal("POST_RESET_FRESH_RETURN", d)
	}
	accounts[1].Windows[1].Used = 90
	if Decide(e, s, c, accounts, clock).Target == "team" {
		t.Fatal("RETURN_WHILE_SOURCE_HIGH")
	}
	e.Manual = true
	s.RebalanceEnabled = false
	if Decide(e, s, c, accounts, clock).Reasons[0] != "pane_policy_paused" {
		t.Fatal("LEGACY_MANUAL_OWNER_LOST")
	}
	old := *e.Away
	after, err := e.ApplyUserState("pause")
	if err != nil || !reflect.DeepEqual(old, *after.Away) {
		t.Fatal("QUOTA_AWAY_OWNERSHIP_LOST")
	}
}
func TestCapacityNewDefaultAndBoundedOwnership(t *testing.T) {
	s := policy()
	if !s.NewPaneDefault || s.QuotaEnabled || !s.RebalanceEnabled {
		t.Fatal("DEFAULTS_AUTHORITY")
	}
	for _, verified := range []bool{false, true} {
		for _, lifecycle := range []bool{false, true} {
			e := NewEntry(source(), s, verified, lifecycle)
			if e.Enabled != (verified && lifecycle) {
				t.Fatal("DEFAULT_CAPABILITY_FENCE")
			}
		}
	}
	shell := source()
	shell.Provider = "shell"
	if NewEntry(shell, s, true, true).Enabled {
		t.Fatal("SHELL_DEFAULT_ENROLLED")
	}
	alphabet := []string{"pause", "resume", "human_input", "manual_move", "pin", "unpin", "recover"}
	visits, transitions := 0, 0
	var walk func(Entry, int)
	walk = func(e Entry, depth int) {
		visits++
		if !e.Valid() {
			t.Fatal("BOUNDED_INVALID_STATE", e)
		}
		if e.Enabled && (e.OptOut || e.Takeover || e.Pinned) {
			t.Fatal("BOUNDED_AUTHORITY_PROPERTY", e)
		}
		if depth == 0 {
			return
		}
		for _, a := range alphabet {
			next := e
			var err error
			if a == "recover" {
				raw, _ := json.Marshal(e)
				err = Decode(raw, &next)
			} else {
				next, err = e.ApplyUserState(a)
			}
			if err != nil {
				next = e
			}
			if e.Takeover && !next.Takeover {
				t.Fatal("BOUNDED_TAKEOVER_LIFTED")
			}
			transitions++
			walk(next, depth-1)
		}
	}
	walk(entry(), 4)
	if visits != 2801 || transitions != 2800 {
		t.Fatal("BOUNDED_ENUMERATION_CHANGED", visits, transitions)
	}
	t.Logf("capacity ownership real Entry reducer: alphabet=%d depth=4 actors=1 initial=1 visits=%d transitions=%d safety checked after every step", len(alphabet), visits, transitions)
}
func preparation() Preparation {
	e := source()
	p := Preparation{LinkState: "user_reviewed_exact_lineage", Source: e, Capsule: Canonical{Session: e.Session, Revision: 1, SHA256: strings.Repeat("b", 64), LedgerSeq: 3, SourceSHA256: strings.Repeat("c", 64)}, Jobs: []Job{{ID: "job", Host: e.Host, Boot: e.Boot, PID: 100, Start: 200, State: "independent", EvidenceSHA256: strings.Repeat("d", 64), Log: "/job/log", Brief: "/job/brief", Output: "/job/output", NextAction: "observe only"}}, InventoryComplete: true, ScheduledTasksKnown: true, Falsifiers: "confirmed"}
	return sealPreparation(p)
}
func sealPreparation(p Preparation) Preparation {
	hash, _ := PreparationManifestHash(p)
	raw, _ := json.Marshal(map[string]any{"version": 2, "revision": p.Capsule.Revision, "ledger_seq": p.Capsule.LedgerSeq, "session_id": p.Source.Session, "source": "explicit", "constraints": []string{"relay.source.sha256=" + p.Capsule.SourceSHA256, "relay.jobs.sha256=" + hash}})
	p.CanonicalJSON = raw
	p.Capsule.SHA256 = Hash(raw)
	return p
}

func TestCapacityPreparation(t *testing.T) {
	p := preparation()
	hash := strings.Repeat("c", 64)
	if err := ValidatePreparation(p, source(), hash, 3); err != nil {
		t.Fatal(err)
	}
	cases := map[string]func(*Preparation){"SCHEDULES_OMITTED": func(p *Preparation) { p.Jobs = nil; p.ScheduledTasksKnown = false }, "WRONG_JOB_BOOT": func(p *Preparation) { p.Jobs[0].Boot = "" }, "JOB_START_UNKNOWN": func(p *Preparation) { p.Jobs[0].Start = 0 }, "ATTACHED_CHILD": func(p *Preparation) { p.Jobs[0].State = "attached" }, "FALSIFIER_UNAVAILABLE": func(p *Preparation) { p.Falsifiers = "unavailable" }, "CAPSULE_HASH_IGNORED": func(p *Preparation) { p.Capsule.SourceSHA256 = strings.Repeat("e", 64) }, "CANONICAL_COVERAGE_IGNORED": func(p *Preparation) { p.Capsule.LedgerSeq = 2 }, "STALE_LINK_IGNORED": func(p *Preparation) { p.LinkState = "old_session" }}
	for name, change := range cases {
		p := preparation()
		change(&p)
		p = sealPreparation(p)
		if ValidatePreparation(p, source(), hash, 3) == nil {
			t.Fatal(name)
		}
	}
	p = preparation()
	p.Capsule.SHA256 = strings.Repeat("e", 64)
	if ValidatePreparation(p, source(), hash, 3) == nil {
		t.Fatal("CANONICAL_EXACT_HASH_IGNORED")
	}
	p = preparation()
	p.Jobs[0].State = "finished"
	p = sealPreparation(p)
	if ValidatePreparation(p, source(), hash, 3) != nil {
		t.Fatal("AUTHENTICATED_JOB_COMPLETION_REJECTED")
	}
}
func TestCapacityStrictCodecsAndRecipe(t *testing.T) {
	valid, _ := json.Marshal(policy())
	for i := 0; i < len(valid); i++ {
		var s Settings
		if Decode(valid[:i], &s) == nil {
			t.Fatalf("TRUNCATED_SETTINGS_ACCEPTED %d", i)
		}
	}
	for _, v := range []string{`{"threshold_tokens":100000,"threshold_tokens":1}`, `{"approved_accounts":[],"extra":true}`, `{"a":{"b":1,"b":2}}`, `[] {}`, `null {}`} {
		var s Settings
		if Decode([]byte(v), &s) == nil {
			t.Fatal("STRICT_UNKNOWN_DUPLICATE", v)
		}
	}
	r, err := ParseRecipe("claude", "/usr/bin/claude", "/team", []string{"--model", "opus", "--permission-mode", "default", "initial prompt"})
	if err != nil || !r.RemovedPrompt || !reflect.DeepEqual(r.Arguments, []string{"--model", "opus", "--permission-mode", "default"}) {
		t.Fatal("RECIPE_PROMPT_ONLY_REMOVAL", r, err)
	}
	for _, args := range [][]string{{"--model"}, {"--model", "opus", "--model", "sonnet"}, {"one", "two"}, {"--unknown"}, {"--model=bad\n"}, {"--resume", "../x"}} {
		if _, e := ParseRecipe("claude", "/usr/bin/claude", "/team", args); e == nil {
			t.Fatal("AMBIGUOUS_RECIPE_ACCEPTED", args)
		}
	}
}
func TestCapacityJournalNoReplayAndFilesystem(t *testing.T) {
	j := Journal{Root: filepath.Join(t.TempDir(), "state")}
	d, err := j.Load()
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	change := func(d *Disk) error { calls++; d.Entries["pane"] = entry(); return nil }
	d, err = j.Update("first", Hash([]byte("first")), d.Revision, change)
	if err != nil {
		t.Fatal(err)
	}
	_, err = j.Update("first", Hash([]byte("first")), 0, change)
	if err != nil || calls != 1 {
		t.Fatal("DURABLE_SETTINGS_REPLAY", calls, err)
	}
	if _, err = j.Update("first", Hash([]byte("different")), d.Revision, change); err == nil {
		t.Fatal("REQUEST_ID_CONFLICT_ACCEPTED")
	}
	f, err := os.OpenFile(filepath.Join(j.Root, "policy.jsonl"), os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = f.WriteString("{")
	_ = f.Close()
	if _, err = j.Load(); err == nil {
		t.Fatal("PARTIAL_JOURNAL_REPLAYED")
	}
	dir := t.TempDir()
	outside := filepath.Join(dir, "outside")
	_ = os.WriteFile(outside, []byte("untouched"), 0600)
	root := filepath.Join(dir, "state")
	_ = os.Mkdir(root, 0700)
	_ = os.Symlink(outside, filepath.Join(root, "policy.jsonl"))
	if _, err := (Journal{Root: root}).Load(); err == nil {
		t.Fatal("JOURNAL_SYMLINK_FOLLOWED")
	}
	data, _ := os.ReadFile(outside)
	if string(data) != "untouched" {
		t.Fatal("JOURNAL_OUTSIDE_MUTATION")
	}
}
func TestCapacityConcurrentCAS(t *testing.T) {
	j := Journal{Root: filepath.Join(t.TempDir(), "state")}
	_, _ = j.Load()
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, e := j.Update(fmt.Sprintf("actor%d", i), Hash([]byte(fmt.Sprint(i))), 0, func(d *Disk) error { d.Settings.Threshold += int64(i + 1); return nil })
			results <- e
		}(i)
	}
	wg.Wait()
	close(results)
	success := 0
	for err := range results {
		if err == nil {
			success++
		}
	}
	if success != 1 {
		t.Fatal("TWO_ACTOR_CAS", success)
	}
}

type fakeLease struct {
	effects  map[string]int
	fail     string
	change   func()
	checks   int
	noLaunch bool
}

func (f *fakeLease) VerifyLegacyLineage(ctx context.Context, p Plan, e Entry) error {
	if f.fail == "lineage" {
		return errors.New("legacy journal provenance unavailable")
	}
	return nil
}
func (f *fakeLease) Revalidate(context.Context, Plan) error {
	f.checks++
	if f.fail == "child" && f.checks >= 2 {
		return errors.New("new child")
	}
	return nil
}
func (f *fakeLease) effect(kind string) (string, error) {
	f.effects[kind]++
	if f.change != nil && kind == "notice" {
		f.change()
	}
	if f.fail == kind {
		return "", errors.New("lost receipt")
	}
	return kind + "-receipt", nil
}
func (f *fakeLease) Notice(context.Context, Plan) (string, error) { return f.effect("notice") }
func (f *fakeLease) RetirePreserving(context.Context, Plan) (string, error) {
	if f.fail == "dialog" {
		f.effects["retire"]++
		return "", ErrConfirmation
	}
	return f.effect("retire")
}
func (f *fakeLease) VerifySourceExited(context.Context, Plan) error {
	if f.fail == "source_exit" {
		return errors.New("not exited")
	}
	return nil
}
func (f *fakeLease) Launch(context.Context, Plan) (string, error) { return f.effect("launch") }
func (f *fakeLease) VerifyTarget(context.Context, Plan) error {
	if f.fail == "target_image" {
		return errors.New("wrong image/account/session")
	}
	return nil
}
func (f *fakeLease) Pickup(context.Context, Plan) (string, error) { return f.effect("pickup") }
func (f *fakeLease) VerifyPickup(context.Context, Plan) error {
	if f.fail == "pickup_ack" {
		return errors.New("socket write only")
	}
	return nil
}
func (f *fakeLease) Completion(ctx context.Context, p Plan) (Completion, error) {
	target := p.Source
	target.PID++
	target.Start++
	target.Binding = strings.Repeat("9", 64)
	target.Session = p.NewSession
	target.Account = p.Target
	target.Config = p.TargetConfig
	jobs := map[string]CompletedJob{}
	for _, j := range p.Preparation.Jobs {
		jobs[j.ID] = CompletedJob{State: "same_incarnation", Host: j.Host, Boot: j.Boot, PID: j.PID, Start: j.Start, EvidenceSHA256: j.EvidenceSHA256}
	}
	result := Completion{Source: target, ImageSHA256: p.InstalledImage, CapsuleSHA256: p.Preparation.Capsule.SHA256, Jobs: jobs, Receipt: "native-completion", LinkSource: p.Source.Session, LinkTarget: p.NewSession, PermissionsRetained: true, Counters: Counters{Session: p.NewSession, Turn: 1, Tokens: 56000, Window: 200000, ObservedMS: clock + 1000, CompletedIdle: true}}
	if p.Mode == "resume_same_conversation" {
		result.Counters.Turn = p.Counters.Turn + 1
	}
	switch f.fail {
	case "completion_account":
		result.Source.Account = "wrong"
	case "completion_image":
		result.ImageSHA256 = strings.Repeat("0", 64)
	case "completion_job":
		v := result.Jobs["job"]
		v.Start++
		result.Jobs["job"] = v
	case "completion_link":
		result.LinkTarget = "stale"
	case "completion_baseline":
		result.Counters.Session = "old"
	}
	return result, nil
}
func (f *fakeLease) NoPriorLaunch(context.Context, Plan) error {
	if !f.noLaunch || f.effects["launch"] != 0 {
		return errors.New("prior launch unknown")
	}
	return nil
}

type fakeAdapter struct{ lease *fakeLease }

func (f fakeAdapter) Capabilities(Source) Capabilities {
	return Capabilities{ProviderVersion: "disposable-contract-v1", Admission: true, CompleteWork: true, ScheduledTasks: true, Preservation: true, Pickup: true}
}
func (f fakeAdapter) Acquire(context.Context, Plan) (Lease, error) { return f.lease, nil }
func fixture(t *testing.T) (Coordinator, Plan, *fakeLease) {
	t.Helper()
	j := Journal{Root: filepath.Join(t.TempDir(), "state")}
	d, err := j.Update("setup", Hash([]byte("setup")), 0, func(d *Disk) error {
		d.Settings = policy()
		d.Settings.RebalanceEnabled = false
		d.Settings.QuotaEnabled = true
		d.Settings.AdoptInstalledUpdates = true
		d.Entries["pane"] = entry()
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	p := Plan{Origin: "automation", ID: "operation", Source: source(), Target: "personal", TargetConfig: "/personal", NewSession: "fresh-session", Mode: "fresh_context", Reasons: []string{"context", "quota"}, PolicyRevision: d.Revision, SettingsSHA256: SettingsHash(d.Settings), Preparation: preparation(), SourceSHA256: strings.Repeat("c", 64), Turn: 3, InstalledImage: strings.Repeat("e", 64), CurrentImage: strings.Repeat("f", 64)}
	p.Counters = sample()
	p.Accounts = []Account{quota("team", "/team", 91, 91), quota("personal", "/personal", 20, 20)}
	p.ObservedMS = clock
	p.SourceQuota = quota("team", "/team", 91, 91)
	p.TargetQuota = quota("personal", "/personal", 20, 20)
	p.TriggerResets = TriggerResets(p.SourceQuota, d.Settings, clock)
	f := &fakeLease{effects: map[string]int{}, noLaunch: true}
	return Coordinator{Now: func() int64 { return clock + 1000 }, Journal: j, Adapter: fakeAdapter{f}}, p, f
}
func TestCapacityCoordinatorActualUnavailable(t *testing.T) {
	for _, provider := range []string{"claude", "codex"} {
		c, p, f := fixture(t)
		p.Source.Provider = provider
		p.Preparation.Source = p.Source
		p.Preparation = sealPreparation(p.Preparation)
		d, _ := c.Journal.Load()
		_, e := c.Journal.Update("provider", Hash([]byte(provider)), d.Revision, func(d *Disk) error { v := d.Entries["pane"]; v.Source = p.Source; d.Entries["pane"] = v; return nil })
		if e != nil {
			t.Fatal(e)
		}
		d, _ = c.Journal.Load()
		p.PolicyRevision = d.Revision
		c.Adapter = NativeUnavailable{}
		o, err := c.Request(context.Background(), p)
		if err != nil || o.State != "held" || o.Reason != RetirementHold || len(f.effects) != 0 {
			t.Fatal("NATIVE_CAPABILITY_MANUFACTURED", o, err)
		}
	}
}
func TestCapacityCoordinatorOneShotAndLoss(t *testing.T) {
	for _, fail := range []string{"", "notice", "retire", "source_exit", "launch", "target_image", "pickup", "pickup_ack", "dialog", "child", "lineage", "completion_account", "completion_image", "completion_job", "completion_link", "completion_baseline"} {
		t.Run(fail, func(t *testing.T) {
			c, p, f := fixture(t)
			f.fail = fail
			o, err := c.Request(context.Background(), p)
			if err != nil || o.State != "prepared" {
				t.Fatal("PREPARATION_REJECTED", o, err)
			}
			o, err = c.Advance(context.Background(), p.ID)
			if err != nil {
				t.Fatal(err)
			}
			if fail == "" && o.State != "completed" {
				t.Fatal("EXACT_COMPLETION_REQUIRED", o)
			}
			if fail != "" && o.State == "completed" {
				t.Fatal("FALSE_SUCCESS", fail, o)
			}
			before := fmt.Sprint(f.effects)
			_, _ = c.Advance(context.Background(), p.ID)
			if fmt.Sprint(f.effects) != before {
				t.Fatal("UNCERTAIN_EFFECT_REPLAY", fail)
			}
			for name, n := range f.effects {
				if n > 1 {
					t.Fatal("DOUBLE_EFFECT", name, n)
				}
			}
			if fail == "dialog" && (o.State != "confirmation_required" || f.effects["launch"] != 0) {
				t.Fatal("SCHEDULED_EXIT_DIALOG_NOT_HELD", o)
			}
			if fail == "child" && f.effects["retire"] != 0 {
				t.Fatal("CHILD_START_PREFLIGHT_IGNORED")
			}
		})
	}
}
func TestCapacityCoordinatorUserAndSettingsRaces(t *testing.T) {
	for _, change := range []string{"pause", "human_input", "manual_move", "settings"} {
		c, p, f := fixture(t)
		f.change = func() {
			d, _ := c.Journal.Load()
			_, err := c.Journal.Update("user", Hash([]byte(change)), d.Revision, func(d *Disk) error {
				if change == "settings" {
					d.Settings.Threshold++
				} else {
					e, _ := d.Entries["pane"].ApplyUserState(change)
					d.Entries["pane"] = e
				}
				return nil
			})
			if err != nil {
				t.Fatal(err)
			}
		}
		_, _ = c.Request(context.Background(), p)
		o, err := c.Advance(context.Background(), p.ID)
		if err != nil || f.effects["retire"] != 0 || o.State != "held" {
			t.Fatal("USER_PREFLIGHT_CHANGE_IGNORED", change, o, err)
		}
	}
}
func TestCapacityRecoveryAndCoalescing(t *testing.T) {
	c, p, f := fixture(t)
	o, err := c.Request(context.Background(), p)
	if err != nil {
		t.Fatal(err)
	}
	p.Reasons = append(p.Reasons, "installed_update")
	o, err = c.Coalesce(context.Background(), p)
	if err != nil || len(o.Plan.Reasons) != 3 {
		t.Fatal("PRECOMMIT_COALESCING", o, err)
	}
	f.fail = "retire"
	o, err = c.Advance(context.Background(), p.ID)
	if err != nil || o.State != "unknown" {
		t.Fatal("UNKNOWN_RETIREMENT_REQUIRED", o, err)
	}
	if _, err = c.Coalesce(context.Background(), p); err == nil {
		t.Fatal("POSTCOMMIT_PLAN_MUTATION")
	}
	f.fail = ""
	o, err = c.ReconcileSourceExit(context.Background(), p.ID)
	if err != nil || o.State != "source_exited" {
		t.Fatal("INDEPENDENT_EXIT_RECONCILIATION", o, err)
	}
	o, err = c.Advance(context.Background(), p.ID)
	if err != nil || o.State != "completed" || f.effects["retire"] != 1 || f.effects["launch"] != 1 {
		t.Fatal("ORIGINAL_UNISSUED_LAUNCH_ONCE", o, err, f.effects)
	}
	if _, err = c.ReconcileSourceExit(context.Background(), p.ID); err == nil {
		t.Fatal("COMPLETED_EXIT_RECONCILED_AGAIN")
	}
}
func FuzzCapacitySettings(f *testing.F) {
	seed, _ := json.Marshal(policy())
	f.Add(seed)
	f.Add([]byte(`{"threshold_tokens":1,"threshold_tokens":2}`))
	f.Fuzz(func(t *testing.T, raw []byte) {
		var v Settings
		if Decode(raw, &v) != nil {
			return
		}
		if !v.Valid() {
			return
		}
		encoded, _ := json.Marshal(v)
		var trailing Settings
		if Decode(append(append([]byte{}, raw...), '{'), &trailing) == nil {
			t.Fatal("SETTINGS_TRAILING_INPUT_ACCEPTED")
		}
		var back Settings
		if Decode(encoded, &back) != nil || !reflect.DeepEqual(v, back) {
			t.Fatal("SETTINGS_ROUNDTRIP")
		}
	})
}
func FuzzCapacityPreparation(f *testing.F) {
	seed, _ := json.Marshal(preparation())
	f.Add(seed)
	f.Add([]byte(`{}`))
	f.Add([]byte(`{"canonical_json":null}`))
	f.Add([]byte(`{"canonical_json":[]}`))
	f.Add([]byte(`{"canonical_json":{ "objective" : "fixture" }}`))
	f.Add([]byte(`{"canonical_json":{"objective":"<capsule>"}}`))
	f.Add([]byte(`{"source":{"pid":1,"pid":2}}`))
	bad := preparation()
	bad.Source.PID++
	bad = sealPreparation(bad)
	input, _ := json.Marshal(bad)
	f.Add(input)
	bad = preparation()
	bad.ScheduledTasksKnown = false
	bad = sealPreparation(bad)
	input, _ = json.Marshal(bad)
	f.Add(input)
	f.Fuzz(func(t *testing.T, raw []byte) {
		p, err := DecodePreparation(raw)
		if err != nil {
			return
		}
		encoded, _ := json.Marshal(p)
		back, err := DecodePreparation(encoded)
		if err != nil || !reflect.DeepEqual(p, back) {
			t.Fatal("PREPARATION_ROUNDTRIP")
		}
		if ValidatePreparation(p, source(), strings.Repeat("c", 64), 3) == nil {
			if p.Source != source() || !p.InventoryComplete || !p.ScheduledTasksKnown || p.Falsifiers != "confirmed" {
				t.Fatal("PREPARATION_SOURCE_BINDING")
			}
		}
	})
}
func FuzzCapacityRecipe(f *testing.F) {
	f.Add([]byte(`["--model","opus","prompt"]`))
	f.Add([]byte(`["--model","opus","--model","sonnet"]`))
	f.Add([]byte(`["resume","native-session","--model","observed-model"]`))
	f.Fuzz(func(t *testing.T, raw []byte) {
		var args []string
		if Decode(raw, &args) != nil {
			return
		}
		for _, provider := range []string{"claude", "codex"} {
			executable := "/usr/bin/" + provider
			r, err := ParseRecipe(provider, executable, "/team", args)
			if err != nil {
				continue
			}
			if r.Provider != provider || r.Config != "/team" || r.Executable != executable || len(r.Arguments) > len(args) {
				t.Fatal("RECIPE_BINDING_OR_BOUND")
			}
			if r.PriorSession != "" && !recipeSession(r.PriorSession) {
				t.Fatal("RECIPE_PRIOR_SESSION_BINDING")
			}
			for _, a := range r.Arguments {
				if strings.ContainsAny(a, "\n\r\x00") {
					t.Fatal("RECIPE_CONTROL_ESCAPE")
				}
			}
		}
	})
}
func TestCapacityProviderSpecificRecipeData(t *testing.T) {
	r, err := ParseRecipe("codex", "/usr/bin/codex", "/codex-team", []string{"resume", "exact-session", "--model", "observed-model", "--profile", "work"})
	if err != nil || r.PriorSession != "exact-session" || !reflect.DeepEqual(r.Arguments, []string{"--model", "observed-model", "--profile", "work"}) {
		t.Fatal("CODEX_EXACT_SELECTOR_NOT_TYPED_DATA", r, err)
	}
	for _, tc := range []struct {
		provider string
		args     []string
	}{{"codex", []string{"--permission-mode", "default"}}, {"claude", []string{"--profile", "work"}}, {"codex", []string{"--resume", "exact-session"}}, {"codex", []string{"resume", "../escape"}}, {"codex", []string{"resume", "--last"}}} {
		if _, err := ParseRecipe(tc.provider, "/usr/bin/"+tc.provider, "/team", tc.args); err == nil {
			t.Fatal("WRONG_PROVIDER_OR_AMBIGUOUS_SELECTOR_ACCEPTED", tc)
		}
	}
}

func TestCapacityInstalledImageModeAndFreshBaseline(t *testing.T) {
	c, p, f := fixture(t)
	p.Reasons = []string{"installed_update"}
	p.Mode = "resume_same_conversation"
	p.NewSession = p.Source.Session
	p.Target = p.Source.Account
	p.TargetConfig = p.Source.Config
	p.Counters.Tokens = 90000
	d, _ := c.Journal.Load()
	_, err := c.Journal.Update("quiet-quotas", Hash([]byte("quiet")), d.Revision, func(d *Disk) error { d.Settings.QuotaEnabled = false; return nil })
	if err != nil {
		t.Fatal(err)
	}
	d, _ = c.Journal.Load()
	p.PolicyRevision = d.Revision
	p.SettingsSHA256 = SettingsHash(d.Settings)
	o, err := c.Request(context.Background(), p)
	if err != nil || o.State != "prepared" {
		t.Fatal("UPDATE_ONLY_SAME_CONVERSATION", o.State, o.Reason, err)
	}
	o, err = c.Advance(context.Background(), p.ID)
	if err != nil || o.State != "completed" || f.effects["launch"] != 1 {
		t.Fatal("UPDATE_ONLY_SINGLE_LAUNCH", o.State, err)
	}

	d, _ = c.Journal.Load()
	if e := d.Entries["pane"]; e.Baseline != 56000 || e.BaselineTurn != 1 || e.Source.Session != p.Source.Session {
		t.Fatal("UPDATE_ONLY_BASELINE_REPLACED", e)
	}
	c, p, f = fixture(t)
	_, _ = c.Request(context.Background(), p)
	o, err = c.Advance(context.Background(), p.ID)
	if err != nil || o.State != "completed" {
		t.Fatal(err, o.State)
	}
	d, _ = c.Journal.Load()
	e := d.Entries["pane"]
	if e.Source.Session != p.NewSession || e.Away == nil || len(e.Away.Resets) != 2 {
		t.Fatal("FINAL_METADATA_QUOTA_LINEAGE_LOST", e)
	}
	same := Counters{Session: p.NewSession, Turn: e.BaselineTurn, Tokens: 100000, Window: 200000, ObservedMS: clock + 1000, CompletedIdle: true}
	if due, _ := Context(e, d.Settings, same, clock+1000); due {
		t.Fatal("IMMEDIATE_POST_PICKUP_LOOP")
	}
}

func FuzzCapacityJournalFrame(f *testing.F) {
	state := Empty()
	state.Revision = 1
	raw, _ := json.Marshal(state)
	seed, _ := json.Marshal(frame{Version, "", Hash(raw), state})
	f.Add(seed)
	f.Add([]byte(`{"v":1,"v":1}`))
	corrupt, _ := json.Marshal(frame{Version, "", strings.Repeat("0", 64), state})
	f.Add(corrupt)
	f.Fuzz(func(t *testing.T, raw []byte) {
		state, next, err := decodeFrame(raw, "", 1)
		if err != nil {
			return
		}
		if !state.Valid() || state.Revision != 1 || next != Hash(raw) {
			t.Fatal("JOURNAL_FRAME_HASH_CHAIN_PROPERTY")
		}
		encoded, _ := json.Marshal(state)
		var parsed frame
		if Decode(raw, &parsed) != nil || parsed.SHA256 != Hash(encoded) {
			t.Fatal("JOURNAL_FRAME_INTEGRITY")
		}
	})
}
func TestCapacityNativeTakeoverWinsConcurrentSettings(t *testing.T) {
	j := Journal{Root: filepath.Join(t.TempDir(), "state")}
	d, err := j.Update("setup", Hash([]byte("setup")), 0, func(d *Disk) error { d.Entries["pane"] = entry(); return nil })
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	wg.Add(2)
	var nativeErr error
	go func() {
		defer wg.Done()
		_, _ = j.Update("settings", Hash([]byte("settings")), d.Revision, func(d *Disk) error { d.Settings.Threshold++; return nil })
	}()
	go func() {
		defer wg.Done()
		_, nativeErr = j.NativeEvent("native", Hash([]byte("native")), func(d *Disk) error {
			e, _ := d.Entries["pane"].ApplyUserState("human_input")
			d.Entries["pane"] = e
			return nil
		})
	}()
	wg.Wait()
	d, err = j.Load()
	if nativeErr != nil || err != nil || !d.Entries["pane"].Takeover || d.Entries["pane"].Enabled {
		t.Fatal("NATIVE_INPUT_LOST_TO_SETTINGS_CAS", nativeErr, err)
	}
}
