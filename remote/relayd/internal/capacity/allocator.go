package capacity

import (
	"math"
	"strings"
)

// Weight is an explicit, dated USER assumption for a fixed provider/model
// workload, not a price/plan multiplier, entitlement or measured token limit.
type Weight struct {
	Provider   string  `json:"provider"`
	Account    string  `json:"account"`
	Model      string  `json:"model"`
	Value      float64 `json:"value"`
	AsOfMS     int64   `json:"as_of_ms"`
	ExpiresMS  int64   `json:"expires_ms"`
	Provenance string  `json:"provenance"`
	Note       string  `json:"note"`
}

func (w Weight) Valid() bool {
	return (w.Provider == "codex" || w.Provider == "claude") && accountLabel(w.Account) && w.Model != "" && len(w.Model) <= 256 && !strings.ContainsAny(w.Model, "\x00\n\r") && w.Value > 0 && w.Value <= 1000000 && !math.IsNaN(w.Value) && !math.IsInf(w.Value, 0) && w.AsOfMS > 0 && w.ExpiresMS > w.AsOfMS && w.ExpiresMS-w.AsOfMS <= 30*86400000 && w.Provenance == "user_assumption" && len(w.Note) <= 256
}
func weightFor(s Settings, a Account, model string, now int64) (Weight, bool) {
	var exact, wild *Weight
	for i := range s.Weights {
		w := &s.Weights[i]
		if w.Provider != a.Provider || w.Account != a.Label {
			continue
		}
		if w.Model == model {
			exact = w
		} else if w.Model == "*" {
			wild = w
		}
	}
	chosen := exact
	if chosen == nil {
		chosen = wild
	}
	if chosen == nil || !chosen.Valid() || now < chosen.AsOfMS || now >= chosen.ExpiresMS {
		return Weight{}, false
	}
	return *chosen, true
}

type Score struct {
	Provider string   `json:"provider"`
	Account  string   `json:"account"`
	Model    string   `json:"model"`
	Known    bool     `json:"known"`
	Eligible bool     `json:"eligible"`
	Value    *float64 `json:"value"`
	Weight   *Weight  `json:"weight"`
	Unit     string   `json:"unit"`
	Limiting string   `json:"limiting_window"`
	Reason   string   `json:"reason"`
	Absolute string   `json:"absolute_capacity"`
	Plan     string   `json:"observed_plan"`
}

// ScoreAccount normalizes each observed percentage to a remaining fraction of
// its own reported limit, then uses the minimum fraction as the bottleneck.
// A user workload weight supplies the common relative-capacity scale. No raw
// currencies, token counters or cross-provider scores are compared.
func ScoreAccount(a Account, s Settings, model string, now int64) Score {
	out := Score{Provider: a.Provider, Account: a.Label, Model: model, Unit: "relative_capacity_weighted_headroom_estimate", Reason: "weight_assumption_missing_or_stale", Absolute: "not_reported_by_usage_adapter", Plan: a.Plan}
	if !a.ObservationCurrent(now) {
		out.Reason = "fresh_provider_window_observation_unavailable"
		return out
	}
	w, ok := weightFor(s, a, model, now)
	if !ok {
		return out
	}
	out.Weight = &w
	fraction := 1.0
	for _, window := range a.Windows {
		v := (s.TargetCeiling - window.Used) / 100
		if v < fraction {
			fraction = v
			out.Limiting = window.Name
		}
	}
	value := w.Value * math.Max(0, fraction)
	out.Value = &value
	out.Known = true
	out.Eligible = a.Current(now) && a.Model == model && fraction > 0
	out.Reason = "user_assumption_not_measured_absolute_capacity"
	if !a.Compatible {
		out.Reason = "provider_or_model_incompatible_or_unverified"
	} else if !a.ScopeKnown {
		out.Reason = "provider_limit_scope_or_backend_permission_unavailable"
	}
	return out
}
func weightedImprovement(current, target Score, s Settings) bool {
	return current.Known && target.Known && target.Eligible && current.Value != nil && target.Value != nil && *target.Value > 0 && *target.Value >= *current.Value*(1+s.Hysteresis/100) && *target.Value > *current.Value
}
