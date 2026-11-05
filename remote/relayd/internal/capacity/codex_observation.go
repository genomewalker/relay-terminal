package capacity

import (
	"bytes"
	"encoding/json"
	"errors"
	"math"
	"sort"
	"strings"
)

// These names/fields are from the pinned Codex 0.164 experimental
// GetAccountRateLimitsResponse schema. Unsupported/omitted backend permission
// and spend-control state stay unknown. No Claude window names are synthesized.
func ParseCodexObservation(raw []byte) ([]Window, string, error) {
	if len(raw) > 1<<20 {
		return nil, "", errors.New("codex observation bound")
	}
	messages := map[string]json.RawMessage{}
	for _, line := range bytes.Split(raw, []byte{'\n'}) {
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		var envelope map[string]json.RawMessage
		if Decode(line, &envelope) != nil {
			return nil, "", errors.New("codex ambiguous observation")
		}
		var id string
		switch string(envelope["id"]) {
		case "2", `"2"`:
			id = "2"
		case "3", `"3"`:
			id = "3"
		default:
			continue
		}
		if messages[id] != nil || len(envelope["error"]) > 0 {
			return nil, "", errors.New("codex duplicate or failed observation")
		}
		messages[id] = envelope["result"]
	}
	var account struct {
		AccountID string `json:"accountId"`
		Account   *struct {
			Type  string `json:"type"`
			ID    string `json:"id"`
			Email string `json:"email"`
			Plan  string `json:"planType"`
		} `json:"account"`
		RequiresAuth bool `json:"requiresOpenaiAuth"`
	}
	// Account/read may add non-authoritative display metadata. Duplicate keys
	// were already rejected; only the active-account identity fields are used.
	if json.Unmarshal(messages["3"], &account) != nil || account.Account == nil || account.Account.Type != "chatgpt" || account.Account.Email == "" {
		return nil, "", errors.New("codex active account evidence unavailable")
	}
	var result struct {
		AccountID    string                     `json:"accountId"`
		Ordinary     *bool                      `json:"ordinaryUsageAllowed"`
		Legacy       json.RawMessage            `json:"rateLimits"`
		Buckets      map[string]json.RawMessage `json:"rateLimitsByLimitId"`
		ResetCredits json.RawMessage            `json:"rateLimitResetCredits"`
		Upsell       json.RawMessage            `json:"rateLimitUpsell"`
	}
	if Decode(messages["2"], &result) != nil || result.AccountID == "" || result.Ordinary == nil || !*result.Ordinary {
		return nil, "", errors.New("codex ordinary usage/backend permission unavailable")
	}
	if account.AccountID != "" && account.Account.ID != "" && account.AccountID != account.Account.ID {
		return nil, "", errors.New("codex contradictory active-account identity")
	}
	observedID := account.AccountID
	if observedID == "" {
		observedID = account.Account.ID
	}
	if observedID == "" || observedID != result.AccountID {
		return nil, "", errors.New("codex active account identity mismatch")
	}
	if len(result.Buckets) == 0 || len(result.Buckets) > 16 {
		return nil, "", errors.New("codex full reported limit buckets unavailable")
	}
	keys := []string{}
	for k := range result.Buckets {
		if !identifier(k) || strings.Contains(k, ":") {
			return nil, "", errors.New("codex invalid limit identity")
		}
		keys = append(keys, k)
	}
	sort.Strings(keys)
	windows := []Window{}
	type window struct {
		Used     *float64 `json:"usedPercent"`
		Duration *int64   `json:"windowDurationMins"`
		Reset    *int64   `json:"resetsAt"`
	}
	for _, key := range keys {
		var bucket struct {
			Primary    *window `json:"primary"`
			Secondary  *window `json:"secondary"`
			Spend      *bool   `json:"spendControlReached"`
			Individual *struct {
				Limit     string   `json:"limit"`
				Used      string   `json:"used"`
				Remaining *float64 `json:"remainingPercent"`
				Reset     int64    `json:"resetsAt"`
			} `json:"individualLimit"`
			Credits     json.RawMessage `json:"credits"`
			LimitID     *string         `json:"limitId"`
			LimitName   *string         `json:"limitName"`
			NormalModel *string         `json:"normalModelSlug"`
			Plan        *string         `json:"planType"`
			Reached     json.RawMessage `json:"rateLimitReachedType"`
		}
		if Decode(result.Buckets[key], &bucket) != nil || bucket.Spend == nil || *bucket.Spend {
			return nil, "", errors.New("codex spend-control or bucket evidence unavailable")
		}
		if bucket.LimitID != nil && *bucket.LimitID != key {
			return nil, "", errors.New("codex limit bucket identity mismatch")
		}
		count := 0
		for _, item := range []struct {
			name string
			w    *window
		}{{"primary", bucket.Primary}, {"secondary", bucket.Secondary}} {
			if item.w == nil {
				continue
			}
			w := item.w
			if w.Used == nil || (w.Used != nil && (math.IsNaN(*w.Used) || math.IsInf(*w.Used, 0) || *w.Used < 0 || *w.Used > 100)) || w.Duration == nil || w.Reset == nil || *w.Duration <= 0 || *w.Duration >= 1<<20 || *w.Reset <= 0 || *w.Reset > 1<<53/1000 {
				return nil, "", errors.New("codex window counters unavailable")
			}
			windows = append(windows, Window{Name: "codex:" + key + ":" + item.name, Used: *w.Used, ResetMS: *w.Reset * 1000, DurationMinutes: *w.Duration})
			count++
		}
		if count == 0 {
			return nil, "", errors.New("codex reported bucket has no measured window")
		}
		if v := bucket.Individual; v != nil {
			if v.Remaining == nil || *v.Remaining < 0 || *v.Remaining > 100 || v.Reset <= 0 || v.Reset > 1<<53/1000 || len(v.Limit) == 0 || len(v.Limit) > 128 || len(v.Used) == 0 || len(v.Used) > 128 {
				return nil, "", errors.New("codex individual limit evidence unavailable")
			}
			windows = append(windows, Window{Name: "codex:" + key + ":spend_control", Used: 100 - *v.Remaining, ResetMS: v.Reset * 1000})
		}
	}
	return windows, account.Account.Plan, nil
}
