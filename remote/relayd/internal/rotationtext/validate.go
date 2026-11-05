package rotationtext

import (
	"crypto/sha256"
	"encoding/hex"
	"math/big"
	"regexp"
	"strings"
)

type obj = map[string]any

var (
	providers     = []string{"anthropic_api", "claude_account", "codex_account"}
	draftFields   = []string{"summary", "decisions", "constraints", "pending_work", "next_action", "uncertainties"}
	healthActions = []string{"observe", "repair_link", "apply_update", "reconnect", "attention"}
	healthStates  = []string{"healthy", "working", "held", "attention", "unknown"}

	draftSchema      = parseJSON(draftSchemaJSON)
	healthTools      = parseJSON(healthToolsJSON).([]any)
	assistantTools   = currentAssistantTools()
	healthToolNames  = toolNames(healthTools)
	assistantNames   = toolNames(assistantTools)
	assistantSchemas = schemasOf(assistantTools)
	assistantPrompt  = assistantSystemPrompt

	operationIDPattern = regexp.MustCompile(`^[a-f0-9]{32}$`)
	toolUseIDPattern   = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)
	sha256Pattern      = regexp.MustCompile(`^[a-f0-9]{64}$`)
	hostIDPattern      = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,128}$`)
	paneIDPattern      = regexp.MustCompile(`^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$`)
	sessionIDPattern   = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)
	modelPattern       = regexp.MustCompile(`^[a-zA-Z0-9_.-]{1,128}$`)
	billingPattern     = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,64}$`)

	maxSafeInteger = bigInt(1<<53 - 1)
	maxUint64      = new(big.Int).SetUint64(1<<64 - 1)
)

func toolNames(tools []any) []string {
	names := make([]string, len(tools))
	for i, tool := range tools {
		names[i] = tool.(obj)["name"].(string)
	}
	return names
}

func fullmatch(pattern *regexp.Regexp, value any) bool {
	s, ok := value.(string)
	return ok && pattern.MatchString(s)
}

func sha256Hex(s string) string {
	sum := sha256.Sum256(encodeUTF8(s))
	return hex.EncodeToString(sum[:])
}

func validOperationID(value any) {
	if !fullmatch(operationIDPattern, value) {
		fail("invalid_operation_id")
	}
}

func validateDraft(value any) any {
	draft, ok := value.(obj)
	if !ok || !keysEqual(draft, draftFields...) {
		fail("invalid_draft_fields")
	}
	for _, name := range draftFields {
		values, ok := draft[name].([]any)
		if name == "summary" || name == "next_action" {
			values, ok = []any{draft[name]}, true
		}
		if !ok || len(values) > 32 {
			fail("invalid_draft_shape")
		}
		for _, item := range values {
			text, ok := item.(string)
			if !ok || blank(text) || encodedLen(text) > 6400 {
				fail("invalid_draft_text")
			}
		}
	}
	if encodedLen(compact(draft)) > maxDraft {
		fail("draft_too_large")
	}
	return draft
}

func usageFields(value any) obj {
	usage, ok := value.(obj)
	if !ok {
		return obj{}
	}
	out := obj{}
	for _, key := range []string{"input_tokens", "output_tokens", "cache_read_input_tokens",
		"cache_creation_input_tokens", "cached_input_tokens"} {
		if intIn(usage[key], bigInt(0), nil) {
			out[key] = usage[key]
		}
	}
	return out
}

// retainAPIFailureUsage keeps billing metadata from a complete JSON response
// for the exact reviewed model: a rejected tool/report still consumed tokens.
func retainAPIFailureUsage(err *draftError, result any) {
	response, ok := result.(obj)
	if ok && pyEqual(response["model"], apiModel) {
		usage := usageFields(response["usage"])
		if hasKeys(usage, "input_tokens", "output_tokens") {
			err.apiUsage = usage
		}
	}
}

