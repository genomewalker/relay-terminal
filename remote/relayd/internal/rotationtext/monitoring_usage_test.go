package rotationtext

import (
	"testing"
	"time"
)

func TestMonitoringUsageSeparatesHealthAndAssistantCharges(t *testing.T) {
	j, _ := safetyJournal(t, 100)
	j.now = func() time.Time { return time.Date(2026, 11, 4, 12, 0, 0, 0, time.UTC) }
	providerResult := `{"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":99,"cache_creation_input_tokens":100}}`
	if err := j.store.Begin(); err != nil {
		t.Fatal(err)
	}
	for _, r := range []Operation{
		{ID: "health", Fingerprint: "health", Day: "2026-11-04", Month: "2026-11", Purpose: "pane_health", Charged: 24000, State: "complete", Result: &providerResult},
		{ID: "assistant", Fingerprint: "assistant", Day: "2026-11-04", Month: "2026-11", Purpose: "relay_assistant", Charged: 1400000, State: "complete"},
		{ID: "prior", Fingerprint: "prior", Day: "2026-11-03", Month: "2026-11", Purpose: "pane_health", Charged: 3000, State: "complete"},
	} {
		if err := j.store.InsertOperation(r); err != nil {
			t.Fatal(err)
		}
	}
	if err := j.store.Commit(); err != nil {
		t.Fatal(err)
	}
	usage := j.Status(nil)["purpose_usage"].(obj)
	safetyEq(t, usage["pane_health"].(obj)["requests_today"], 1)
	safetyEq(t, usage["pane_health"].(obj)["charged_today_microusd"], 24000)
	safetyEq(t, usage["pane_health"].(obj)["charged_month_microusd"], 27000)
	safetyEq(t, usage["pane_health"].(obj)["input_tokens_today"], 10)
	safetyEq(t, usage["pane_health"].(obj)["cache_read_input_tokens_today"], 99)
	safetyEq(t, usage["relay_assistant"].(obj)["charged_today_microusd"], 1400000)
	safetyEq(t, j.Status(nil)["cost_basis"], "conservative_journal_charge_not_provider_invoice")
}
