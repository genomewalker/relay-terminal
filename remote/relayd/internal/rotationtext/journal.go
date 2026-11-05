package rotationtext

import (
	"context"
	"encoding/json"
	"errors"
	"math/big"
	"time"
)

// Operation is one row of the text journal's operations table.
type Operation struct {
	ID             string  `json:"id"`
	Fingerprint    string  `json:"fingerprint"`
	SettingsDigest string  `json:"settings_digest"`
	State          string  `json:"state"`
	Day            string  `json:"day"`
	Month          string  `json:"month"`
	Reserved       int64   `json:"reserved"`
	Charged        int64   `json:"charged"`
	Result         *string `json:"result"` // NULL until the outcome is recorded
	AccountID      string  `json:"account_id"`
	BillingGroup   string  `json:"billing_group"`
	Purpose        string  `json:"purpose"`
	RequestID      string  `json:"request_id"`
}

// Store is the journal's durable state: the Ledger in rotation-text/, shared by
// the text service and the pane-health controller, replacing the
// operations.sqlite3 text_backend.py kept. Begin is BEGIN IMMEDIATE: one
// exclusive writer until Commit or Rollback. Reads outside a transaction see
// committed state. Operations are returned in insertion (rowid) order.
type Store interface {
	Begin() error
	Commit() error
	Rollback() error
	InTransaction() bool
	// InitSettings inserts the singleton settings row unless it exists.
	InitSettings(value string) error
	Settings() (operationID, value string, ok bool, err error)
	UpdateSettings(operationID, value string) error
	ConfigurationChange(id string) (value string, ok bool, err error)
	InsertConfigurationChange(id, value string) error
	Operations() ([]Operation, error)
	InsertOperation(Operation) error
	// FinishOperation records an outcome only while the row is still pending.
	FinishOperation(id, state string, charged int64, result string) error
	// AbandonOperation marks a pending or uncertain row abandoned.
	AbandonOperation(id string) error
	Close() error
}

var defaultSettings = obj{"enabled": false, "providers": []any{"anthropic_api"},
	"daily_limit_microusd": int64(0), "monthly_limit_microusd": int64(0), "max_requests_per_day": int64(0)}

// Journal is TextJournal: a budgeted, journaled front for the backends.
type Journal struct {
	store   Store
	backend func(context.Context, obj) any
	now     func() time.Time
}

// OpenJournal prepares the store's default settings row.
func OpenJournal(store Store, execute func(context.Context, any) any, now func() time.Time) (*Journal, error) {
	if execute == nil {
		execute = Draft
	}
	if now == nil {
		now = time.Now
	}
	if err := store.InitSettings(compact(defaultSettings)); err != nil {
		return nil, err
	}
	return &Journal{store: store, backend: func(ctx context.Context, request obj) any { return execute(ctx, request) }, now: now}, nil
}

func (j *Journal) Close() error { return j.store.Close() }

// must turns a store failure into the sqlite3.Error Python would raise; a
// ledger that stopped itself (poisoned, durability unknown) keeps its code.
func must(err error) {
	var refusal ledgerRefusal
	if errors.As(err, &refusal) {
		fail(refusal.Code())
	}
	if err != nil {
		raise("StoreError")
	}
}

// ledgerRefusal is a ledger state only an operator can clear; its message
// names the files and the recovery.
type ledgerRefusal interface {
	error
	Code() string
	operatorRecovery()
}

func (*errLedgerDiverged) operatorRecovery()          {}
func (*errLedgerPoisoned) operatorRecovery()          {}
func (*errLedgerDurabilityUnknown) operatorRecovery() {}

// transaction runs fn between BEGIN IMMEDIATE and COMMIT, rolling back and
// re-raising whatever fn (or the commit) raises.
func (j *Journal) transaction(fn func()) {
	must(j.store.Begin())
	defer func() {
		if value := recover(); value != nil {
			if j.store.InTransaction() {
				j.store.Rollback()
			}
			panic(value)
		}
	}()
	fn()
	must(j.store.Commit())
}

// storeText refuses a lone surrogate exactly where sqlite3 would fail to bind it.
func storeText(values ...string) {
	for _, value := range values {
		encodeUTF8(value)
	}
}

