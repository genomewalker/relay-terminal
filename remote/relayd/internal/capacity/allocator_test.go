package capacity

import (
	"encoding/json"
	"math"
	"strings"
	"testing"
)

func codexQuota(label, dir string, used float64) Account {
	return Account{Label: label, Config: dir, Provider: "codex", Model: "observed-model", Compatible: true, ScopeKnown: true, ObservedMS: clock, Windows: []Window{{Name: "primary", Used: used, ResetMS: clock + 10000, DurationMinutes: 300}, {Name: "secondary", Used: used, ResetMS: clock + 20000, DurationMinutes: 10080}}}
}
func TestCapacityWeightedBothProvidersAndUnknown(t *testing.T) {
	for _, provider := range []string{"claude", "codex"} {
		e, s, c := entry(), policy(), sample()
		c.Tokens = 90000
		e.Source.Provider = provider
		var a, b Account
		if provider == "codex" {
			a = codexQuota("team", "/team", 50)
			b = codexQuota("personal", "/personal", 50)
			s.Approved = []string{"codex:team", "codex:personal"}
		} else {
			a = quota("team", "/team", 50, 50)
			b = quota("personal", "/personal", 50, 50)
		}
		s.Weights = []Weight{{Provider: provider, Account: "team", Model: "observed-model", Value: 1, AsOfMS: clock - 1000, ExpiresMS: clock + 100000, Provenance: "user_assumption"}, {Provider: provider, Account: "personal", Model: "observed-model", Value: 5, AsOfMS: clock - 1000, ExpiresMS: clock + 100000, Provenance: "user_assumption"}}
		d := Decide(e, s, c, []Account{a, b}, clock)
		if !d.RebalanceDue || d.Target != "personal" || d.Ranking != "relative_capacity_weighted_headroom_estimate" || d.Scores[1].Value == nil || *d.Scores[1].Value != 2.25 {
			t.Fatal("EQUAL_PERCENT_UNEQUAL_WEIGHT", provider, d)
		}
		if d.Ready || d.Scores[1].Absolute != "not_reported_by_usage_adapter" {
			t.Fatal("ESTIMATE_MISREPRESENTED_AS_ABSOLUTE", d)
		}
		// Reverse placement reverses the decision only when relative score changes;
		// a past manual placement is not an implicit pin in the default-on mode.
		e.Manual = true
		s.Weights[0].Value = 10
		s.Weights[1].Value = 1
		e.Source.Account = "personal"
		e.Source.Config = "/personal"
		d = Decide(e, s, c, []Account{a, b}, clock)
		if !d.RebalanceDue || d.Target != "team" {
			t.Fatal("BIDIRECTIONAL_WEIGHTED_MANUAL_HISTORY", provider, d)
		}
		e.Pinned = true
		e.Enabled = false
		if Decide(e, s, c, []Account{a, b}, clock).Target != "" {
			t.Fatal("WEIGHT_BYPASSED_EXPLICIT_PIN")
		}
		e = entry()
		e.Source.Provider = provider
		s.Weights = nil
		a.Plan = "team"
		b.Plan = "pro"
		d = Decide(e, s, c, []Account{a, b}, clock)
		if d.RebalanceDue || d.Scores[0].Known || d.Scores[1].Known {
			t.Fatal("PLAN_LABEL_FABRICATED_CAPACITY", provider, d)
		}
	}
}
func TestCapacityWeightInvalidStaleBottleneckAndCompatibility(t *testing.T) {
	s := policy()
	a := quota("personal", "/personal", 20, 90)
	score := ScoreAccount(a, s, "observed-model", clock)
	if !score.Known || score.Limiting != "seven_day" || score.Value == nil || math.Abs(*score.Value-0.05) > 1e-9 {
		t.Fatal("WEIGHTED_MULTI_WINDOW_BOTTLENECK", score)
	}
	for _, value := range []float64{0, -1, math.NaN(), math.Inf(1), math.Inf(-1), 1000001} {
		bad := policy()
		bad.Weights[0].Value = value
		if bad.Valid() {
			t.Fatal("INVALID_WEIGHT_ACCEPTED", value)
		}
	}
	for _, mutate := range []func(*Weight){func(w *Weight) { w.AsOfMS = clock + 1; w.ExpiresMS = clock + 10000 }, func(w *Weight) { w.ExpiresMS = clock }, func(w *Weight) { w.Model = "other-model" }} {
		test := policy()
		mutate(&test.Weights[1])
		score := ScoreAccount(a, test, "observed-model", clock)
		if score.Known {
			t.Fatal("STALE_FUTURE_OR_WRONG_MODEL_WEIGHT_USED", score)
		}
	}
	a.Compatible = false
	if ScoreAccount(a, s, "observed-model", clock).Eligible {
		t.Fatal("UNSUPPORTED_MODEL_ACCOUNT_RANKED")
	}
	a.Compatible = true
	a.ScopeKnown = false
	if ScoreAccount(a, s, "observed-model", clock).Eligible {
		t.Fatal("UNKNOWN_LIMIT_SCOPE_RANKED")
	}
	a.ScopeKnown = true
	a.Reserved = true
	if ScoreAccount(a, s, "observed-model", clock).Eligible {
		t.Fatal("RESERVED_ACCOUNT_RANKED")
	}
	a.Reserved = false
	a.Windows[0].Used = 101
	if ScoreAccount(a, s, "observed-model", clock).Known {
		t.Fatal("INVALID_COUNTER_SCORED")
	}
	s = Defaults()
	if !s.RebalanceEnabled || len(s.Approved) != 0 || len(s.Weights) != 0 {
		t.Fatal("DEFAULT_ON_EXPANDED_ACCOUNT_AUTHORITY")
	}
}
func codexObservation() []byte {
	raw := `{"id":2,"result":{"accountId":"account-test","ordinaryUsageAllowed":true,"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":2000},"secondary":{"usedPercent":50,"windowDurationMins":10080,"resetsAt":3000},"spendControlReached":false}}}}` + "\n" + `{"id":3,"result":{"accountId":"account-test","account":{"type":"chatgpt","id":"account-test","email":"fixture@example.invalid","planType":"pro"}}}`
	return []byte(raw)
}
func TestCapacityCodexUsesActualSchemaAndBackendPermissions(t *testing.T) {
	raw := codexObservation()
	windows, plan, err := ParseCodexObservation(raw)
	if err != nil || plan != "pro" || len(windows) != 2 || windows[0].Name != "codex:codex:primary" || windows[0].DurationMinutes != 300 || windows[1].DurationMinutes != 10080 {
		t.Fatal("CODEX_ACTUAL_WINDOW_SCHEMA", windows, plan, err)
	}
	for _, test := range []struct{ old, new string }{{`"ordinaryUsageAllowed":true`, `"ordinaryUsageAllowed":null`}, {`"spendControlReached":false`, `"spendControlReached":null`}, {`"ordinaryUsageAllowed":true`, `"ordinaryUsageAllowed":false`}, {`"windowDurationMins":300`, `"windowDurationMins":null`}, {`"accountId":"account-test","account"`, `"accountId":"other","account"`}, {`"usedPercent":20`, `"usedPercent":20,"usedPercent":30`}, {`"accountId":"account-test","account":{"type":"chatgpt","id":"account-test",`, `"account":{"type":"chatgpt",`}, {`"type":"chatgpt","id":"account-test"`, `"type":"chatgpt","id":"other"`}} {
		input := strings.Replace(string(raw), test.old, test.new, 1)
		if _, _, err := ParseCodexObservation([]byte(input)); err == nil {
			t.Fatal("CODEX_UNKNOWN_OR_CONTRADICTED_EVIDENCE_ACCEPTED", test)
		}
	}
	// Claude-shaped windows cannot be substituted into a Codex account.
	fake := codexQuota("pro", "/pro", 20)
	fake.Windows = []Window{{Name: "five_hour", Used: 20, ResetMS: clock + 1000, DurationMinutes: 300}, {Name: "seven_day", Used: 20, ResetMS: clock + 2000, DurationMinutes: 10080}}
	if fake.Current(clock) {
		t.Fatal("CLAUDE_SCHEMA_ASSUMED_FOR_CODEX")
	}
}
func FuzzCapacityCodexObservation(f *testing.F) {
	f.Add(codexObservation())
	f.Add([]byte(strings.Replace(string(codexObservation()), `"usedPercent":20`, `"usedPercent":101`, 1)))
	f.Add([]byte(`{"id":2,"id":3}`))
	f.Fuzz(func(t *testing.T, raw []byte) {
		windows, _, err := ParseCodexObservation(raw)
		if err != nil {
			return
		}
		if len(windows) == 0 || len(windows) > 48 {
			t.Fatal("CODEX_WINDOW_BOUND")
		}
		for _, w := range windows {
			if !codexWindowName(w.Name) || w.Used < 0 || w.Used > 100 || w.ResetMS <= 0 {
				t.Fatal("CODEX_SCHEMA_BINDING")
			}
		}
	})
}
func FuzzCapacityWeights(f *testing.F) {
	seed, _ := json.Marshal(policy().Weights)
	f.Add(seed)
	f.Add([]byte(`[{"value":0,"value":1}]`))
	f.Fuzz(func(t *testing.T, raw []byte) {
		var weights []Weight
		if Decode(raw, &weights) != nil || len(weights) > 64 {
			return
		}
		for _, w := range weights {
			if !w.Valid() {
				continue
			}
			round, _ := json.Marshal(w)
			var back Weight
			if Decode(round, &back) != nil || back != w {
				t.Fatal("WEIGHT_PROVENANCE_ROUNDTRIP")
			}
		}
	})
}

