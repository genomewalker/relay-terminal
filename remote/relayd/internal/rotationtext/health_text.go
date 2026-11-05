package rotationtext

import (
	"context"
	"errors"
)

// HealthText serves the pane-health controller's remaining text_backend
// calls in process, replacing relayd's Python co-process: health validation
// and assessments through one journal over the Go ledger, opened once for the
// controller operation as the co-process opened its TextJournal.
type HealthText struct {
	journal *Journal
}

// HealthTextError is a call that raised: Code is the DraftError code, or ""
// where the co-process replied with a null code (any other exception).
type HealthTextError struct{ Code string }

func (e *HealthTextError) Error() string {
	if e.Code == "" {
		return "health text call failed"
	}
	return e.Code
}

// ErrHealthTextLost is a failure the co-process could not have replied to.
var ErrHealthTextLost = errors.New("pane health text backend unavailable")

func OpenHealthText(ctx context.Context, root string) (*HealthText, error) {
	journal, err := OpenLedgerJournal(ctx, root)
	if err != nil {
		return nil, err
	}
	return &HealthText{journal: journal}, nil
}

func (h *HealthText) Close() error { return h.journal.Close() }

// Call runs one operation on its JSON-encoded argument object and returns the
// JSON-encoded value.
func (h *HealthText) Call(ctx context.Context, operation string, args []byte) (reply []byte, err error) {
	defer func() {
		if value := recover(); value != nil {
			draft, _ := recoverPy(value)
			if draft != nil {
				reply, err = nil, &HealthTextError{Code: draft.code}
			} else {
				reply, err = nil, &HealthTextError{}
			}
		}
	}()
	request, ok := parseJSON(args).(obj)
	if !ok {
		raise("TypeError")
	}
	arg := func(key string) any {
		value, ok := request[key]
		if !ok {
			raise("KeyError")
		}
		return value
	}
	list := func(value any) []any {
		items, ok := value.([]any)
		if !ok {
			raise("TypeError")
		}
		return items
	}
	var value any
	switch operation {
	case "validate_panes":
		value = validHealthPanes(arg("host_id"), arg("snapshot_id"), arg("panes"))
	case "validate_messages":
		messages, hostID, panes := arg("messages"), arg("host_id"), list(arg("panes"))
		value = validateHealthMessages(messages, hostID, panes)
	case "validate_calls":
		content, latest := arg("content"), list(arg("latest"))
		value = validateHealthCalls(content, latest, true)
	case "assess":
		value = h.journal.Assess(ctx, arg("request"))
	case "status":
		value = h.journal.Status(arg("operation_id"))
	default:
		raise("ValueError")
	}
	encoded := compact(value)
	if hasSurrogate(encoded) {
		// The co-process could not write a lone surrogate to its UTF-8 reply.
		return nil, ErrHealthTextLost
	}
	return []byte(encoded), nil
}