func (j *Journal) operations() []Operation {
	rows, err := j.store.Operations()
	must(err)
	return rows
}

func (j *Journal) configuration() (string, obj) {
	id, value, ok, err := j.store.Settings()
	must(err)
	if !ok {
		fail("journal_corrupt")
	}
	if id != "" {
		validOperationID(id)
	}
	return id, validatedSettings(parseJSON(value))
}

func (j *Journal) Configure(operationID any, settings any, expected any) obj {
	validOperationID(operationID)
	if expected != nil {
		text, ok := expected.(string)
		if !ok {
			fail("invalid_request")
		}
		if text != "" {
			validOperationID(text)
		}
	}
	value := compact(validatedSettings(settings))
	id := operationID.(string)
	j.transaction(func() {
		existing, found, err := j.store.ConfigurationChange(id)
		must(err)
		if found {
			if existing != value {
				fail("operation_identity_conflict")
			}
			return
		}
		if expected != nil {
			current, _, ok, err := j.store.Settings()
			must(err)
			if !ok || current != expected.(string) {
				fail("configuration_changed")
			}
		}
		storeText(value)
		must(j.store.InsertConfigurationChange(id, value))
		must(j.store.UpdateSettings(id, value))
	})
	return j.Status(nil)
}

type usageTotals struct {
	day, month            string
	count, daily, monthly *big.Int
}

func (j *Journal) usage() usageTotals {
	now := j.now().UTC()
	totals := usageTotals{day: now.Format("2006-01-02"), month: now.Format("2006-01"),
		count: new(big.Int), daily: new(big.Int), monthly: new(big.Int)}
	for _, row := range j.operations() {
		if row.Day == totals.day {
			totals.count.Add(totals.count, bigInt(1))
			totals.daily.Add(totals.daily, bigInt(row.Charged))
		}
		if row.Month == totals.month {
			totals.monthly.Add(totals.monthly, bigInt(row.Charged))
		}
	}
	return totals
}

func (j *Journal) accountUsage(accountID any, billingGroup any) obj {
	totals := j.usage()
	requests, today, month := new(big.Int), new(big.Int), new(big.Int)
	groupDay, groupMonth := new(big.Int), new(big.Int)
	group, _ := billingGroup.(string)
	for _, row := range j.operations() {
		if pyEqual(row.AccountID, accountID) {
			if row.Day == totals.day {
				requests.Add(requests, bigInt(1))
				today.Add(today, bigInt(row.Charged))
			}
			if row.Month == totals.month {
				month.Add(month, bigInt(row.Charged))
			}
		}
		if truthy(billingGroup) && row.BillingGroup == group {
			if row.Day == totals.day {
				groupDay.Add(groupDay, bigInt(row.Charged))
			}
			if row.Month == totals.month {
				groupMonth.Add(groupMonth, bigInt(row.Charged))
			}
		}
	}
	return obj{"account_id": accountID, "requests_today": normInt(requests), "charged_today_microusd": normInt(today),
		"charged_month_microusd": normInt(month), "billing_group": billingGroup,
		"group_charged_today_microusd": normInt(groupDay), "group_charged_month_microusd": normInt(groupMonth)}
}

// selectAccount follows operator provider and profile order. Selection is
// preflight-only and journaled once before the backend can submit.
func (j *Journal) selectAccount(ctx context.Context, settings obj, apiOnly bool) (obj, obj) {
	eligible, blocked := 0, 0
	for _, rawProvider := range settings["providers"].([]any) {
		provider := rawProvider.(string)
		if apiOnly && provider != "anthropic_api" {
			continue
		}
		for _, rawAccount := range settings["accounts"].([]any) {
			account := rawAccount.(obj)
			if !account["enabled"].(bool) || account["provider"] != provider {
				continue
			}
			eligible++
			usage := j.accountUsage(account["id"], getDefault(account, "billing_group", ""))
			reserved := bigInt(0)
			if provider == "anthropic_api" {
				reserved = bigInt(apiReservationMicroUSD)
			}
			over := func(used string, limit string) bool {
				total := new(big.Int).Add(bigOf(usage[used]), reserved)
				return total.Cmp(bigOf(account[limit])) > 0
			}
			if requestCapReached(bigOf(usage["requests_today"]), bigOf(account["max_requests_per_day"])) ||
				over("charged_today_microusd", "daily_limit_microusd") || over("charged_month_microusd", "monthly_limit_microusd") ||
				provider == "anthropic_api" && (over("group_charged_today_microusd", "daily_limit_microusd") ||
					over("group_charged_month_microusd", "monthly_limit_microusd")) {
				blocked++
				continue
			}
			var config obj
			err := catchDraftObj(func() { config = preflightAccount(ctx, account) })
			if err == nil {
				return account, config
			}
			if !err.unavailable {
				panic(err)
			}
		}
	}
	if eligible > 0 && blocked == eligible {
		fail("spending_limit")
	}
	fail("no_ready_account")
	return nil, nil
}

