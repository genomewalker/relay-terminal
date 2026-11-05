package main

import (
	"bytes"
	"encoding/json"
	"regexp"
)

// relay_research_capability is the P1 preflight for coordinated research turns
// (chitta-research handoff 394c93be). It is read-only and local: it makes no
// model, daemon, Relay or network call. Relay cannot yet run an enforced native
// worker turn (P2), so every well-formed request is refused with reasons and
// scope_enforcement is always false. A positive answer may only appear once P2
// enforcement exists and is tested; until then this tool can never report
// readiness.

const researchCapabilityVersion = "relay_research_capability/1"

var (
	researchSHA256   = regexp.MustCompile(`^[0-9a-f]{64}$`)
	researchLabel    = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:@\[\]/-]{0,127}$`)
	researchHost     = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$`)
	researchToolName = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,128}$`)
	researchEfforts  = map[string]bool{"low": true, "medium": true, "high": true, "xhigh": true, "max": true}
)

var researchUnsupportedReasons = []string{
	"enforced_native_worker_turn_unavailable: Relay cannot yet run a bounded worker turn with a launch-fixed tool policy (P2)",
	"scope_enforcement_unavailable: tool restriction would be prompt-only, which is not enforcement",
	"lifecycle_receipt_unavailable: no research-turn job with terminal completed/failed/cancelled/timeout receipt (P3)",
	"usage_accounting_unavailable: usage and cost cannot be bound to a research turn",
}

type researchTarget struct {
	Host      string `json:"host"`
	PaneID    string `json:"pane_id"`
	SessionID string `json:"session_id"`
	Cwd       string `json:"cwd"`
}

type researchToolsPolicy struct {
	Allow []string `json:"allow"`
	Deny  []string `json:"deny"`
}

type researchBudget struct {
	Passes      *int     `json:"passes"`
	Retries     *int     `json:"retries"`
	WallSeconds *int     `json:"wall_seconds"`
	USD         *float64 `json:"usd"`
}

// strictResearchObject decodes one JSON object, refusing nulls, unknown keys
// and wrong types.
func strictResearchObject(raw json.RawMessage, dst any) bool {
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || fields == nil {
		return false
	}
	for _, value := range fields {
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return false
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	return decoder.Decode(dst) == nil
}

func validResearchToolList(names []string) bool {
	if len(names) > 32 {
		return false
	}
	for _, name := range names {
		if !researchToolName.MatchString(name) {
			return false
		}
	}
	return true
}

func validResearchCapabilityArgs(arguments map[string]json.RawMessage) (string, string, bool) {
	known := map[string]bool{"request_id": true, "target": true, "provider": true, "model": true, "account": true, "effort": true, "contract_sha256": true, "tools_policy": true, "budget": true}
	for key, value := range arguments {
		if !known[key] || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return "", "", false
		}
	}
	var requestID, provider, contract string
	if json.Unmarshal(arguments["request_id"], &requestID) != nil || !paneID.MatchString(requestID) ||
		json.Unmarshal(arguments["provider"], &provider) != nil || (provider != "claude" && provider != "codex") ||
		json.Unmarshal(arguments["contract_sha256"], &contract) != nil || !researchSHA256.MatchString(contract) {
		return "", "", false
	}
	var target researchTarget
	if raw, ok := arguments["target"]; !ok || !strictResearchObject(raw, &target) || !paneID.MatchString(target.PaneID) ||
		(target.Host != "" && !researchHost.MatchString(target.Host)) ||
		(target.SessionID != "" && !researchLabel.MatchString(target.SessionID)) ||
		(target.Cwd != "" && (target.Cwd[0] != '/' || len(target.Cwd) > 1024)) {
		return "", "", false
	}
	for _, key := range []string{"model", "account"} {
		if raw, ok := arguments[key]; ok {
			var value string
			if json.Unmarshal(raw, &value) != nil || !researchLabel.MatchString(value) {
				return "", "", false
			}
		}
	}
	if raw, ok := arguments["effort"]; ok {
		var effort string
		if json.Unmarshal(raw, &effort) != nil || !researchEfforts[effort] {
			return "", "", false
		}
	}
	if raw, ok := arguments["tools_policy"]; ok {
		var policy researchToolsPolicy
		if !strictResearchObject(raw, &policy) || !validResearchToolList(policy.Allow) || !validResearchToolList(policy.Deny) {
			return "", "", false
		}
	}
	if raw, ok := arguments["budget"]; ok {
		var budget researchBudget
		if !strictResearchObject(raw, &budget) ||
			(budget.Passes != nil && (*budget.Passes < 1 || *budget.Passes > 10)) ||
			(budget.Retries != nil && (*budget.Retries < 0 || *budget.Retries > 5)) ||
			(budget.WallSeconds != nil && (*budget.WallSeconds < 1 || *budget.WallSeconds > 3600)) ||
			(budget.USD != nil && (*budget.USD < 0 || *budget.USD > 100)) {
			return "", "", false
		}
	}
	return requestID, contract, true
}

func researchCapabilityTool() map[string]any {
	label := map[string]any{"type": "string", "pattern": researchLabel.String()}
	names := map[string]any{"type": "array", "maxItems": 32, "items": map[string]any{"type": "string", "pattern": researchToolName.String()}}
	return tool("relay_research_capability",
		"Preflight a coordinated research turn. Read-only and local: no model, daemon or network call, no side effects. Relay does not yet run enforced native worker turns, so every valid request returns supported:false, execution_ready:false and scope_enforcement:false with unsupported_reasons. A refusal is the truthful answer, not an error; do not fall back to prompt-only restriction in a general pane.",
		map[string]any{
			"request_id": map[string]any{"type": "string", "description": "New UUID for this preflight; echoed back"},
			"target": map[string]any{"type": "object", "additionalProperties": false, "required": []string{"pane_id"}, "properties": map[string]any{
				"pane_id":    map[string]any{"type": "string", "description": "Pane UUID"},
				"host":       map[string]any{"type": "string", "pattern": researchHost.String()},
				"session_id": label,
				"cwd":        map[string]any{"type": "string", "maxLength": 1024, "description": "Absolute path on the target host"},
			}},
			"provider":        map[string]any{"type": "string", "enum": []string{"claude", "codex"}},
			"model":           label,
			"account":         label,
			"effort":          map[string]any{"type": "string", "enum": []string{"low", "medium", "high", "xhigh", "max"}},
			"contract_sha256": map[string]any{"type": "string", "pattern": researchSHA256.String()},
			"tools_policy": map[string]any{"type": "object", "additionalProperties": false, "properties": map[string]any{
				"allow": names, "deny": names,
			}},
			"budget": map[string]any{"type": "object", "additionalProperties": false, "properties": map[string]any{
				"passes":       map[string]any{"type": "integer", "minimum": 1, "maximum": 10},
				"retries":      map[string]any{"type": "integer", "minimum": 0, "maximum": 5},
				"wall_seconds": map[string]any{"type": "integer", "minimum": 1, "maximum": 3600},
				"usd":          map[string]any{"type": "number", "minimum": 0, "maximum": 100},
			}},
		}, []string{"request_id", "target", "provider", "contract_sha256"})
}

// researchCapability answers locally; it must never reach s.endpoint or
// s.daemonHelper.
func researchCapability(arguments map[string]json.RawMessage) (any, int, string) {
	requestID, contract, ok := validResearchCapabilityArgs(arguments)
	if !ok {
		return nil, -32602, "Invalid research capability request: request_id UUID, target.pane_id UUID, provider claude|codex and contract_sha256 (64 lowercase hex) are required; optional fields must match the schema"
	}
	answer, _ := json.Marshal(map[string]any{
		"request_id":          requestID,
		"contract_sha256":     contract,
		"supported":           false,
		"execution_ready":     false,
		"scope_enforcement":   false,
		"unsupported_reasons": researchUnsupportedReasons,
		"effective_settings":  nil,
		"lifecycle_support":   false,
		"usage_support":       false,
		"version":             researchCapabilityVersion,
	})
	return toolText(string(answer), false), 0, ""
}
