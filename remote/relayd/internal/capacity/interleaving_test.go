package capacity

import (
	"context"
	"fmt"
	"testing"
)

// All ordered interleavings preserve each actor's program order. This invokes
// the real journal/coordinator, not a parallel specification of its behavior.
func TestCapacityOrderedTwoActorInterleavings(t *testing.T) {
	families := []string{"user_pause_manual", "human_takeover_pin", "settings_source", "job_finish_child_start", "notice_loss_launch_loss", "app_recovery_provider_confirmation"}
	total, steps := 0, 0
	var schedules [][]int
	var build func([]int, int, int)
	build = func(prefix []int, a, b int) {
		if a == 6 && b == 2 {
			schedules = append(schedules, append([]int{}, prefix...))
			return
		}
		if a < 6 {
			build(append(append([]int{}, prefix...), 0), a+1, b)
		}
		if b < 2 {
			build(append(append([]int{}, prefix...), 1), a, b+1)
		}
	}
	build(nil, 0, 0)
	if len(schedules) != 28 {
		t.Fatal("INTERLEAVING_ENUMERATION_BOUND", len(schedules))
	}
	for _, family := range families {
		for index, schedule := range schedules {
			t.Run(fmt.Sprintf("%s/%02d", family, index), func(t *testing.T) {
				c, p, f := fixture(t)
				userRevoked := false
				a, b := 0, 0
				for _, actor := range schedule {
					before := f.effects["retire"] + f.effects["launch"] + f.effects["pickup"]
					if actor == 0 {
						switch a {
						case 0:
							_, _ = c.Request(context.Background(), p)
						case 1:
							p.Reasons = []string{"context", "quota"}
							_, _ = c.Coalesce(context.Background(), p)
						case 2:
							p.Reasons = []string{"context", "quota", "installed_update"}
							_, _ = c.Coalesce(context.Background(), p)
						case 3:
							_, _ = c.Request(context.Background(), p)
						case 4:
							_, _ = c.Advance(context.Background(), p.ID)
						case 5:
							_, _ = c.Advance(context.Background(), p.ID)
						}
						a++
					} else {
						d, err := c.Journal.Load()
						if err != nil {
							t.Fatal(err)
						}
						switch family {
						case "user_pause_manual", "human_takeover_pin", "settings_source":
							_, err = c.Journal.Update(fmt.Sprintf("actor-%d", b), Hash([]byte(fmt.Sprintf("%s%d", family, b))), d.Revision, func(d *Disk) error {
								e := d.Entries["pane"]
								switch family {
								case "user_pause_manual":
									actions := []string{"pause", "manual_move"}
									e, _ = e.ApplyUserState(actions[b])
								case "human_takeover_pin":
									actions := []string{"human_input", "pin"}
									e, _ = e.ApplyUserState(actions[b])
								case "settings_source":
									if b == 0 {
										d.Settings.Threshold++
									} else {
										e.Source.Start++
										e.UserGeneration++
									}
								}
								d.Entries["pane"] = e
								return nil
							})
							if err != nil {
								t.Fatal(err)
							}
							userRevoked = true
						case "job_finish_child_start":
							// An authenticated job finish is safe data; a child start after the
							// checked manifest invalidates the acquired fixture admission contract.
							if b == 0 {
								p.Preparation.Jobs[0].State = "finished"
								p.Preparation = sealPreparation(p.Preparation)
								_, _ = c.Coalesce(context.Background(), p)
							} else {
								f.fail = "child"
							}
						case "notice_loss_launch_loss":
							if b == 0 {
								f.fail = "notice"
							} else {
								f.fail = "launch"
							}
						case "app_recovery_provider_confirmation":
							if b == 0 {
								_, _ = c.Advance(context.Background(), p.ID)
							} else {
								f.fail = "dialog"
							}
						}
						b++
					}
					after := f.effects["retire"] + f.effects["launch"] + f.effects["pickup"]
					if actor == 0 && userRevoked && after > before {
						t.Fatal("INTERLEAVING_EFFECT_AFTER_USER_REVOCATION", family, index)
					}
					for kind, n := range f.effects {
						if n > 1 {
							t.Fatal("INTERLEAVING_DUPLICATE_EFFECT", kind, n)
						}
					}
					d, err := c.Journal.Load()
					if err != nil || !d.Valid() {
						t.Fatal("INTERLEAVING_DURABLE_INVARIANT", err)
					}
					active := 0
					for _, o := range d.Operations {
						if !o.terminal() {
							active++
						}
						if o.State == "completed" {
							for _, kind := range []string{"notice", "retire", "launch", "pickup"} {
								if o.Effects[kind] != "confirmed" {
									t.Fatal("INTERLEAVING_FALSE_SUCCESS", kind)
								}
							}
						}
					}
					if active > 1 {
						t.Fatal("INTERLEAVING_SINGLE_LANE")
					}
					steps++
				}
				total++
			})
		}
	}
	if total != 168 || steps != 1344 {
		t.Fatal("INTERLEAVING_BOUND_CHANGED", total, steps)
	}
	t.Logf("capacity real journal/coordinator ordered interleavings: families=%d scheduler_events=6 actor_events=2 permutations=28 sequences=%d steps=%d panes=1 jobs=1; safety after every step", len(families), total, steps)
}
func TestCapacityIndependentPolicyAuthorityAndLane(t *testing.T) {
	c, p, f := fixture(t)
	d, _ := c.Journal.Load()
	_, err := c.Journal.Update("disable-quota", Hash([]byte("disabled")), d.Revision, func(d *Disk) error { d.Settings.QuotaEnabled = false; return nil })
	if err != nil {
		t.Fatal(err)
	}
	d, _ = c.Journal.Load()
	p.SettingsSHA256 = SettingsHash(d.Settings)
	p.PolicyRevision = d.Revision
	o, err := c.Request(context.Background(), p)
	if err != nil || o.State != "held" || o.Reason != "native_policy_or_user_origin_not_authorized" || len(f.effects) != 0 {
		t.Fatal("CONTEXT_CANNOT_ENABLE_QUOTA", o, err)
	}
	c, p, f = fixture(t)
	_, _ = c.Request(context.Background(), p)
	f.fail = "launch"
	o, err = c.Advance(context.Background(), p.ID)
	if err != nil || o.State != "unknown" {
		t.Fatal(err, o)
	}
	other := p
	other.ID = "second-operation"
	d, _ = c.Journal.Load()
	other.PolicyRevision = d.Revision
	if _, err = c.Request(context.Background(), other); err == nil {
		t.Fatal("UNCERTAIN_SHARED_LANE_RELEASED")
	}
}

