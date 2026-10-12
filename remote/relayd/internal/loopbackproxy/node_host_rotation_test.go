package loopbackproxy

import (
	"bytes"
	"context"
	"encoding/json"
	"github.com/relay-terminal/relayd/internal/protocol"
	"net"
	"testing"
	"time"
)

func TestNodeProxyHostRotationBypassesRetainedSupervisor(t *testing.T) {
	client, front := net.Pipe()
	upstream, supervisor := net.Pipe()
	defer client.Close()
	defer supervisor.Close()
	client.SetDeadline(time.Now().Add(5 * time.Second))
	supervisor.SetDeadline(time.Now().Add(5 * time.Second))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	handled := make(chan []byte, 1)
	handler := func(_ context.Context, data []byte) ([]byte, error) {
		handled <- data
		return []byte(`{"request_id":"account-status","result":{"v":1,"status":"not_configured","credential_support":"v1"}}`), nil
	}
	go func() { done <- RelayNodeWithHostRequestHandler(ctx, front, front, upstream, handler) }()
	daemonDone := make(chan error, 1)
	go func() {
		w := protocol.NewWriter(supervisor)
		if err := w.Write(protocol.Frame{Type: protocol.Status, Payload: []byte(`{"state":"ready","capabilities":["host_rpc_v1"],"exact_counter":18446744073709551614}`)}); err != nil {
			daemonDone <- err
			return
		}
		frame, err := protocol.ReadFrame(supervisor)
		if err != nil {
			daemonDone <- err
			return
		}
		if frame.Type != protocol.Ping || string(frame.Payload) != "terminal-stream-preserved" {
			daemonDone <- net.ErrClosed
			return
		}
		daemonDone <- w.Write(protocol.Frame{Type: protocol.Pong, Payload: frame.Payload})
	}()
	w := protocol.NewWriter(client)
	r := protocol.NewFragmentReader(client)
	ready, err := r.Read()
	if err != nil {
		t.Fatal(err)
	}
	var status map[string]json.RawMessage
	if json.Unmarshal(ready.Payload, &status) != nil || string(status["exact_counter"]) != "18446744073709551614" || !bytes.Contains(status["capabilities"], []byte("host_rotation_client_v1")) {
		t.Fatal("ready metadata", string(ready.Payload))
	}
	request := []byte(`{"request_id":"account-status","operation":"host_rotation","host_rotation":{"pane_id":"pane","client_id":"client","request":{"v":1,"operation":"text_status"}}}`)
	if err := w.Write(protocol.Frame{Type: protocol.HostRequest, Payload: request}); err != nil {
		t.Fatal(err)
	}
	answer, err := r.Read()
	if err != nil || answer.Type != protocol.HostResponse || !bytes.Contains(answer.Payload, []byte("credential_support")) {
		t.Fatal("account response", err, string(answer.Payload))
	}
	select {
	case got := <-handled:
		if !bytes.Equal(got, request) {
			t.Fatal("request changed")
		}
	case <-time.After(time.Second):
		t.Fatal("handler never called")
	}
	if err := w.Write(protocol.Frame{Type: protocol.Ping, Payload: []byte("terminal-stream-preserved")}); err != nil {
		t.Fatal(err)
	}
	pong, err := r.Read()
	if err != nil || pong.Type != protocol.Pong {
		t.Fatal("terminal heartbeat", err)
	}
	if err := <-daemonDone; err != nil {
		t.Fatal(err)
	}
	client.Close()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("node shutdown")
	}
}
