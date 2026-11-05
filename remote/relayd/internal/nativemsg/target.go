package nativemsg

import (
	"context"
	"errors"

	"github.com/relay-terminal/relayd/internal/desktoproute"
)

// Target is an explicit provider endpoint. A Work task is not a terminal pane;
// both cannot be set. A selected Work owner is rechecked during delivery.
type Target struct {
	Kind   string        `json:"kind"`
	PaneID string        `json:"pane_id,omitempty"`
	Work   *WorkEndpoint `json:"work,omitempty"`
}

// IdentityKey distinguishes the logical target from its mutable process
// incarnation. It is not an authorization, owner check, or transition proof.
func (t Target) IdentityKey() (string, error) {
	switch t.Kind {
	case "pane":
		if t.PaneID == "" || t.Work != nil {
			return "", errors.New("invalid pane target")
		}
		return "pane:" + t.PaneID, nil
	case "work":
		if t.PaneID != "" || t.Work == nil || !desktoproute.ValidWorkThread(t.Work.Thread) || t.Work.Owner == "" || t.Work.Incarnation == "" {
			return "", errors.New("invalid Work target")
		}
		return "work:" + t.Work.Thread, nil
	default:
		return "", errors.New("unknown native target kind")
	}
}

type WorkMessage struct {
	Envelope desktoproute.Envelope
	// Authorize is supplied by the communication authority, not the sender.
	// It is rechecked immediately before Work IPC dispatch.
	Authorize func(context.Context) error
}

// RunTarget is the native provider dispatch boundary. Legacy pane packets
// remain unchanged. Work delivery is unavailable without an authority guard.
func RunTarget(ctx context.Context, host Host, target Target, packet []byte, work *WorkMessage) (map[string]any, error) {
	if _, err := target.IdentityKey(); err != nil {
		return nil, err
	}
	switch target.Kind {
	case "pane":
		if work != nil {
			return nil, errors.New("invalid pane target")
		}
		return Run(ctx, host, target.PaneID, packet), nil
	case "work":
		if len(packet) != 0 || work == nil || work.Authorize == nil {
			return nil, errors.New("invalid Work target or authority")
		}
		deliver := host.workDeliver
		if deliver == nil {
			deliver = desktoproute.DeliverSelectedWork
		}
		delivery := deliverWork(ctx, *target.Work, work.Envelope, work.Authorize, deliver)
		result := map[string]any{"message_id": delivery.MessageID, "transport": "work_ipc", "replay_permitted": false}
		switch delivery.Receipt {
		case "admitted":
			result["status"], result["acknowledgement"] = "admitted_not_processed", "not_implied"
		case "not_sent":
			result["status"] = "not_sent"
		default:
			result["status"] = "outcome_unknown"
		}
		if delivery.Error != "" {
			result["error"] = delivery.Error
		}
		return result, nil
	default:
		return nil, errors.New("unknown native target kind")
	}
}