func apiFailureFields(err *draftError, config obj, binding any, evidence string, purpose string) obj {
	if err.apiUsage == nil {
		return obj{}
	}
	selected := selectedAccount(config)
	result := obj{"provider": "anthropic_api", "model": apiModel, "usage": err.apiUsage, "binding": binding,
		"source_sha256": sha256Hex(evidence), "account_id": getDefault(selected, "id", ""),
		"billing_group": getDefault(selected, "billing_group", "")}
	if purpose != "" {
		result["purpose"], result["effort"], result["thinking"] = purpose, "low", "disabled"
	}
	return result
}

// selectedAccount is config.get("selected_account", {}).
func selectedAccount(config obj) obj {
	selected, ok := config["selected_account"]
	if !ok {
		return obj{}
	}
	account, ok := selected.(obj)
	if !ok {
		raise("AttributeError")
	}
	return account
}

func getDefault(m obj, key string, fallback any) any {
	if value, ok := m[key]; ok {
		return value
	}
	return fallback
}

func validateHealthCalls(blocks any, panes []any, report bool) []any {
	list, ok := blocks.([]any)
	if !ok || len(list) == 0 || len(list) > 65 {
		fail("invalid_health_tool_response")
	}
	expected := map[string]bool{}
	for _, pane := range panes {
		expected[pane.(obj)["pane_id"].(string)] = true
	}
	calls := []any{}
	seen := map[string]bool{}
	for _, raw := range list {
		block, ok := raw.(obj)
		if !ok {
			fail("invalid_health_tool_response")
		}
		if pyEqual(block["type"], "text") {
			text, ok := block["text"].(string)
			if !ok || encodedLen(text) > 4096 {
				fail("invalid_health_tool_response")
			}
			continue
		}
		if !toolUseEnvelope(block, seen) || !strIn(block["name"], healthToolNames...) {
			fail("invalid_health_tool_response")
		}
		id := block["id"].(string)
		seen[id] = true
		name, args := block["name"].(string), block["input"]
		if name == "report_health" {
			if report {
				validateHealthAssessment(args, panes)
			}
		} else {
			required := []string{"pane_id", "evidence_id"}
			if name == "inspect_pane" || name == "verify_pane" {
				required = []string{"pane_id"}
			}
			input, ok := args.(obj)
			if !ok || !keysEqual(input, required...) || !isStr(input["pane_id"]) || !expected[input["pane_id"].(string)] ||
				len(required) == 2 && !fullmatch(sha256Pattern, input["evidence_id"]) {
				fail("invalid_health_tool_arguments")
			}
		}
		// The current Messages API may identify a direct tool caller. Relay's
		// native tool envelope has the four canonical fields; server-side
		// callers are never admitted to this native authority boundary.
		calls = append(calls, obj{"type": block["type"], "id": block["id"], "name": block["name"], "input": block["input"]})
	}
	if len(calls) == 0 {
		fail("invalid_health_tool_response")
	}
	for _, call := range calls {
		if call.(obj)["name"] == "report_health" && len(calls) != 1 {
			fail("invalid_health_tool_response")
		}
	}
	return calls
}

// toolUseEnvelope checks the shared tool_use block shape: exactly the four
// canonical fields plus an optional direct caller, and a fresh valid id.
func toolUseEnvelope(block obj, seen map[string]bool) bool {
	if !pyEqual(block["type"], "tool_use") || !hasKeys(block, "type", "id", "name", "input") ||
		!keysWithin(block, "type", "id", "name", "input", "caller") {
		return false
	}
	if caller, ok := block["caller"]; ok && !pyEqual(caller, obj{"type": "direct"}) {
		return false
	}
	id, ok := block["id"].(string)
	return ok && toolUseIDPattern.MatchString(id) && !seen[id] && isStr(block["name"])
}

