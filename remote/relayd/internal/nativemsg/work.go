package nativemsg

import (
	"context"
	"errors"

	"github.com/relay-terminal/relayd/internal/desktoproute"
)

// WorkEndpoint identifies a Work conversation independently of terminal pane
// IDs. An observation is not an authorization to send to that conversation.
type WorkEndpoint struct {
	Thread      string `json:"thread"`
	Owner       string `json:"owner"`
	Incarnation string `json:"incarnation"`
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
	if selected.Thread != thread || selected.Owner == "" || selected.PID <= 1 || selected.Start == "" {
		return WorkEndpoint{}, errors.New("Work identity unavailable")
	}
	return WorkEndpoint{Thread: selected.Thread, Owner: selected.Owner, Incarnation: selected.Incarnation()}, nil
}

// DeliverWork uses the same Work IPC adapter and preserves its unknown versus
// admitted result. The caller must supply the communication service's final
// authorization check; this adapter cannot establish sender identity itself.
func DeliverWork(ctx context.Context, endpoint WorkEndpoint, message desktoproute.Envelope, authorize func(context.Context) error) desktoproute.Delivery {
	if authorize == nil || !desktoproute.ValidWorkThread(endpoint.Thread) || endpoint.Owner == "" || endpoint.Incarnation == "" {
		return desktoproute.Delivery{MessageID: message.ID, Receipt: "not_sent", Transport: "work_ipc", Error: "Work identity or authorization unavailable"}
	}
	return deliverWork(ctx, endpoint, message, authorize, desktoproute.DeliverSelectedWork)
}

func deliverWork(ctx context.Context, endpoint WorkEndpoint, message desktoproute.Envelope, authorize func(context.Context) error, deliver func(context.Context, string, string, string, desktoproute.Envelope, func(context.Context) error) desktoproute.Delivery) desktoproute.Delivery {
	if authorize == nil || deliver == nil || !desktoproute.ValidWorkThread(endpoint.Thread) || endpoint.Owner == "" || endpoint.Incarnation == "" {
		return desktoproute.Delivery{MessageID: message.ID, Receipt: "not_sent", Transport: "work_ipc", Error: "Work identity or authorization unavailable"}
	}
	return deliver(ctx, endpoint.Thread, endpoint.Owner, endpoint.Incarnation, message, authorize)
}
