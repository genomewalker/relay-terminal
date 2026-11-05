package nativemsg

import (
	"context"
	"errors"
	"unicode"
	"unicode/utf8"

	"github.com/relay-terminal/relayd/internal/desktoproute"
)

// WorkEndpoint identifies a Work conversation independently of terminal pane
// IDs. An observation is not an authorization to send to that conversation.
type WorkEndpoint struct {
	Thread      string `json:"thread"`
	Owner       string `json:"owner"`
	Incarnation string `json:"incarnation"`
}

// Valid checks bounded identity metadata, not whether the owner is live or
// authorized. Live owner and process verification occurs through Work IPC.
func (w WorkEndpoint) Valid() bool {
	if !desktoproute.ValidWorkThread(w.Thread) || !validWorkIdentityText(w.Owner, 128) || !validWorkIdentityText(w.Incarnation, 160) {
		return false
	}
	return true
}

func validWorkIdentityText(value string, limit int) bool {
	if value == "" || len(value) > limit || !utf8.ValidString(value) {
		return false
	}
	for _, r := range value {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

// ObserveWork resolves an explicitly selected conversation through the same
// Work IPC identity checks used by the existing desktop route.
func ObserveWork(ctx context.Context, thread string) (WorkEndpoint, error) {
	return observeWork(ctx, thread, desktoproute.InspectSelectedWork)
}

func observeWork(ctx context.Context, thread string, inspect func(context.Context, string) (desktoproute.SelectedWorkIdentity, error)) (WorkEndpoint, error) {
	if inspect == nil || !desktoproute.ValidWorkThread(thread) {
		return WorkEndpoint{}, errors.New("invalid Work selection")
	}
	selected, err := inspect(ctx, thread)
	if err != nil {
		return WorkEndpoint{}, err
	}
	if selected.Thread != thread || selected.PID <= 1 || !(WorkEndpoint{Thread: selected.Thread, Owner: selected.Owner, Incarnation: selected.Incarnation()}).Valid() {
		return WorkEndpoint{}, errors.New("Work identity unavailable")
	}
	return WorkEndpoint{Thread: selected.Thread, Owner: selected.Owner, Incarnation: selected.Incarnation()}, nil
}

// DeliverWork uses the same Work IPC adapter and preserves its unknown versus
// admitted result. The caller must supply the communication service's final
// authorization check; this adapter cannot establish sender identity itself.
func DeliverWork(ctx context.Context, endpoint WorkEndpoint, message desktoproute.Envelope, authorize func(context.Context) error) desktoproute.Delivery {
	if authorize == nil || !endpoint.Valid() {
		return desktoproute.Delivery{MessageID: message.ID, Receipt: "not_sent", Transport: "work_ipc", Error: "Work identity or authorization unavailable"}
	}
	return deliverWork(ctx, endpoint, message, authorize, desktoproute.DeliverSelectedWork)
}

func deliverWork(ctx context.Context, endpoint WorkEndpoint, message desktoproute.Envelope, authorize func(context.Context) error, deliver func(context.Context, string, string, string, desktoproute.Envelope, func(context.Context) error) desktoproute.Delivery) desktoproute.Delivery {
	if authorize == nil || deliver == nil || !endpoint.Valid() {
		return desktoproute.Delivery{MessageID: message.ID, Receipt: "not_sent", Transport: "work_ipc", Error: "Work identity or authorization unavailable"}
	}
	return deliver(ctx, endpoint.Thread, endpoint.Owner, endpoint.Incarnation, message, authorize)
}