func validateHealthMessages(raw any, hostID any, panes []any) []any {
	messages, ok := raw.([]any)
	if !ok || len(messages) > 24 || len(messages)%2 != 0 {
		fail("invalid_health_messages")
	}
	order := []string{}
	latest := map[string]any{}
	for _, pane := range panes {
		id := pane.(obj)["pane_id"].(string)
		if _, ok := latest[id]; !ok {
			order = append(order, id)
		}
		latest[id] = pane
	}
	values := func() []any {
		out := make([]any, len(order))
		for i, id := range order {
			out[i] = latest[id]
		}
		return out
	}
	for index := 0; index < len(messages); index += 2 {
		assistant, ok1 := messages[index].(obj)
		user, ok2 := messages[index+1].(obj)
		if !ok1 || !keysEqual(assistant, "role", "content") || !pyEqual(assistant["role"], "assistant") ||
			!ok2 || !keysEqual(user, "role", "content") || !pyEqual(user["role"], "user") {
			fail("invalid_health_messages")
		}
		calls := validateHealthCalls(assistant["content"], values(), true)
		for _, call := range calls {
			if call.(obj)["name"] == "report_health" {
				fail("health_conversation_already_finished")
			}
		}
		expected := map[string]obj{}
		for _, call := range calls {
			expected[call.(obj)["id"].(string)] = call.(obj)
		}
		seen := map[string]bool{}
		content, ok := user["content"].([]any)
		if !ok || len(content) != len(calls) {
			fail("invalid_health_tool_results")
		}
		for _, rawItem := range content {
			item, ok := rawItem.(obj)
			if !ok || !keysWithin(item, "type", "tool_use_id", "content", "is_error") || !pyEqual(item["type"], "tool_result") {
				fail("invalid_health_tool_results")
			}
			id, ok := item["tool_use_id"].(string)
			if !ok || expected[id] == nil || seen[id] {
				fail("invalid_health_tool_results")
			}
			text, ok := item["content"].(string)
			if !ok || encodedLen(text) > 16384 {
				fail("invalid_health_tool_results")
			}
			if isError, ok := item["is_error"]; ok {
				if _, isBool := isError.(bool); !isBool {
					fail("invalid_health_tool_results")
				}
			}
			seen[id] = true
			result := parseJSON(text)
			if resultMap, ok := result.(obj); ok {
				if pane, ok := resultMap["pane"].(obj); ok {
					call := expected[id]
					if !pyEqual(pane["pane_id"], call["input"].(obj)["pane_id"]) {
						fail("health_tool_identity_mismatch")
					}
					digest := sha256Hex(compact(obj{"host_id": hostID, "panes": []any{pane}}))
					validHealthPanes(hostID, digest, []any{pane})
					latest[pane["pane_id"].(string)] = pane
				}
			}
		}
	}
	return values()
}