// Exhaust the bounded weighted-policy input product against the real selector.
// Unknown weights cannot become invented capacity and every user fence wins.
func TestCapacityWeightedBoundedMatrix(t *testing.T) {
	states := 0
	for _, provider := range []string{"claude", "codex"} {
		for _, usedA := range []float64{0, 50, 94, 95} {
			for _, usedB := range []float64{0, 50, 94, 95} {
				for _, weightA := range []float64{0, 1, 5} {
					for _, weightB := range []float64{0, 1, 5} {
						for _, allowed := range []bool{false, true} {
							for _, guard := range []string{"none", "pin", "optout", "pause", "takeover"} {
								e, s, c := entry(), policy(), sample()
								c.Tokens = 90000
								e.Source.Provider = provider
								a, b := quota("team", "/team", usedA, usedA), quota("personal", "/personal", usedB, usedB)
								if provider == "codex" {
									a = codexQuota("team", "/team", usedA)
									b = codexQuota("personal", "/personal", usedB)
								}
								s.Approved = []string{provider + ":team"}
								if allowed {
									s.Approved = append(s.Approved, provider+":personal")
								}
								s.Weights = nil
								for i, v := range []float64{weightA, weightB} {
									if v > 0 {
										label := []string{"team", "personal"}[i]
										s.Weights = append(s.Weights, Weight{Provider: provider, Account: label, Model: e.Source.Model, Value: v, AsOfMS: clock - 1000, ExpiresMS: clock + 10000, Provenance: "user_assumption"})
									}
								}
								switch guard {
								case "pin":
									e.Pinned = true
								case "optout":
									e.OptOut = true
								case "pause":
									e.Enabled = false
								case "takeover":
									e.Takeover = true
								}
								d := Decide(e, s, c, []Account{a, b}, clock)
								expected := guard == "none" && allowed && usedB < 95 && weightA > 0 && weightB > 0 && weightB*(95-usedB) > weightA*(95-usedA) && weightB*(95-usedB) >= weightA*(95-usedA)*1.1
								if d.RebalanceDue != expected || (d.RebalanceDue && d.Target != "personal") {
									t.Fatal("WEIGHTED_BOUNDED_SAFETY", provider, usedA, usedB, weightA, weightB, allowed, guard, d)
								}
								states++
							}
						}
					}
				}
			}
		}
	}
	if states != 2880 {
		t.Fatal("WEIGHTED_MATRIX_BOUND", states)
	}
	t.Logf("weighted real-policy exhaustive product: providers=2 source_used=4 target_used=4 source_weight=3 target_weight=3 approval=2 user_states=5 states=%d; safety checked each state", states)
}

