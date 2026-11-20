package contextusage

import "encoding/json"

// Counts is the provider's current usage and reported context window.
// A missing value remains unknown. Zero used tokens is a valid reading.
type Counts struct {
	Used  *int64 `json:"used_tokens,omitempty"`
	Limit *int64 `json:"limit_tokens,omitempty"`
}

const maximumCount = 1 << 53

func count(value *int64) *int64 {
	if value == nil || *value < 0 || *value >= maximumCount {
		return nil
	}
	return value
}

func New(used, limit *int64) Counts {
	limit = count(limit)
	if limit != nil && *limit == 0 {
		limit = nil
	}
	return Counts{Used: count(used), Limit: limit}
}

func Claude(raw json.RawMessage) Counts {
	var window struct {
		Limit   *int64 `json:"context_window_size"`
		Current *struct {
			Input    *int64 `json:"input_tokens"`
			Creation *int64 `json:"cache_creation_input_tokens"`
			Read     *int64 `json:"cache_read_input_tokens"`
		} `json:"current_usage"`
	}
	if json.Unmarshal(raw, &window) != nil {
		return Counts{}
	}
	var used *int64
	if current := window.Current; current != nil {
		if input, creation, read := count(current.Input), count(current.Creation), count(current.Read); input != nil && creation != nil && read != nil {
			sum := *input + *creation + *read
			used = &sum
		}
	}
	return New(used, window.Limit)
}