func validHealthPanes(hostID, snapshotID any, raw any) []any {
	panes, ok := raw.([]any)
	if !fullmatch(hostIDPattern, hostID) || !fullmatch(sha256Pattern, snapshotID) || !ok || len(panes) < 1 || len(panes) > 64 {
		fail("invalid_health_snapshot")
	}
	ids := map[string]bool{}
	for _, rawPane := range panes {
		pane, ok := rawPane.(obj)
		required := []string{"pane_id", "evidence_id", "kind", "connection", "binding", "activity",
			"identity_verified", "prompt_empty", "has_draft", "pending_approvals",
			"input_idle", "installed_update", "allowed_actions"}
		if !ok || !hasKeys(pane, required...) ||
			!keysWithin(pane, append(required, "session_id", "process_id", "process_start", "observed_at")...) {
			fail("invalid_health_pane")
		}
		pid, isString := pane["pane_id"].(string)
		if !isString || !paneIDPattern.MatchString(pid) || ids[pid] ||
			!strIn(pane["kind"], "claude", "codex", "shell", "other") ||
			!strIn(pane["connection"], "connected", "connecting", "reconnecting", "waiting_for_network", "disconnected", "unknown") ||
			!strIn(pane["binding"], "bound", "unbound", "unknown", "not_applicable") ||
			!strIn(pane["activity"], "quiet", "working", "unknown") ||
			!isBool(pane["identity_verified"]) || !isBool(pane["installed_update"]) ||
			!optionalBool(pane["prompt_empty"]) || !optionalBool(pane["has_draft"]) || !optionalBool(pane["input_idle"]) ||
			pane["pending_approvals"] != nil && !intIn(pane["pending_approvals"], bigInt(0), bigInt(10000)) {
			fail("invalid_health_pane")
		}
		if observed, ok := pane["observed_at"]; ok && !intIn(observed, bigInt(1), maxSafeInteger) {
			fail("invalid_health_pane")
		}
		ids[pid] = true
		for _, key := range []string{"process_id", "process_start"} {
			if value, ok := pane[key]; ok && !intIn(value, bigInt(2), maxUint64) {
				fail("invalid_health_identity")
			}
		}
		if session, ok := pane["session_id"]; ok && !fullmatch(sessionIDPattern, session) {
			fail("invalid_health_identity")
		}
		verified := pane["identity_verified"].(bool)
		shell := pane["binding"] == "not_applicable"
		_, hasSession := pane["session_id"]
		if shell && (pane["kind"] != "shell" || !verified || hasSession || pane["installed_update"].(bool)) {
			fail("invalid_health_identity")
		}
		identity := []string{"session_id", "process_id", "process_start"}
		if shell {
			identity = identity[1:]
		}
		if verified && !hasKeys(pane, identity...) {
			fail("invalid_health_identity")
		}
		actions, ok := pane["allowed_actions"].([]any)
		if !ok || len(actions) == 0 {
			fail("invalid_health_actions")
		}
		unique := map[string]bool{}
		for _, action := range actions {
			if !strIn(action, healthActions...) {
				fail("invalid_health_actions")
			}
			unique[action.(string)] = true
		}
		if len(unique) != len(actions) || !unique["observe"] {
			fail("invalid_health_actions")
		}
		safeAgent := pane["connection"] == "connected" && verified && strIn(pane["kind"], "claude", "codex") &&
			pane["activity"] == "quiet" && pane["prompt_empty"] == true && pane["has_draft"] == false &&
			isInt(pane["pending_approvals"]) && bigOf(pane["pending_approvals"]).Sign() == 0 && pane["input_idle"] == true
		if unique["repair_link"] && !(safeAgent && pane["binding"] == "unbound") ||
			unique["apply_update"] && !(safeAgent && pane["installed_update"].(bool)) ||
			unique["reconnect"] && pane["connection"] != "disconnected" {
			fail("inadmissible_health_actions")
		}
		evidence := obj{}
		for key, value := range pane {
			if key != "evidence_id" {
				evidence[key] = value
			}
		}
		if !pyEqual(pane["evidence_id"], sha256Hex(compact(evidence))) {
			fail("health_evidence_mismatch")
		}
	}
	if !pyEqual(snapshotID, sha256Hex(compact(obj{"host_id": hostID, "panes": panes}))) {
		fail("health_snapshot_mismatch")
	}
	return panes
}

func isBool(value any) bool { _, ok := value.(bool); return ok }

func optionalBool(value any) bool { return value == nil || isBool(value) }

func validateHealthAssessment(value any, panes []any) any {
	assessment, ok := value.(obj)
	if !ok || !keysEqual(assessment, "panes") {
		fail("invalid_health_assessment")
	}
	items, ok := assessment["panes"].([]any)
	if !ok {
		fail("invalid_health_assessment")
	}
	expected := map[string]obj{}
	for _, pane := range panes {
		expected[pane.(obj)["pane_id"].(string)] = pane.(obj)
	}
	seen := map[string]bool{}
	if len(items) != len(expected) {
		fail("incomplete_health_assessment")
	}
	for _, raw := range items {
		item, ok := raw.(obj)
		if !ok || !keysEqual(item, "pane_id", "evidence_id", "health", "action", "reason") {
			fail("invalid_health_assessment")
		}
		pid, isString := item["pane_id"].(string)
		var pane obj
		if isString {
			pane = expected[pid]
		}
		if pane == nil || seen[pid] || !pyEqual(item["evidence_id"], pane["evidence_id"]) ||
			!strIn(item["health"], healthStates...) || !listContains(pane["allowed_actions"].([]any), item["action"]) ||
			!validReason(item["reason"]) {
			fail("inadmissible_health_assessment")
		}
		if strIn(item["health"], "healthy", "working") {
			agent := strIn(pane["kind"], "claude", "codex") && pane["binding"] == "bound"
			shell := pane["kind"] == "shell" && pane["binding"] == "not_applicable"
			if pane["connection"] != "connected" || pane["identity_verified"] != true || !(agent || shell) ||
				item["health"] == "working" && !(agent && pane["activity"] == "working") {
				fail("unsupported_health_success")
			}
		}
		seen[pid] = true
	}
	return assessment
}