// Status reports one operation, or the journal's budget and unresolved rows.
func (j *Journal) Status(operationID any) obj {
	if truthy(operationID) {
		validOperationID(operationID)
		for _, row := range j.operations() {
			if row.ID != operationID.(string) {
				continue
			}
			var result any = obj{"v": int64(1), "status": "outcome_unknown", "operation_id": operationID}
			if row.Result != nil && *row.Result != "" {
				result = parseJSON(*row.Result)
			}
			return obj{"v": int64(1), "status": row.State, "operation_id": operationID,
				"charged_microusd": row.Charged, "result": result,
				"account_id": row.AccountID, "billing_group": row.BillingGroup}
		}
		return obj{"v": int64(1), "status": "not_found", "operation_id": operationID}
	}
	totals := j.usage()
	unresolved := []any{}
	byPurpose := obj{}
	for _, row := range j.operations() {
		if len(unresolved) == 16 {
			break
		}
		if row.State != "pending" && row.State != "uncertain" {
			continue
		}
		unresolved = append(unresolved, row.ID)
		purpose := row.Purpose
		if purpose == "" {
			purpose = "legacy"
		}
		list, _ := byPurpose[purpose].([]any)
		byPurpose[purpose] = append(list, row.ID)
	}
	configurationID, settings := j.configuration()
	status := "ready"
	if len(unresolved) > 0 {
		status = "reconciliation_required"
	}
	accountUsage := []any{}
	if accounts, ok := settings["accounts"]; ok {
		for _, account := range accounts.([]any) {
			accountUsage = append(accountUsage, j.accountUsage(account.(obj)["id"], getDefault(account.(obj), "billing_group", "")))
		}
	}
	return obj{"v": int64(1), "status": status, "configuration_id": configurationID, "settings": settings,
		"day": totals.day, "month": totals.month, "requests_today": normInt(totals.count),
		"charged_today_microusd": normInt(totals.daily), "charged_month_microusd": normInt(totals.monthly),
		"unresolved": unresolved, "unresolved_by_purpose": byPurpose, "account_usage": accountUsage,
		"purpose_usage": j.purposeUsage(totals.day, totals.month), "cost_basis": "conservative_journal_charge_not_provider_invoice"}
}

func (j *Journal) purposeUsage(day, month string) obj {
	groups := obj{}
	for _, row := range j.operations() {
		if row.Month != month {
			continue
		}
		purpose := row.Purpose
		if purpose == "" {
			purpose = "legacy"
		}
		group, ok := groups[purpose].(obj)
		if !ok {
			group = obj{"requests_today": int64(0), "charged_today_microusd": int64(0), "requests_month": int64(0), "charged_month_microusd": int64(0)}
			groups[purpose] = group
		}
		add := func(key string, n int64) { group[key] = normInt(new(big.Int).Add(bigOf(group[key]), bigInt(n))) }
		add("requests_month", 1)
		add("charged_month_microusd", row.Charged)
		if row.Day == day {
			add("requests_today", 1)
			add("charged_today_microusd", row.Charged)
			if row.Result != nil {
				var result struct {
					Usage map[string]json.RawMessage `json:"usage"`
				}
				if json.Unmarshal([]byte(*row.Result), &result) == nil {
					for _, key := range []string{"input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"} {
						var value int64
						if json.Unmarshal(result.Usage[key], &value) == nil && value >= 0 {
							name := key + "_today"
							if group[name] == nil {
								group[name] = int64(0)
							}
							add(name, value)
						}
					}
				}
			}
		}
	}
	return groups
}

