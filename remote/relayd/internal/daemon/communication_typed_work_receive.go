package daemon

// Typed Work delivery is part of the common communication service. This
// source increment is not yet registered on a peer listener. A fresh source
// observation is not a continuous fence: production also requires a proven
// cross-node admission/transition barrier and Work-side commit semantics.
import (
	"context"
	"errors"
	"os"
	"time"

	"github.com/relay-terminal/relayd/internal/desktoproute"
	"github.com/relay-terminal/relayd/internal/nativemsg"
)

type communicationTypedWorkReceipt struct {
	Version      int            `json:"version"`
	LinkID       string         `json:"link_id"`
	SourceNodeID string         `json:"source_node_id"`
	TargetNodeID string         `json:"target_node_id"`
	MessageID    string         `json:"message_id"`
	Fingerprint  string         `json:"fingerprint"`
	CreatedAt    time.Time      `json:"created_at"`
	Result       map[string]any `json:"result"`
}

type communicationTypedWorkHooks struct {
	// readAuthorizedLink must re-read the local relationship, active pinned
	// route and remote-receive policy. It must perform no network I/O because
	// it runs under the metadata lock.
	readAuthorizedLink func(context.Context, string) (communicationTypedRemoteLink, error)
	// sourceFresh must independently authenticate an observation bound to the
	// exact message, link and source. It is not a continuous source fence.
	sourceFresh func(context.Context, communicationTypedWorkMessage) error
	observeWork func(context.Context, string) (nativemsg.WorkEndpoint, error)
	deliverWork func(context.Context, nativemsg.WorkEndpoint, communicationTypedWorkMessage, func(context.Context) error) (map[string]any, error)
	now         func() time.Time
}

func typedWorkReceiptMatches(r communicationTypedWorkReceipt, m communicationTypedWorkMessage, node string) bool {
	return r.Version == 2 && r.LinkID == m.LinkID && r.SourceNodeID == m.Source.NodeID && r.TargetNodeID == node &&
		r.MessageID == m.MessageID && r.Fingerprint == m.Fingerprint && !r.CreatedAt.IsZero() && r.Result != nil
}