func TestCapacityProviderApprovalAndModelScopes(t *testing.T) {
	s := Defaults()
	s.Approved = []string{"claude:personal"}
	if IsApproved(s, "codex", "personal") || !IsApproved(s, "claude", "personal") {
		t.Fatal("PROVIDER_SCOPED_APPROVAL_BYPASSED")
	}
	e, c := entry(), sample()
	c.Tokens = 90000
	s = policy()
	s.Weights[1].Value = 5
	target := codexQuota("personal", "/personal", 0)
	if d := Decide(e, s, c, []Account{quota("team", "/team", 50, 50), target}, clock); d.RebalanceDue || d.Target != "" {
		t.Fatal("CROSS_PROVIDER_CONVERSION_SELECTED", d)
	}
	target = quota("personal", "/personal", 0, 0)
	target.Model = "unsupported-model"
	if d := Decide(e, s, c, []Account{quota("team", "/team", 50, 50), target}, clock); d.Target != "" {
		t.Fatal("UNSUPPORTED_MODEL_SELECTED", d)
	}
}

func TestCapacityResetArithmeticAndAccountLabelDomain(t *testing.T) {
	e := entry()
	e.Away = &Away{OriginalAccount: "team", OriginalConfig: "/team", Owner: "owner", Resets: map[string]int64{"five_hour": math.MaxInt64}}
	if e.Valid() {
		t.Fatal("RESET_FENCE_OVERFLOW_DOMAIN_ACCEPTED")
	}
	a := quota("personal", "/personal", 10, 10)
	a.Windows[0].ResetMS = math.MaxInt64
	if a.Current(clock) {
		t.Fatal("RESET_OBSERVATION_OVERFLOW_DOMAIN_ACCEPTED")
	}
	for _, label := range []string{"space label", "UPPER", "dots.x", "a:b", "-start", strings.Repeat("a", 25)} {
		s := policy()
		s.Approved = []string{"claude:" + label}
		if s.Valid() {
			t.Fatal("APPROVAL_LABEL_DOMAIN_MISMATCH", label)
		}
		s = policy()
		s.Weights[0].Account = label
		if s.Valid() {
			t.Fatal("WEIGHT_LABEL_DOMAIN_MISMATCH", label)
		}
	}
}