// Abandon is an explicit operator acknowledgement; it never refunds or
// replays a call.
func (j *Journal) Abandon(operationID any) obj {
	validOperationID(operationID)
	j.transaction(func() { must(j.store.AbandonOperation(operationID.(string))) })
	return j.Status(operationID)
}

// Submit validates a draft request without invoking a backend. Runtime
// settings are loaded from this journal and cannot be replaced by
// request/transcript JSON.
func (j *Journal) Submit(ctx context.Context, raw any) obj {
	request, ok := raw.(obj)
	if !ok || !keysEqual(request, "v", "operation_id", "binding", "evidence") {
		fail("invalid_request")
	}
	validOperationID(request["operation_id"])
	binding, ok := request["binding"].(obj)
	if !isInt(request["v"]) || !pyEqual(request["v"], int64(1)) || !ok ||
		!keysEqual(binding, "session_id", "client", "turn_seq") || !fullmatch(sessionIDPattern, binding["session_id"]) ||
		!strIn(binding["client"], "claude", "codex") || !intIn(binding["turn_seq"], bigInt(0), nil) {
		fail("invalid_binding")
	}
	evidence, ok := request["evidence"].(string)
	if !ok || blank(evidence) || encodedLen(evidence) > maxSource {
		fail("invalid_evidence")
	}
	return j.submit(ctx, request, binding, evidence)
}

func (j *Journal) Assess(ctx context.Context, raw any) obj {
	request, ok := raw.(obj)
	if !ok || !keysEqual(request, "v", "operation_id", "host_id", "snapshot_id", "panes", "messages") ||
		!isInt(request["v"]) || !pyEqual(request["v"], int64(1)) {
		fail("invalid_health_request")
	}
	validOperationID(request["operation_id"])
	panes := validHealthPanes(request["host_id"], request["snapshot_id"], request["panes"])
	validateHealthMessages(request["messages"], request["host_id"], panes)
	binding := obj{"host_id": request["host_id"], "snapshot_id": request["snapshot_id"]}
	evidence := compact(obj{"panes": panes, "messages": request["messages"]})
	if encodedLen(evidence) > 131072 {
		fail("invalid_health_snapshot")
	}
	backend := obj{"v": int64(1), "operation_id": request["operation_id"], "purpose": "pane_health",
		"binding": binding, "evidence": evidence}
	return j.submit(ctx, backend, binding, evidence)
}

func (j *Journal) Assist(ctx context.Context, raw any) obj {
	request, ok := raw.(obj)
	if !ok || !keysEqual(request, "v", "operation_id", "request_id", "host_id", "context", "messages") ||
		!isInt(request["v"]) || !pyEqual(request["v"], int64(1)) {
		fail("invalid_assistant_request")
	}
	validOperationID(request["operation_id"])
	binding := validAssistantBinding(obj{"host_id": request["host_id"], "operation_id": request["operation_id"],
		"request_id": request["request_id"]})
	evidence := compact(obj{"context": request["context"], "messages": request["messages"]})
	if encodedLen(evidence) > 131072 {
		fail("invalid_assistant_context")
	}
	validAssistantEvidence(evidence)
	backend := obj{"v": int64(1), "operation_id": request["operation_id"], "purpose": "relay_assistant",
		"binding": binding, "evidence": evidence}
	return j.submit(ctx, backend, binding, evidence)
}