func TestCapacityCurrentClockRejectsQueuedStaleEvidence(t *testing.T) {
	for _, phase := range []string{"request", "before-effects", "during-notice", "completion"} {
		t.Run(phase, func(t *testing.T) {
			c, p, f := fixture(t)
			now := clock + 1000
			c.Now = func() int64 { return now }
			if phase == "request" {
				now = clock + MaxAgeMS + 1
			}
			o, err := c.Request(context.Background(), p)
			if err != nil {
				t.Fatal(err)
			}
			if phase == "request" {
				if o.State != "held" || o.Reason != "native_observation_expired" {
					t.Fatal("STALE_REQUEST_ADMITTED", o)
				}
				return
			}
			if phase == "before-effects" {
				now = clock + MaxAgeMS + 1
			}
			if phase == "during-notice" {
				f.change = func() { now = clock + MaxAgeMS + 1 }
			}
			if phase == "completion" {
				now = clock /* fixture completion timestamp is future, not an observation */
			}
			o, err = c.Advance(context.Background(), p.ID)
			if err != nil {
				t.Fatal(err)
			}
			if phase == "completion" {
				if o.State != "unknown" || o.Reason != "completion_observation_expired" {
					t.Fatal("FUTURE_COMPLETION_ACCEPTED", o)
				}
			} else if f.effects["retire"] != 0 || f.effects["launch"] != 0 || o.State != "held" {
				t.Fatal("STALE_QUEUED_EFFECT", o, f.effects)
			}
		})
	}
}