func validReason(value any) bool {
	reason, ok := value.(string)
	if !ok || blank(reason) || encodedLen(reason) > 240 {
		return false
	}
	for i := 0; i < len(reason); i++ {
		if reason[i] < 32 {
			return false
		}
	}
	return true
}

func schemasOf(tools []any) map[string]obj {
	schemas := map[string]obj{}
	for _, tool := range tools {
		schemas[tool.(obj)["name"].(string)] = tool.(obj)["input_schema"].(obj)
	}
	return schemas
}

func validateAssistantInput(name string, raw any) {
	schema := assistantSchemas[name]
	args, ok := raw.(obj)
	if schema == nil || !ok || encodedLen(compact(args)) > 66000 {
		fail("invalid_assistant_tool_arguments")
	}
	properties := schema["properties"].(obj)
	if !hasKeys(args, stringsOf(schema["required"])...) || !keysWithin(args, keysOf(properties)...) {
		fail("invalid_assistant_tool_arguments")
	}
	validateFields(args, properties)
}

func stringsOf(value any) []string {
	items := value.([]any)
	out := make([]string, len(items))
	for i, item := range items {
		out[i] = item.(string)
	}
	return out
}

func keysOf(m obj) []string {
	out := make([]string, 0, len(m))
	for key := range m {
		out = append(out, key)
	}
	return out
}

// validateFields is _validate_fields: a generic check against the tool's own
// fixed input_schema. Identifiers are admitted by Relay against its live
// snapshot; an unknown one returns an error result to the model and never acts.
func validateFields(args obj, properties obj) {
	for key, value := range args {
		rule := properties[key].(obj)
		switch rule["type"] {
		case "string":
			text, ok := value.(string)
			if !ok || pyLen(text) > int(bigOf(getDefault(rule, "maxLength", int64(8192))).Int64()) {
				fail("invalid_assistant_tool_arguments")
			}
			if enum, ok := rule["enum"]; ok && !listContains(enum.([]any), value) {
				fail("invalid_assistant_tool_arguments")
			}
		case "boolean":
			if !isBool(value) {
				fail("invalid_assistant_tool_arguments")
			}
		case "integer":
			if !intIn(value, bigOf(getDefault(rule, "minimum", int64(-(1<<53)))), bigOf(getDefault(rule, "maximum", int64(1<<53)))) {
				fail("invalid_assistant_tool_arguments")
			}
		case "array":
			items := rule["items"].(obj)
			list, ok := value.([]any)
			if !ok || len(list) < 1 || int64(len(list)) > bigOf(getDefault(rule, "maxItems", int64(8))).Int64() {
				fail("invalid_assistant_tool_arguments")
			}
			itemProperties := items["properties"].(obj)
			for _, rawItem := range list {
				item, ok := rawItem.(obj)
				if !ok || !hasKeys(item, stringsOf(items["required"])...) || !keysWithin(item, keysOf(itemProperties)...) {
					fail("invalid_assistant_tool_arguments")
				}
				validateFields(item, itemProperties)
			}
		default:
			fail("invalid_assistant_tool_arguments")
		}
	}
}