func (j *Journal) submit(ctx context.Context, request obj, binding obj, evidence string) obj {
	purpose, _ := getDefault(request, "purpose", "").(string)
	health := purpose == "pane_health"
	assistant := purpose == "relay_assistant"
	source := obj{"binding": binding, "evidence": evidence}
	if health || assistant {
		source["purpose"] = purpose
	}
	fingerprint := sha256Hex(compact(source))
	operationID := request["operation_id"].(string)
	var selected, config obj
	var reserved int64
	duplicate := false
	j.transaction(func() {
		_, settings := j.configuration()
		rows := j.operations()
		var found []Operation
		for _, row := range rows {
			if row.ID == operationID || row.Fingerprint == fingerprint {
				found = append(found, row)
			}
		}
		if len(found) > 0 {
			if len(found) != 1 || found[0].ID != operationID || found[0].Fingerprint != fingerprint {
				fail("operation_identity_conflict")
			}
			duplicate = true
			return
		}
		if !settings["enabled"].(bool) {
			fail("text_backend_disabled")
		}
		// An unknown outcome holds its own workflow, never another one. Rows
		// without a purpose (drafts, pre-migration rows) still hold every
		// workflow. Usage and reservations below stay shared by all purposes.
		for _, row := range rows {
			if (row.State == "pending" || row.State == "uncertain") && (row.Purpose == purpose || row.Purpose == "" || purpose == "") {
				fail("reconciliation_required")
			}
		}
		totals := j.usage()
		if assistant {
			requestID := binding["request_id"].(string)
			steps := 0
			requests := map[string]bool{}
			for _, row := range rows {
				if row.Purpose != "relay_assistant" {
					continue
				}
				if row.RequestID == requestID {
					steps++
				}
				if row.Day == totals.day {
					requests[row.RequestID] = true
				}
			}
			if steps >= assistantRequestStepLimit {
				fail("assistant_request_step_limit")
			}
			if bigOf(settings["max_requests_per_day"]).Sign() > 0 && steps == 0 && len(requests) >= assistantDailyRequestLimit {
				fail("assistant_daily_limit")
			}
			limit := bigOf(settings["max_requests_per_day"])
			if limit.Sign() > 0 && new(big.Int).Sub(limit, totals.count).Cmp(assistantHealthReserve(limit)) <= 0 {
				fail("assistant_health_reserve")
			}
		}
		if _, ok := settings["accounts"]; ok {
			selected, config = j.selectAccount(ctx, settings, health || assistant)
		} else {
			selected, config = obj{}, obj{}
			for _, key := range []string{"providers", "codex_model", "claude_path", "codex_path"} {
				if value, ok := settings[key]; ok {
					config[key] = value
				}
			}
		}
		if (health || assistant) && !pyEqual(config["providers"], []any{"anthropic_api"}) {
			fail("health_api_account_required")
		}
		if listContains(config["providers"].([]any), "anthropic_api") {
			reserved = apiReservationMicroUSD
		}
		if assistant && len(selected) > 0 {
			limit := bigOf(selected["max_requests_per_day"])
			used := bigOf(j.accountUsage(selected["id"], getDefault(selected, "billing_group", ""))["requests_today"])
			if limit.Sign() > 0 && new(big.Int).Sub(limit, used).Cmp(assistantHealthReserve(limit)) <= 0 {
				fail("assistant_health_reserve")
			}
		}
		withReserve := func(total *big.Int) *big.Int { return new(big.Int).Add(total, bigInt(reserved)) }
		if requestCapReached(totals.count, bigOf(settings["max_requests_per_day"])) ||
			withReserve(totals.daily).Cmp(bigOf(settings["daily_limit_microusd"])) > 0 ||
			withReserve(totals.monthly).Cmp(bigOf(settings["monthly_limit_microusd"])) > 0 {
			fail("spending_limit")
		}
		requestID := ""
		if assistant {
			requestID = binding["request_id"].(string)
		}
		accountID, group := textColumn(getDefault(selected, "id", "")), textColumn(getDefault(selected, "billing_group", ""))
		row := Operation{ID: operationID, Fingerprint: fingerprint, SettingsDigest: sha256Hex(compact(settings)),
			State: "pending", Day: totals.day, Month: totals.month, Reserved: reserved, Charged: reserved,
			AccountID: accountID, BillingGroup: group, Purpose: purpose, RequestID: requestID}
		storeText(row.ID, row.Fingerprint, row.Day, row.Month, row.AccountID, row.BillingGroup, row.Purpose, row.RequestID)
		must(j.store.InsertOperation(row)) // durable BEFORE any network/process call
	})
	if duplicate {
		return j.Status(operationID)
	}
	state, charged, encoded := j.outcome(ctx, request, config, selected, binding, evidence, reserved, health, assistant)
	j.transaction(func() {
		if !charged.IsInt64() {
			raise("OverflowError")
		}
		storeText(encoded)
		must(j.store.FinishOperation(operationID, state, charged.Int64(), encoded))
	})
	return j.Status(operationID)
}

