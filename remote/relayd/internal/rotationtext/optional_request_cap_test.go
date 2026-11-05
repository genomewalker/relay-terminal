package rotationtext

import (
	"context"
	"runtime"
	"testing"
	"time"
)

func TestOptionalAPIRequestCapValidation(t *testing.T) {
	for _, providers := range [][]any{{"anthropic_api"}, {"claude_account"}, {"codex_account"}, {"anthropic_api", "codex_account"}} {
		t.Run(compact(providers), func(t *testing.T) {
			settings := enabledSettings(obj{"providers": providers, "max_requests_per_day": int64(0)})
			if len(providers) == 1 && providers[0] == "anthropic_api" {
				validatedSettings(settings)
			} else {
				safetyCode(t, "positive_limits_required", func() { validatedSettings(settings) })
			}
		})
	}
	for _, key := range []string{"daily_limit_microusd", "monthly_limit_microusd"} {
		t.Run(key, func(t *testing.T) {
			safetyCode(t, "positive_limits_required", func() { validatedSettings(enabledSettings(obj{"max_requests_per_day": int64(0), key: int64(999999)})) })
			safetyCode(t, "api_account_configuration_required", func() { validatedAccount(apiAccount(obj{"max_requests_per_day": int64(0), key: int64(999999)})) })
		})
	}
	validatedAccount(apiAccount(obj{"max_requests_per_day": int64(0)}))
	safetyCode(t, "positive_limits_required", func() { validatedAccount(cliAccount(obj{"max_requests_per_day": int64(0)})) })
	safetyCode(t, "positive_limits_required", func() {
		validatedAccount(cliAccount(obj{"provider": "codex_account", "max_requests_per_day": int64(0)}))
	})
}

func TestOptionalAPIRequestCapJournal(t *testing.T) {
	ctx := context.Background()
	t.Run("zero_allows_assistant_and_health", func(t *testing.T) {
		j, _ := safetyJournal(t, 0)
		calls := safetyPost(t, safetyAnswer())
		for n := 1; n <= 12; n++ {
			safetyEq(t, j.Assist(ctx, safetyAssist(n, n))["status"], "complete")
		}
		safetyPost(t, safetyResponse([]any{safetyCall("inspect_pane")}))
		safetyEq(t, j.Assess(ctx, safetyAssess(900))["status"], "complete")
		safetyEq(t, *calls, 12)
	})
	for _, period := range []string{"daily", "monthly"} {
		t.Run("zero_preserves_"+period+"_reservation", func(t *testing.T) {
			j, _ := safetyJournal(t, 0)
			u := j.usage()
			charged := int64(49_000_001)
			day := u.day
			if period == "monthly" {
				charged = 199_000_001
				day = "1900-01-01"
			}
			j.transaction(func() {
				must(j.store.InsertOperation(Operation{ID: safetyID(800), Fingerprint: "budget", SettingsDigest: "x", State: "complete", Day: day, Month: u.month, Charged: charged}))
			})
			calls := safetyPost(t, safetyAnswer())
			safetyCode(t, "spending_limit", func() { j.Assist(ctx, safetyAssist(1, 1)) })
			safetyEq(t, *calls, 0)
		})
	}
	t.Run("zero_preserves_uncertain_hold", func(t *testing.T) {
		j, _ := safetyJournal(t, 0)
		calls := 0
		apiPostHook = func([]byte, string, time.Duration) []byte { calls++; fail("request_outcome_unknown"); return nil }
		r := safetyAssist(1, 1)
		first := j.Assist(ctx, r)
		safetyEq(t, first["status"], "uncertain")
		safetyEq(t, first["charged_microusd"], apiReservationMicroUSD)
		safetyEq(t, j.Assist(ctx, r), first)
		safetyCode(t, "reconciliation_required", func() { j.Assist(ctx, safetyAssist(2, 2)) })
		safetyEq(t, calls, 1)
	})
	t.Run("zero_allows_chore_201", func(t *testing.T) {
		j, _ := safetyJournal(t, 0)
		u := j.usage()
		j.transaction(func() {
			for n := 1; n <= assistantDailyRequestLimit; n++ {
				must(j.store.InsertOperation(Operation{ID: safetyID(1000 + n), Fingerprint: safetyID(n), SettingsDigest: "x", State: "complete", Day: u.day, Month: u.month, Purpose: "relay_assistant", RequestID: safetyID(n)}))
			}
		})
		calls := safetyPost(t, safetyAnswer())
		safetyEq(t, j.Assist(ctx, safetyAssist(1, 999))["status"], "complete")
		safetyEq(t, *calls, 1)
	})
	t.Run("zero_preserves_step_limit", func(t *testing.T) {
		j, _ := safetyJournal(t, 0)
		calls := safetyPost(t, safetyAnswer())
		for n := 1; n <= 9; n++ {
			safetyEq(t, j.Assist(ctx, safetyAssist(n, 1))["status"], "complete")
		}
		safetyCode(t, "assistant_request_step_limit", func() { j.Assist(ctx, safetyAssist(10, 1)) })
		safetyEq(t, *calls, 9)
	})
}

func TestOptionalAPIAccountRequestCap(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("credential helper fixture is macOS-specific")
	}
	ctx := context.Background()
	for _, cap := range []int64{0, 11} {
		name := "uncapped"
		if cap > 0 {
			name = "positive_cap"
		}
		t.Run(name, func(t *testing.T) {
			j, _ := safetyJournal(t, 0)
			f := newCLIFixture(t)
			old := CredentialHelper
			CredentialHelper = f.helper
			t.Cleanup(func() { CredentialHelper = old })
			account := apiAccount(obj{"max_requests_per_day": cap})
			j.Configure(safetyID(700), enabledSettings(obj{"max_requests_per_day": int64(0), "accounts": []any{account}}), nil)
			calls := safetyPost(t, safetyAnswer())
			safetyEq(t, j.Assist(ctx, safetyAssist(1, 1))["status"], "complete")
			if cap > 0 {
				safetyCode(t, "assistant_health_reserve", func() { j.Assist(ctx, safetyAssist(2, 2)) })
				safetyEq(t, *calls, 1)
			} else {
				safetyEq(t, j.Assist(ctx, safetyAssist(2, 2))["status"], "complete")
				u := j.usage()
				j.transaction(func() {
					must(j.store.InsertOperation(Operation{ID: safetyID(800), Fingerprint: "account-budget", SettingsDigest: "x", State: "complete", Day: u.day, Month: u.month, Charged: 4_000_001, AccountID: acctAPI, BillingGroup: "team-a"}))
				})
				safetyCode(t, "spending_limit", func() { j.Assist(ctx, safetyAssist(3, 3)) })
				safetyEq(t, *calls, 2)
			}
		})
	}
}