func validateAssistantBlocks(raw any, limit int) []any {
	blocks, ok := raw.([]any)
	if !ok || len(blocks) == 0 || len(blocks) > limit {
		fail("invalid_assistant_response")
	}
	calls := []any{}
	seen := map[string]bool{}
	for _, rawBlock := range blocks {
		block, ok := rawBlock.(obj)
		if !ok {
			fail("invalid_assistant_response")
		}
		// Haiku returns opaque signed thinking when display is omitted.
		// Preserve it unchanged for tool continuations; never accept readable
		// reasoning or treat it as a tool proposal.
		if pyEqual(block["type"], "thinking") {
			text, textOK := block["thinking"].(string)
			signature, signatureOK := block["signature"].(string)
			if !keysEqual(block, "type", "thinking", "signature") || !textOK || text != "" ||
				!signatureOK || blank(signature) || encodedLen(signature) > 65536 {
				fail("invalid_assistant_response")
			}
			continue
		}
		if pyEqual(block["type"], "redacted_thinking") {
			data, ok := block["data"].(string)
			if !keysEqual(block, "type", "data") || !ok || blank(data) || encodedLen(data) > 65536 {
				fail("invalid_assistant_response")
			}
			continue
		}
		if pyEqual(block["type"], "text") {
			text, ok := block["text"].(string)
			if !keysWithin(block, "type", "text", "citations") || !ok || encodedLen(text) > 8192 {
				fail("invalid_assistant_response")
			}
			continue
		}
		if !toolUseEnvelope(block, seen) || !strIn(block["name"], assistantNames...) {
			fail("invalid_assistant_response")
		}
		validateAssistantInput(block["name"].(string), block["input"])
		seen[block["id"].(string)] = true
		calls = append(calls, obj{"type": block["type"], "id": block["id"], "name": block["name"], "input": block["input"]})
	}
	return calls
}

// validateAssistantMessages checks alternating user/assistant turns ending
// with the user; every tool_use is answered exactly once by the next user
// turn. It returns the number of tool calls used.
func validateAssistantMessages(raw any) int {
	messages, ok := raw.([]any)
	if !ok || len(messages) < 1 || len(messages) > 48 || len(messages)%2 != 1 {
		fail("invalid_assistant_messages")
	}
	used := 0
	var pending map[string]bool
	for index, rawMessage := range messages {
		role := "user"
		if index%2 == 1 {
			role = "assistant"
		}
		message, ok := rawMessage.(obj)
		if !ok || !keysEqual(message, "role", "content") || !pyEqual(message["role"], role) {
			fail("invalid_assistant_messages")
		}
		content := message["content"]
		if role == "assistant" {
			if text, ok := content.(string); ok {
				if blank(text) || encodedLen(text) > 8192 {
					fail("invalid_assistant_messages")
				}
				pending = nil
				continue
			}
			calls := validateAssistantBlocks(content, 16)
			used += len(calls)
			pending = nil
			for _, call := range calls {
				if pending == nil {
					pending = map[string]bool{}
				}
				pending[call.(obj)["id"].(string)] = true
			}
			continue
		}
		if text, ok := content.(string); ok {
			if pending != nil || blank(text) || encodedLen(text) > 8192 {
				fail("invalid_assistant_messages")
			}
			continue
		}
		items, ok := content.([]any)
		if pending == nil || !ok || len(items) != len(pending) {
			fail("invalid_assistant_tool_results")
		}
		seen := map[string]bool{}
		for _, rawItem := range items {
			item, ok := rawItem.(obj)
			if !ok || !keysWithin(item, "type", "tool_use_id", "content", "is_error") || !pyEqual(item["type"], "tool_result") {
				fail("invalid_assistant_tool_results")
			}
			requireHashable(item["tool_use_id"])
			id, isString := item["tool_use_id"].(string)
			if !isString || !pending[id] || seen[id] {
				fail("invalid_assistant_tool_results")
			}
			text, ok := item["content"].(string)
			if !ok || encodedLen(text) > 8192 {
				fail("invalid_assistant_tool_results")
			}
			if isError, ok := item["is_error"]; ok && !isBool(isError) {
				fail("invalid_assistant_tool_results")
			}
			seen[id] = true
		}
		pending = nil
	}
	if used > assistantMaxToolCalls {
		fail("assistant_tool_limit")
	}
	return used
}

func validAssistantBinding(raw any) obj {
	binding, ok := raw.(obj)
	if !ok || !keysEqual(binding, "host_id", "operation_id", "request_id") || !fullmatch(hostIDPattern, binding["host_id"]) {
		fail("invalid_assistant_binding")
	}
	validOperationID(binding["operation_id"])
	validOperationID(binding["request_id"])
	return binding
}

