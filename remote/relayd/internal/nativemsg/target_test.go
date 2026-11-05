package nativemsg

import (
	"context"
	"reflect"
	"testing"

	"github.com/relay-terminal/relayd/internal/desktoproute"
)

func TestRunTargetPreservesPaneDispatchAndRejectsAmbiguity(t *testing.T) {
	ctx := context.Background()
	packet := []byte("not json")
	got, err := RunTarget(ctx, Host{}, Target{Kind: "pane", PaneID: "test-pane"}, packet, nil)
	if err != nil || !reflect.DeepEqual(got, Run(ctx, Host{}, "test-pane", packet)) {
		t.Fatal(got, err)
	}
	endpoint := &WorkEndpoint{Thread: "task-1", Owner: "owner", Incarnation: "42:123"}
	if _, err = RunTarget(ctx, Host{}, Target{Kind: "pane", PaneID: "test-pane", Work: endpoint}, packet, nil); err == nil {
		t.Fatal("ambiguous target accepted")
	}
	if _, err = RunTarget(ctx, Host{}, Target{Kind: "work", Work: endpoint}, nil, &WorkMessage{Envelope: desktoproute.Envelope{ID: "1", Sender: "sender", Content: "text"}}); err == nil {
		t.Fatal("missing authority accepted")
	}
	if _, err = RunTarget(ctx, Host{}, Target{Kind: "work", Work: endpoint, PaneID: "test-pane"}, nil, nil); err == nil {
		t.Fatal("mixed target accepted")
	}
}

func TestRunTargetWorkPropagatesAdmissionAndUnknown(t *testing.T) {
	target := Target{Kind: "work", Work: &WorkEndpoint{Thread: "task-1", Owner: "owner", Incarnation: "42:123"}}
	message := desktoproute.Envelope{ID: "msg-1", Sender: "verified-source", Content: "hello"}
	calls, guards := 0, 0
	host := Host{workDeliver: func(ctx context.Context, thread, owner, incarnation string, got desktoproute.Envelope, guard func(context.Context) error) desktoproute.Delivery {
		calls++
		if thread != "task-1" || owner != "owner" || incarnation != "42:123" || got != message {
			t.Fatal("identity or message changed")
		}
		if err := guard(ctx); err != nil {
			return desktoproute.Delivery{Receipt: "not_sent"}
		}
		return desktoproute.Delivery{MessageID: got.ID, Receipt: "admitted"}
	}}
	work := &WorkMessage{Envelope: message, Authorize: func(context.Context) error { guards++; return nil }}
	result, err := RunTarget(context.Background(), host, target, nil, work)
	if err != nil || result["status"] != "admitted_not_processed" || result["replay_permitted"] != false || calls != 1 || guards != 1 {
		t.Fatal(result, err, calls, guards)
	}
	host.workDeliver = func(context.Context, string, string, string, desktoproute.Envelope, func(context.Context) error) desktoproute.Delivery {
		return desktoproute.Delivery{MessageID: message.ID, Receipt: "unknown"}
	}
	result, err = RunTarget(context.Background(), host, target, nil, work)
	if err != nil || result["status"] != "outcome_unknown" || result["replay_permitted"] != false {
		t.Fatal(result, err)
	}
}

func TestNativeTargetIdentitySeparatesWorkFromPane(t *testing.T) {
	pane := Target{Kind: "pane", PaneID: "same-id"}
	work := Target{Kind: "work", Work: &WorkEndpoint{Thread: "same-id", Owner: "owner", Incarnation: "42:123"}}
	a, err := pane.IdentityKey()
	if err != nil {
		t.Fatal(err)
	}
	b, err := work.IdentityKey()
	if err != nil || a == b {
		t.Fatal(a, b, err)
	}
	// A process replacement does not silently validate a saved binding: the
	// stable key is not an authorization or an incarnation comparison.
	replacement := *work.Work
	replacement.Incarnation = "43:124"
	c, err := (Target{Kind: "work", Work: &replacement}).IdentityKey()
	if err != nil || c != b || replacement == *work.Work {
		t.Fatal("logical identity or incarnation lost")
	}
	if _, err := (Target{Kind: "work", PaneID: "same-id", Work: work.Work}).IdentityKey(); err == nil {
		t.Fatal("mixed identity accepted")
	}
}
