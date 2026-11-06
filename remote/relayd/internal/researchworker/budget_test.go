package researchworker

import (
	"context"
	"math"
	"strings"
	"testing"
)

func TestBudgetLimitsArePassesOneRetriesZeroWall180USD3(t *testing.T) {
	if DefaultBudget != (Budget{Passes: 1, Retries: 0, WallSeconds: 180, USD: 3}) {
		t.Fatalf("default budget %+v", DefaultBudget)
	}
	for _, provider := range []string{ProviderClaude, ProviderCodex} {
		for name, budget := range map[string]Budget{
			"default":   DefaultBudget,
			"short":     {Passes: 1, Retries: 0, WallSeconds: 1, USD: 0.01},
			"wall edge": {Passes: 1, Retries: 0, WallSeconds: 180, USD: 1},
			"usd edge":  {Passes: 1, Retries: 0, WallSeconds: 60, USD: 3},
		} {
			p := basePolicy(provider)
			p.Budget = budget
			if _, err := Plan(p, testWorkerDir); err != nil {
				t.Fatalf("%s/%s refused: %v", provider, name, err)
			}
		}
		for name, edit := range map[string]func(*Budget){
			"zero passes":    func(b *Budget) { b.Passes = 0 },
			"two passes":     func(b *Budget) { b.Passes = 2 },
			"one retry":      func(b *Budget) { b.Retries = 1 },
			"negative retry": func(b *Budget) { b.Retries = -1 },
			"zero wall":      func(b *Budget) { b.WallSeconds = 0 },
			"wall 181":       func(b *Budget) { b.WallSeconds = 181 },
			"zero usd":       func(b *Budget) { b.USD = 0 },
			"negative usd":   func(b *Budget) { b.USD = -1 },
			"usd 3.01":       func(b *Budget) { b.USD = 3.01 },
			"usd NaN":        func(b *Budget) { b.USD = math.NaN() },
			"usd +Inf":       func(b *Budget) { b.USD = math.Inf(1) },
		} {
			p := basePolicy(provider)
			edit(&p.Budget)
			if _, err := Plan(p, testWorkerDir); err == nil {
				t.Fatalf("%s/%s accepted: %+v", provider, name, p.Budget)
			}
		}
	}
	p := basePolicy(ProviderClaude)
	p.Budget.USD = 0.5
	launch, _ := Plan(p, testWorkerDir)
	if value(t, launch.Argv, "--max-budget-usd") != "0.5" {
		t.Fatal("Claude is not capped at the budget")
	}
	launch, _ = Plan(basePolicy(ProviderCodex), testWorkerDir)
	for _, a := range launch.Argv {
		if strings.Contains(a, "budget") {
			t.Fatalf("Codex given a budget flag it does not have: %s", a)
		}
	}
	if !strings.Contains(strings.Join(launch.Unverified, " "), USDUnknown) {
		t.Fatalf("Codex plan does not say usd is unknown: %q", launch.Unverified)
	}
}

func TestClaudeBudgetReceipt(t *testing.T) {
	h := newHarness(t)
	receipt, err := Run(context.Background(), h.request(t, ProviderClaude, "ok"))
	if err != nil {
		t.Fatal(err)
	}
	b := receipt.Budget
	if !receipt.Verified || b.Passes.Used != 1 || b.Passes.Status != CheckVerified || b.Retries.Used != 0 || b.Retries.Status != CheckVerified ||
		b.WallSeconds.Limit != 180 || b.WallSeconds.Status != CheckVerified || b.USD.Limit != 3.0 || b.USD.Used != 0.42 || b.USD.Status != CheckVerified {
		t.Fatalf("budget %+v", b)
	}
	if used, ok := b.WallSeconds.Used.(float64); !ok || used < 0 || used > 180 {
		t.Fatalf("wall used %v", b.WallSeconds.Used)
	}
	if receipt.Binding.Budget != DefaultBudget {
		t.Fatalf("binding budget %+v", receipt.Binding.Budget)
	}
	// The same request_id with another budget is a different binding.
	request := h.request(t, ProviderClaude, "ok")
	request.Policy.Budget.WallSeconds = 120
	if _, err := Run(context.Background(), request); err == nil || !strings.Contains(err.Error(), "already bound") {
		t.Fatalf("budget change accepted: %v", err)
	}
	if len(h.runs(t)) != 1 {
		t.Fatal("budget change started a worker")
	}
}