func validAssistantEvidence(evidence any) (obj, int) {
	var value any
	if text, ok := evidence.(string); ok {
		value = parseJSON(text)
	}
	parsed, ok := value.(obj)
	if !ok || !keysEqual(parsed, "context", "messages") {
		fail("invalid_assistant_context")
	}
	context, ok := parsed["context"].(string)
	if !ok || blank(context) || encodedLen(context) > assistantContextLimit {
		fail("invalid_assistant_context")
	}
	return parsed, validateAssistantMessages(parsed["messages"])
}

// Validated API-only settings and API accounts allow zero to disable the daily
// request cap. Monetary limits and independent rate limits still apply.
func requestCapReached(used, limit *big.Int) bool {
	return limit.Sign() > 0 && used.Cmp(limit) >= 0
}

// assistantHealthReserve is the daily request headroom the assistant may never
// consume, so pane-health assessments keep capacity: max(10, ceil(20%)).
func assistantHealthReserve(limit *big.Int) *big.Int {
	reserve := new(big.Int).Mul(limit, bigInt(20))
	reserve.Neg(reserve)
	reserve.Div(reserve, bigInt(100)) // floor division, as Python's //
	reserve.Neg(reserve)
	if reserve.Cmp(bigInt(10)) < 0 {
		return bigInt(10)
	}
	return reserve
}

func validProviders(value any) bool {
	list, ok := value.([]any)
	if !ok || len(list) == 0 || len(list) > 3 {
		return false
	}
	seen := map[string]bool{}
	for _, provider := range list {
		if !strIn(provider, providers...) {
			return false
		}
		seen[provider.(string)] = true
	}
	return len(seen) == len(list)
}

func validatedSettings(raw any) obj {
	settings, ok := raw.(obj)
	if !ok || !keysWithin(settings, "enabled", "providers", "daily_limit_microusd", "monthly_limit_microusd",
		"max_requests_per_day", "codex_model", "claude_path", "codex_path", "accounts") {
		fail("invalid_settings")
	}
	if !hasKeys(settings, "enabled", "providers", "daily_limit_microusd", "monthly_limit_microusd", "max_requests_per_day") ||
		!isBool(settings["enabled"]) {
		fail("invalid_settings")
	}
	if !validProviders(settings["providers"]) {
		fail("invalid_settings")
	}
	for _, limit := range []struct {
		key     string
		ceiling int64
	}{{"daily_limit_microusd", 200_000_000}, {"monthly_limit_microusd", 200_000_000}, {"max_requests_per_day", 10000}} {
		if !intIn(settings[limit.key], bigInt(0), bigInt(limit.ceiling)) {
			fail("invalid_settings")
		}
	}
	enabled := settings["enabled"].(bool)
	providerList := settings["providers"].([]any)
	if enabled && (bigOf(settings["max_requests_per_day"]).Sign() == 0 && !pyEqual(providerList, []any{"anthropic_api"}) ||
		listContains(providerList, "anthropic_api") && minBig(settings["daily_limit_microusd"], settings["monthly_limit_microusd"]).Cmp(bigInt(apiReservationMicroUSD)) < 0) {
		fail("positive_limits_required")
	}
	for _, key := range []string{"claude_path", "codex_path"} {
		if value, ok := settings[key]; ok {
			path, isString := value.(string)
			if !isString || !strings.HasPrefix(path, "/") || pyLen(path) > 4096 {
				fail("invalid_cli_path")
			}
		}
	}
	if value, ok := settings["codex_model"]; ok && !fullmatch(modelPattern, value) {
		fail("invalid_model")
	}
	if raw, ok := settings["accounts"]; ok {
		accounts, isList := raw.([]any)
		if !isList || len(accounts) > 12 {
			fail("invalid_accounts")
		}
		validated := make([]obj, len(accounts))
		for i, account := range accounts {
			validated[i] = validatedAccount(account)
		}
		ids, references, logins := map[string]bool{}, map[string]bool{}, map[string]bool{}
		referenceCount, loginCount := 0, 0
		for _, account := range validated {
			ids[account["id"].(string)] = true
			if reference, ok := account["credential_ref"]; ok {
				references[reference.(string)] = true
				referenceCount++
			}
			if directory, ok := account["auth_directory"]; ok {
				logins[account["provider"].(string)+"\x00"+directory.(string)] = true
				loginCount++
			}
		}
		if len(ids) != len(validated) {
			fail("invalid_accounts")
		}
		if len(references) != referenceCount || len(logins) != loginCount {
			fail("duplicate_account_credential")
		}
		if enabled {
			ready := false
			for _, account := range validated {
				if account["enabled"].(bool) && listContains(providerList, account["provider"]) {
					ready = true
				}
			}
			if !ready {
				fail("account_required")
			}
		}
	}
	out := obj{}
	for key, value := range settings {
		out[key] = value
	}
	return out
}