// textColumn is the value sqlite stores in a TEXT NOT NULL column.
func textColumn(value any) string {
	if text, ok := value.(string); ok {
		return text
	}
	// Selected accounts always carry string identifiers; anything else would
	// fail sqlite3 binding or the NOT NULL constraint.
	raise("StoreError")
	return ""
}

// outcome runs the backend once and classifies its outcome. A killed process
// leaves the row pending; a caught failure is equally conservative and never
// permits an automatic resubmission.
func (j *Journal) outcome(ctx context.Context, request, config, selected, binding obj, evidence string, reserved int64,
	health, assistant bool) (state string, charged *big.Int, encoded string) {
	operationID := request["operation_id"].(string)
	defer func() {
		if value := recover(); value != nil {
			recoverPy(value)
			state, charged = "uncertain", bigInt(reserved)
			encoded = compact(obj{"v": int64(1), "operation_id": operationID, "status": "failed", "code": "request_outcome_unknown"})
		}
	}()
	call := obj{}
	for key, value := range request {
		call[key] = value
	}
	call["config"] = config
	raw := j.backend(ctx, call)
	result, ok := raw.(obj)
	if !ok || !pyEqual(result["operation_id"], operationID) {
		fail("invalid_backend_result")
	}
	status := result["status"]
	success := "draft"
	if health {
		success = "health_step"
	} else if assistant {
		success = "assistant_step"
	}
	if !strIn(status, success, "unavailable", "failed") {
		fail("invalid_backend_result")
	}
	if status == success || pyEqual(result["provider"], "anthropic_api") && truthy(result["usage"]) {
		if len(selected) > 0 && (!pyEqual(result["account_id"], selected["id"]) || !pyEqual(result["provider"], selected["provider"]) ||
			!pyEqual(getDefault(result, "billing_group", ""), getDefault(selected, "billing_group", ""))) {
			fail("invalid_account_binding")
		}
		if !pyEqual(result["binding"], binding) || !pyEqual(result["source_sha256"], sha256Hex(evidence)) {
			fail("invalid_backend_binding")
		}
		if pyEqual(result["provider"], "anthropic_api") && !pyEqual(result["model"], apiModel) {
			fail("api_model_mismatch")
		}
	}
	if status == success {
		switch {
		case assistant:
			if !pyEqual(result["purpose"], "relay_assistant") || !pyEqual(result["provider"], "anthropic_api") ||
				!pyEqual(result["model"], apiModel) || !((pyEqual(result["effort"], "medium") && pyEqual(result["thinking"], "adaptive")) || (pyEqual(result["effort"], "low") && pyEqual(result["thinking"], "disabled"))) {
				fail("invalid_assistant_backend")
			}
			calls := validateAssistantBlocks(result["assistant_content"], 16)
			if !pyEqual(result["tool_calls"], calls) || !strIn(result["stop_reason"], "end_turn", "tool_use", "max_tokens") {
				fail("invalid_assistant_response")
			}
		case health:
			if !pyEqual(result["purpose"], "pane_health") || !pyEqual(result["provider"], "anthropic_api") ||
				!pyEqual(result["model"], apiModel) || !pyEqual(result["effort"], "low") || !pyEqual(result["thinking"], "disabled") {
				fail("invalid_health_backend")
			}
			healthEvidence := parseJSON(evidence).(obj)
			latest := validateHealthMessages(healthEvidence["messages"], binding["host_id"], healthEvidence["panes"].([]any))
			calls := validateHealthCalls(result["assistant_content"], latest, true)
			if !pyEqual(result["tool_calls"], calls) {
				fail("invalid_health_tool_response")
			}
		default:
			validateDraft(result["draft"])
		}
	}
	state = "failed"
	if status == success {
		state = "complete"
	}
	charged = bigInt(reserved)
	switch {
	case status == "unavailable":
		charged = bigInt(0)
	case status == success && strIn(result["provider"], "claude_account", "codex_account"):
		charged = bigInt(0) // account usage is governed by the request-count limit
	case strIn(status, success, "failed") && pyEqual(result["provider"], "anthropic_api"):
		usage, ok := getDefault(result, "usage", obj{}).(obj)
		if !ok {
			raise("AttributeError")
		}
		if intIn(usage["input_tokens"], bigInt(0), nil) && intIn(usage["output_tokens"], bigInt(0), nil) {
			inputs := new(big.Int)
			for _, key := range []string{"input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"} {
				value := getDefault(usage, key, int64(0))
				if !isInt(value) && !isBool(value) {
					// Python would mix float arithmetic or raise TypeError;
					// the real backend only reports integer usage.
					raise("TypeError")
				}
				inputs.Add(inputs, bigOf(value))
			}
			// Conservative: charge every input token at the uncached rate.
			numerator := new(big.Int).Add(inputs, new(big.Int).Mul(bigInt(5), bigOf(usage["output_tokens"])))
			if inputs.Cmp(bigInt(100000)) <= 0 {
				charged = numerator.Add(numerator, bigInt(9)).Div(numerator, bigInt(10))
			} else {
				charged = numerator.Add(numerator, bigInt(1)).Div(numerator, bigInt(2))
			}
			if charged.Cmp(bigInt(reserved)) > 0 {
				state = "uncertain" // policy/pricing assumptions need review
			}
		}
	}
	if status == "failed" && strIn(result["code"], "request_outcome_unknown", "internal_error", "cli_request_failed") {
		state = "uncertain"
	}
	encoded = compact(result)
	if encodedLen(encoded) > 65536 {
		fail("backend_result_too_large")
	}
	return state, charged, encoded
}