func TestClaudeBudgetViolationsAndUnknownCost(t *testing.T) {
	over, _ := Run(context.Background(), newHarness(t).request(t, ProviderClaude, "over-budget"))
	if over.Verified || over.Budget.USD.Status != CheckViolated || over.Budget.USD.Used != 3.5 {
		t.Fatalf("over budget %+v", over.Budget.USD)
	}
	twice, _ := Run(context.Background(), newHarness(t).request(t, ProviderClaude, "two-results"))
	if twice.Verified || twice.Budget.Passes.Status != CheckViolated {
		t.Fatalf("two passes %+v", twice.Budget.Passes)
	}
	unknown, _ := Run(context.Background(), newHarness(t).request(t, ProviderClaude, "no-cost"))
	if unknown.Budget.USD.Status != USDUnknown || unknown.Budget.USD.Used != nil || unknown.CostUSD != nil {
		t.Fatalf("missing cost not reported as unknown: %+v", unknown.Budget.USD)
	}
	// Unknown cost is stated, not treated as a pass or a violation of the other checks.
	if !unknown.Verified || status(unknown, "usd") != CheckUnverified {
		t.Fatalf("unknown cost receipt %+v", unknown.Checks)
	}
	timeout := newHarness(t).request(t, ProviderClaude, "hang")
	timeout.Policy.Budget.WallSeconds = 1
	slow, _ := Run(context.Background(), timeout)
	if slow.Budget.WallSeconds.Status != CheckViolated || slow.Budget.WallSeconds.Limit != 1 || slow.Budget.USD.Status != USDUnknown || slow.Budget.Passes.Status == CheckVerified {
		t.Fatalf("timed-out budget %+v", slow.Budget)
	}
}

func TestCodexBudgetReceipt(t *testing.T) {
	rollout := func(h *harness) {
		h.rollout(t, map[string]any{"model": "gpt-6", "approval_policy": "never", "sandbox_policy": map[string]any{"type": "read-only"}, "effort": "high", "cwd": h.cwd})
	}
	h := newHarness(t)
	rollout(h)
	receipt, err := Run(context.Background(), h.request(t, ProviderCodex, "ok"))
	if err != nil {
		t.Fatal(err)
	}
	b := receipt.Budget
	if !receipt.Verified || b.Passes.Status != CheckVerified || b.USD.Status != USDUnknown || b.USD.Used != nil || b.USD.Limit != 3.0 || receipt.Usage["input_tokens"] != float64(100) {
		t.Fatalf("Codex budget %+v usage %v", b, receipt.Usage)
	}
	if !strings.Contains(b.USD.Detail, USDUnknown) {
		t.Fatalf("usd detail %q", b.USD.Detail)
	}
	h2 := newHarness(t)
	rollout(h2)
	twice, _ := Run(context.Background(), h2.request(t, ProviderCodex, "two-turns"))
	if twice.Verified || twice.Budget.Passes.Status != CheckViolated {
		t.Fatalf("two turns %+v", twice.Budget.Passes)
	}
	h3 := newHarness(t)
	rollout(h3)
	failed, _ := Run(context.Background(), h3.request(t, ProviderCodex, "turn-failed"))
	if failed.Verified || failed.Budget.Passes.Status == CheckVerified {
		t.Fatalf("failed turn counted as a finished pass: %+v", failed.Budget.Passes)
	}
}