func minBig(a, b any) *big.Int {
	x, y := bigOf(a), bigOf(b)
	if x.Cmp(y) <= 0 {
		return x
	}
	return y
}

func validatedAccount(raw any) obj {
	value, ok := raw.(obj)
	required := []string{"id", "name", "provider", "enabled", "daily_limit_microusd", "monthly_limit_microusd", "max_requests_per_day"}
	if !ok || !keysWithin(value, append(required, "credential_ref", "auth_directory", "billing_group", "model", "cli_path")...) ||
		!hasKeys(value, required...) {
		fail("invalid_account")
	}
	validOperationID(value["id"])
	name, isString := value["name"].(string)
	if !isString || pyLen(name) < 1 || pyLen(name) > 64 || name != pyStrip(name) || hasControl(name) || containsSKToken(name) {
		fail("invalid_account_name")
	}
	provider := value["provider"]
	if !strIn(provider, providers...) || !isBool(value["enabled"]) {
		fail("invalid_account")
	}
	for _, limit := range []struct {
		key     string
		ceiling int64
	}{{"daily_limit_microusd", 200_000_000}, {"monthly_limit_microusd", 200_000_000}, {"max_requests_per_day", 10000}} {
		if !intIn(value[limit.key], bigInt(0), bigInt(limit.ceiling)) {
			fail("invalid_account")
		}
	}
	enabled := value["enabled"].(bool)
	if enabled && provider != "anthropic_api" && bigOf(value["max_requests_per_day"]).Sign() < 1 {
		fail("positive_limits_required")
	}
	_, hasReference := value["credential_ref"]
	if provider == "anthropic_api" {
		if hasAny(value, "auth_directory", "model", "cli_path") {
			fail("invalid_account")
		}
		if hasReference {
			validOperationID(value["credential_ref"])
		}
		group := getDefault(value, "billing_group", "")
		if truthy(group) && !fullmatch(billingPattern, group) {
			fail("invalid_billing_group")
		}
		if enabled && (!truthy(group) || !hasReference ||
			minBig(value["daily_limit_microusd"], value["monthly_limit_microusd"]).Cmp(bigInt(apiReservationMicroUSD)) < 0) {
			fail("api_account_configuration_required")
		}
	} else {
		if hasAny(value, "credential_ref", "billing_group") {
			fail("invalid_account")
		}
		for _, key := range []string{"auth_directory", "cli_path"} {
			if raw, ok := value[key]; ok {
				path, isString := raw.(string)
				if !isString || !strings.HasPrefix(path, "/") || pyLen(path) > 4096 || strings.Contains(path, "\x00") {
					fail("invalid_cli_path")
				}
			}
		}
		if model, ok := value["model"]; ok && !fullmatch(modelPattern, model) {
			fail("invalid_model")
		}
		if enabled && !hasKeys(value, "auth_directory", "model") {
			fail("saved_account_configuration_required")
		}
	}
	out := obj{}
	for key, item := range value {
		out[key] = item
	}
	return out
}

func hasAny(m obj, keys ...string) bool {
	for _, key := range keys {
		if _, ok := m[key]; ok {
			return true
		}
	}
	return false
}

// hasControl is any(ord(c) < 32 or ord(c) == 127 for c in s).
func hasControl(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < 32 || s[i] == 127 {
			return true
		}
	}
	return false
}
