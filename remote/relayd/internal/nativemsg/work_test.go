package nativemsg

import (
	"context"
	"testing"

	"github.com/relay-terminal/relayd/internal/desktoproute"
)

func TestWorkEndpointRequiresExactSelection(t *testing.T) {
	ctx := context.Background()
	calls := 0
	inspect := func(_ context.Context, thread string) (desktoproute.SelectedWorkIdentity, error) {
		calls++
		return desktoproute.SelectedWorkIdentity{Thread: thread, Owner: "owner", PID: 42, Start: "123"}, nil
	}
	if _, err := observeWork(ctx, "bad/name", inspect); err == nil || calls != 0 {
		t.Fatal("invalid thread was inspected")
	}
	endpoint, err := observeWork(ctx, "task-1", inspect)
	if err != nil || endpoint != (WorkEndpoint{Thread: "task-1", Owner: "owner", Incarnation: "42:123"}) {
		t.Fatal(endpoint, err)
	}
	wrong := func(context.Context, string) (desktoproute.SelectedWorkIdentity, error) {
		return desktoproute.SelectedWorkIdentity{Thread: "task-2", Owner: "owner", PID: 42, Start: "123"}, nil
	}
	if _, err := observeWork(ctx, "task-1", wrong); err == nil {
		t.Fatal("different task accepted")
	}
}

func TestWorkDeliveryRequiresAuthorityBeforeIPC(t *testing.T) {
	result := DeliverWork(context.Background(), WorkEndpoint{Thread: "task-1", Owner: "owner", Incarnation: "42:123"}, desktoproute.Envelope{ID: "m1", Sender: "source", Content: "hello"}, nil)
	if result.Receipt != "not_sent" || result.Transport != "work_ipc" {
		t.Fatal(result)
	}
}