// communicationReceiveTypedWork reuses the existing peer receipt namespace and
// metadata lock. It claims before delivery, stores no message text, and never
// retries a claimed ID. Unknown remains unknown after an interrupted delivery.
func communicationReceiveTypedWork(ctx context.Context, root, node, peerCertificate string, m communicationTypedWorkMessage, hooks communicationTypedWorkHooks) (map[string]any, error) {
	if hooks.readAuthorizedLink == nil || hooks.sourceFresh == nil || hooks.observeWork == nil || hooks.deliverWork == nil || hooks.now == nil ||
		!canonicalRouteToken(node) || !remoteDigest(peerCertificate) || m.Fingerprint == "" || m.Fingerprint != communicationTypedWorkFingerprint(m) {
		return nil, errors.New("typed Work delivery unavailable")
	}
	path := remoteReceiptPath(root, m.Source.NodeID, m.MessageID)
	var receipt communicationTypedWorkReceipt
	claimed := false
	check := func(c context.Context) error {
		if err := c.Err(); err != nil {
			return err
		}
		link, err := hooks.readAuthorizedLink(c, m.LinkID)
		if err != nil {
			return err
		}
		return communicationVerifyTypedWorkDelivery(link, node, peerCertificate, m, hooks.now().UTC())
	}
	// Authenticate before observations, and return an existing receipt without
	// re-observing or redispatching. Receipt queries after authorization expiry
	// require a separately authenticated receipt operation.
	existing := false
	if err := communicationFanoutLocked(root, func() error {
		if err := check(ctx); err != nil {
			return err
		}
		if err := communicationRead(path, &receipt); err == nil {
			if !typedWorkReceiptMatches(receipt, m, node) {
				return errors.New("message identity conflicts with prior request")
			}
			existing = true
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}); err != nil {
		return nil, err
	}
	if existing {
		return receipt.Result, nil
	}
	if err := hooks.sourceFresh(ctx, m); err != nil {
		return nil, err
	}
	observed, err := hooks.observeWork(ctx, m.Target.Work.Thread)
	if err != nil || observed != *m.Target.Work {
		return nil, errors.New("selected Work identity changed")
	}
	err = communicationFanoutLocked(root, func() error {
		if err := check(ctx); err != nil {
			return err
		}
		if err := communicationRead(path, &receipt); err == nil {
			if !typedWorkReceiptMatches(receipt, m, node) {
				return errors.New("message identity conflicts with prior request")
			}
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		receipt = communicationTypedWorkReceipt{Version: 2, LinkID: m.LinkID, SourceNodeID: m.Source.NodeID, TargetNodeID: node,
			MessageID: m.MessageID, Fingerprint: m.Fingerprint, CreatedAt: hooks.now().UTC(),
			Result: map[string]any{"status": "outcome_unknown", "message_id": m.MessageID, "source_authentication": "source_signed", "authority": "relayd", "replay_permitted": false}}
		if err := communicationAtomic(path, receipt); err != nil {
			return err
		}
		if err := communicationEvent(root, node, "remote_message_claimed", []map[string]string{{"link_id": m.LinkID, "message_id": m.MessageID, "peer_node_id": m.Source.NodeID}}); err != nil {
			return err
		}
		claimed = true
		return nil
	})
	if err != nil {
		return nil, err
	}
	if !claimed {
		return receipt.Result, nil
	}
	guard := func(c context.Context) error {
		if err := hooks.sourceFresh(c, m); err != nil {
			return err
		}
		return communicationFanoutLocked(root, func() error { return check(c) })
	}
	native, sendErr := hooks.deliverWork(ctx, observed, m, guard)
	outcome := communicationNativeOutcome(native, sendErr)
	err = communicationFanoutLocked(root, func() error {
		var current communicationTypedWorkReceipt
		if err := communicationRead(path, &current); err != nil {
			return err
		}
		if !typedWorkReceiptMatches(current, m, node) {
			return errors.New("typed Work receipt changed")
		}
		for k, v := range outcome {
			current.Result[k] = v
		}
		current.Result["source_authentication"], current.Result["authority"], current.Result["replay_permitted"] = "source_signed", "relayd", false
		if err := communicationAtomic(path, current); err != nil {
			return err
		}
		receipt = current
		return communicationEvent(root, node, "remote_message_outcome", []map[string]string{{"message_id": m.MessageID, "status": fmtRemoteStatus(current.Result)}})
	})
	if err != nil {
		return nil, err
	}
	return receipt.Result, nil
}

// communicationNativeTypedWorkHooks joins the common peer receipt service to
// the native Work adapter. A real source freshness authority is mandatory;
// until one is available, there is deliberately no production registration.
func communicationNativeTypedWorkHooks(root, node string, sourceFresh func(context.Context, communicationTypedWorkMessage) error) (communicationTypedWorkHooks, error) {
	if !canonicalRouteToken(node) || sourceFresh == nil {
		return communicationTypedWorkHooks{}, errors.New("source freshness authority required")
	}
	return communicationTypedWorkHooks{
		readAuthorizedLink: func(ctx context.Context, id string) (communicationTypedRemoteLink, error) {
			return communicationReadTypedAuthorizedLink(ctx, root, node, id)
		},
		sourceFresh: sourceFresh,
		observeWork: nativemsg.ObserveWork,
		deliverWork: func(ctx context.Context, target nativemsg.WorkEndpoint, m communicationTypedWorkMessage, authorize func(context.Context) error) (map[string]any, error) {
			sender := "Relay pane " + m.Source.NodeID + "/" + m.Source.PaneID + " (" + m.Source.Provider + " session " + m.Source.SessionID + ")"
			message := &nativemsg.WorkMessage{Envelope: desktoproute.Envelope{ID: m.MessageID, Sender: sender, Content: m.Text}, Authorize: authorize}
			return nativemsg.RunTarget(ctx, nativemsg.Host{}, nativemsg.Target{Kind: "work", Work: &target}, nil, message)
		},
		now: time.Now,
	}, nil
}