// RunOperation is text_backend's main(): one operation against an opened
// journal, returning the compact JSON line it prints.
func RunOperation(ctx context.Context, open func() (*Journal, error), operation string, raw []byte) ([]byte, error) {
	switch operation {
	case "status", "configure", "submit", "assess", "assist", "abandon":
	default:
		return nil, errors.New("unsupported text service operation")
	}
	var result obj
	var journal *Journal
	func() {
		defer func() {
			if value := recover(); value != nil {
				draftErr, _ := recoverPy(value)
				if draftErr != nil {
					result = obj{"v": int64(1), "status": "failed", "code": draftErr.code}
				} else {
					result = obj{"v": int64(1), "status": "failed", "code": "journal_or_backend_unavailable"}
				}
			}
			if journal != nil {
				journal.Close()
			}
		}()
		if len(raw) > 262144 {
			fail("request_too_large")
		}
		request := parseJSON(raw)
		var err error
		journal, err = open()
		if err != nil {
			var refusal ledgerRefusal
			if errors.As(err, &refusal) {
				// The operator needs the files and the recovery choice.
				result = obj{"v": int64(1), "status": "failed", "code": refusal.Code(), "message": refusal.Error()}
				return
			}
			var coded interface{ Code() string }
			if errors.As(err, &coded) {
				fail(coded.Code())
			}
			raise("OSError")
		}
		switch operation {
		case "submit":
			result = journal.Submit(ctx, request)
		case "assess":
			result = journal.Assess(ctx, request)
		case "assist":
			result = journal.Assist(ctx, request)
		case "configure":
			fields, ok := request.(obj)
			if !ok || !hasKeys(fields, "operation_id", "settings") ||
				!keysWithin(fields, "operation_id", "settings", "expected_configuration_id") {
				fail("invalid_request")
			}
			if expected, ok := fields["expected_configuration_id"]; ok && !isStr(expected) {
				fail("invalid_request")
			}
			result = journal.Configure(fields["operation_id"], fields["settings"], fields["expected_configuration_id"])
		default:
			fields, ok := request.(obj)
			if !ok || !keysWithin(fields, "operation_id") {
				fail("invalid_request")
			}
			if operation == "abandon" {
				result = journal.Abandon(fields["operation_id"])
			} else {
				result = journal.Status(fields["operation_id"])
			}
		}
	}()
	line := compact(result)
	if hasSurrogate(line) {
		// print() would raise UnicodeEncodeError: the process emits nothing.
		return nil, errors.New("text service output is not encodable")
	}
	return []byte(line + "\n"), nil
}