func TestCapacityAccountReservationRequiresIndependentFreshObservation(t *testing.T) {
	c, p, f := fixture(t)
	d, _ := c.Journal.Load()
	_, err := c.Journal.Update("second-pane", Hash([]byte("second-pane")), d.Revision, func(d *Disk) error {
		e := entry()
		e.Source.Pane = "pane-two"
		d.Entries[e.Source.Pane] = e
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	d, _ = c.Journal.Load()
	p.PolicyRevision = d.Revision
	if o, err := c.Request(context.Background(), p); err != nil || o.State != "prepared" {
		t.Fatal(err, o)
	}
	other := p
	other.ID = "other-operation"
	other.Source.Pane = "pane-two"
	other.Preparation.Source = other.Source
	other.Preparation = sealPreparation(other.Preparation)
	d, _ = c.Journal.Load()
	other.PolicyRevision = d.Revision
	if _, err = c.Request(context.Background(), other); err == nil {
		t.Fatal("COMPETING_PANE_ADMITTED_DURING_PENDING_INTENT")
	}
	if o, err := c.Advance(context.Background(), p.ID); err != nil || o.State != "completed" {
		t.Fatal(err, o)
	}
	d, _ = c.Journal.Load()
	other.PolicyRevision = d.Revision
	o, err := c.Request(context.Background(), other)
	if err != nil || o.State != "held" || o.Reason != "shared_account_observation_reserved" {
		t.Fatal("STALE_SHARED_ACCOUNT_REUSED", err, o)
	}
	other.ID = "fresh-other-operation"
	other.TargetQuota.ObservedMS = clock + 2000
	for i := range other.Accounts {
		other.Accounts[i].ObservedMS = clock + 2000
	}
	other.Counters.ObservedMS = clock + 2000
	other.ObservedMS = clock + 2000
	c.Now = func() int64 { return clock + 2000 }
	d, _ = c.Journal.Load()
	other.PolicyRevision = d.Revision
	o, err = c.Request(context.Background(), other)
	if err != nil || o.State != "prepared" {
		t.Fatal("FRESH_INDEPENDENT_ACCOUNT_NOT_RECONSIDERED", err, o)
	}
	if f.effects["launch"] != 1 {
		t.Fatal("RESERVATION_DUPLICATE_LAUNCH", f.effects)
	}
}

func TestCapacityTwoPaneReservationInterleavings(t *testing.T) {
	schedules := [][]int{{0, 0, 1, 1}, {0, 1, 0, 1}, {0, 1, 1, 0}, {1, 0, 0, 1}, {1, 0, 1, 0}, {1, 1, 0, 0}}
	steps := 0
	for _, schedule := range schedules {
		c, p, f := fixture(t)
		d, _ := c.Journal.Load()
		_, err := c.Journal.Update("two-panes", Hash([]byte("two-panes")), d.Revision, func(d *Disk) error {
			e := entry()
			e.Source.Pane = "pane-two"
			d.Entries[e.Source.Pane] = e
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
		plans := []Plan{p, p}
		plans[1].ID = "second-operation"
		plans[1].Source.Pane = "pane-two"
		plans[1].Preparation.Source = plans[1].Source
		plans[1].Preparation = sealPreparation(plans[1].Preparation)
		actorStep := [2]int{}
		for _, actor := range schedule {
			if actorStep[actor] == 0 {
				d, _ = c.Journal.Load()
				plans[actor].PolicyRevision = d.Revision
				previouslyCompleted := 0
				for _, old := range d.Operations {
					if old.State == "completed" {
						previouslyCompleted++
					}
				}
				admitted, requestErr := c.Request(context.Background(), plans[actor])
				if previouslyCompleted > 0 && (requestErr != nil || admitted.State != "held" || admitted.Reason != "shared_account_observation_reserved") {
					t.Fatal("TWO_PANE_POST_COMPLETION_RESERVATION", schedule, admitted, requestErr)
				}
			} else {
				_, _ = c.Advance(context.Background(), plans[actor].ID)
			}
			actorStep[actor]++
			steps++
			d, err = c.Journal.Load()
			if err != nil || !d.Valid() {
				t.Fatal("TWO_PANE_DURABLE_INVARIANT", err)
			}
			active, completed := 0, 0
			for _, o := range d.Operations {
				if !o.terminal() {
					active++
				}
				if o.State == "completed" {
					completed++
				}
			}
			if active > 1 || completed > 1 || f.effects["launch"] > 1 {
				t.Fatal("TWO_PANE_RESERVATION_HERD", schedule, active, completed, f.effects)
			}
		}
		if f.effects["launch"] != 1 {
			t.Fatal("TWO_PANE_SINGLE_WINNER", schedule, f.effects)
		}
	}
	if steps != 24 {
		t.Fatal("TWO_PANE_INTERLEAVING_BOUND", steps)
	}
	t.Log("real journal/coordinator: panes=2 shared_target=1 actor_events=2 ordered_interleavings=6 steps=24; stale shared observation cannot admit a second move")
}

func TestCapacityCompletionIdentityAndJobMatrix(t *testing.T) {
	_, p, f := fixture(t)
	good, err := f.Completion(context.Background(), p)
	if err != nil || validateCompletion(p, good) != nil {
		t.Fatal("VALID_COMPLETION_REJECTED")
	}
	checks := map[string]func(*Completion){
		"host": func(c *Completion) { c.Source.Host = "other" }, "boot": func(c *Completion) { c.Source.Boot = "other" }, "pane": func(c *Completion) { c.Source.Pane = "other" },
		"worker": func(c *Completion) { c.Source.WorkerStart++ }, "provider": func(c *Completion) { c.Source.Provider = "codex" }, "model": func(c *Completion) { c.Source.Model = "other" }, "root": func(c *Completion) { c.Source.Root = "/other" },
		"old-process": func(c *Completion) { c.Source.PID = p.Source.PID; c.Source.Start = p.Source.Start }, "session": func(c *Completion) { c.Source.Session = "stale" }, "account": func(c *Completion) { c.Source.Account = "other" }, "config": func(c *Completion) { c.Source.Config = "/other" },
		"image": func(c *Completion) { c.ImageSHA256 = Hash([]byte("wrong")) }, "capsule": func(c *Completion) { c.CapsuleSHA256 = Hash([]byte("wrong")) }, "permissions": func(c *Completion) { c.PermissionsRetained = false }, "source-link": func(c *Completion) { c.LinkSource = "stale" }, "target-link": func(c *Completion) { c.LinkTarget = "stale" },
		"job-boot": func(c *Completion) { v := c.Jobs["job"]; v.Boot = "other"; c.Jobs["job"] = v }, "job-start": func(c *Completion) { v := c.Jobs["job"]; v.Start++; c.Jobs["job"] = v }, "job-evidence": func(c *Completion) { v := c.Jobs["job"]; v.EvidenceSHA256 = ""; c.Jobs["job"] = v },
	}
	for name, change := range checks {
		t.Run(name, func(t *testing.T) {
			c, _ := f.Completion(context.Background(), p)
			change(&c)
			if validateCompletion(p, c) == nil {
				t.Fatal("COMPLETION_IDENTITY_OR_JOB_MISMATCH_ACCEPTED", name)
			}
		})
	}
}

func TestCapacityCoalesceCannotAdmitSecondLaneOrStalePlan(t *testing.T) {
	c, p, f := fixture(t)
	original := c.Adapter
	c.Adapter = NativeUnavailable{}
	if o, err := c.Request(context.Background(), p); err != nil || o.State != "held" {
		t.Fatal(err, o)
	}
	c.Adapter = original
	other := p
	other.ID = "second-operation"
	d, _ := c.Journal.Load()
	other.PolicyRevision = d.Revision
	if o, err := c.Request(context.Background(), other); err != nil || o.State != "prepared" {
		t.Fatal(err, o)
	}
	if _, err := c.Coalesce(context.Background(), p); err == nil {
		t.Fatal("COALESCE_CREATED_SECOND_ACTIVE_LANE")
	}
	if len(f.effects) != 0 {
		t.Fatal("COALESCE_EXECUTED_EFFECT")
	}
	c, p, _ = fixture(t)
	if _, err := c.Request(context.Background(), p); err != nil {
		t.Fatal(err)
	}
	c.Now = func() int64 { return clock + MaxAgeMS + 1 }
	if _, err := c.Coalesce(context.Background(), p); err == nil {
		t.Fatal("COALESCE_REFRESHED_STALE_OBSERVATION")
	}
}

func TestCapacityReconcileRequiresIndependentNoLaunch(t *testing.T) {
	c, p, f := fixture(t)
	f.fail = "retire"
	if _, err := c.Request(context.Background(), p); err != nil {
		t.Fatal(err)
	}
	if o, err := c.Advance(context.Background(), p.ID); err != nil || o.State != "unknown" {
		t.Fatal(err, o)
	}
	f.fail = ""
	f.noLaunch = false
	if _, err := c.ReconcileSourceExit(context.Background(), p.ID); err == nil {
		t.Fatal("UNISSUED_LAUNCH_NOT_INDEPENDENTLY_CONFIRMED")
	}
	d, _ := c.Journal.Load()
	if d.Operations[p.ID].State != "unknown" || f.effects["launch"] != 0 {
		t.Fatal("RECONCILIATION_LAUNCHED_WITHOUT_EVIDENCE")
	}
}

func TestCapacityPlanQuotaModelIdentityBound(t *testing.T) {
	for _, part := range []string{"source", "target"} {
		c, p, f := fixture(t)
		if part == "source" {
			p.SourceQuota.Model = "wrong-model"
		} else {
			p.TargetQuota.Model = "wrong-model"
		}
		o, err := c.Request(context.Background(), p)
		if err != nil || o.State != "held" || o.Reason != "target_capacity_or_reset_fence_unavailable" || len(f.effects) != 0 {
			t.Fatal("QUOTA_MODEL_IDENTITY_CONTRADICTION_ACCEPTED", part, o, err)
		}
	}
}
