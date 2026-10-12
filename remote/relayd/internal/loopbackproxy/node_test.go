package loopbackproxy

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

func TestNodeProxyKeepsLegacyFramesAndFragmentedRPC(t *testing.T) {
	client, front := net.Pipe()
	upstream, supervisor := net.Pipe()
	defer client.Close()
	defer supervisor.Close()
	client.SetDeadline(time.Now().Add(5 * time.Second))
	supervisor.SetDeadline(time.Now().Add(5 * time.Second))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- RelayNode(ctx, front, front, upstream) }()
	daemonDone := make(chan error, 1)
	ordinary := []byte(`{"request_id":"ordinary-rpc","operation":"file_stat","padding":"` + string(bytes.Repeat([]byte("x"), 300<<10)) + `"}`)
	go func() {
		writer := protocol.NewWriter(supervisor)
		ready := protocol.Frame{Type: protocol.Status, Payload: []byte(`{"state":"ready","capabilities":["host_rpc_v1"],"exact_counter":18446744073709551614}`)}
		if err := writer.Write(ready); err != nil {
			daemonDone <- err
			return
		}
		ping, err := protocol.ReadFrame(supervisor)
		if err != nil {
			daemonDone <- err
			return
		}
		if ping.Type != protocol.Ping {
			daemonDone <- net.ErrClosed
			return
		}
		if err := writer.Write(protocol.Frame{Type: protocol.Pong, Payload: ping.Payload}); err != nil {
			daemonDone <- err
			return
		}
		forwarded, err := protocol.ReadFrame(supervisor)
		if err != nil {
			daemonDone <- err
			return
		}
		if forwarded.Type != protocol.HostRequest || !bytes.Equal(forwarded.Payload, ordinary) {
			daemonDone <- net.ErrClosed
			return
		}
		answer := []byte(`{"request_id":"ordinary-rpc","result":{"bytes":"` + string(bytes.Repeat([]byte("y"), 300<<10)) + `"}}`)
		daemonDone <- writer.Write(protocol.Frame{Type: protocol.HostResponse, Payload: answer})
	}()
	writer := protocol.NewScheduledWriter(client)
	reader := protocol.NewFragmentReader(client)
	ready, err := reader.Read()
	if err != nil {
		t.Fatal(err)
	}
	var status map[string]json.RawMessage
	if json.Unmarshal(ready.Payload, &status) != nil || string(status["exact_counter"]) != "18446744073709551614" {
		t.Fatal("ready metadata changed")
	}
	var caps []string
	json.Unmarshal(status["capabilities"], &caps)
	found := false
	for _, cap := range caps {
		if cap == "loopback_stream_v1" {
			found = true
		}
	}
	if !found {
		t.Fatal("native stream capability absent")
	}
	if err := writer.Write(protocol.Frame{Type: protocol.Capabilities, Payload: []byte(`{"wire_fragments":true}`)}); err != nil {
		t.Fatal(err)
	}
	writer.EnableFragments()
	reader.Enabled = true
	capability, _ := json.Marshal(Request{RequestID: "native-caps", Operation: "loopback_caps"})
	if err := writer.Write(protocol.Frame{Type: protocol.HostRequest, Payload: capability}); err != nil {
		t.Fatal(err)
	}
	response, err := reader.Read()
	if err != nil || response.Type != protocol.HostResponse {
		t.Fatal("native RPC failed", err)
	}
	if !bytes.Contains(response.Payload, []byte(`"scope_id"`)) {
		t.Fatal("native RPC was not locally served")
	}
	if err := writer.Write(protocol.Frame{Type: protocol.Ping, Payload: []byte("retained-heartbeat")}); err != nil {
		t.Fatal(err)
	}
	pong, err := reader.Read()
	if err != nil || pong.Type != protocol.Pong || string(pong.Payload) != "retained-heartbeat" {
		t.Fatal("heartbeat changed", err)
	}
	if err := writer.Write(protocol.Frame{Type: protocol.HostRequest, Payload: ordinary}); err != nil {
		t.Fatal(err)
	}
	answer, err := reader.Read()
	if err != nil || answer.Type != protocol.HostResponse || !bytes.Contains(answer.Payload, []byte("ordinary-rpc")) || len(answer.Payload) < 300<<10 {
		t.Fatal("large backend response changed", err)
	}
	if err := <-daemonDone; err != nil {
		t.Fatal(err)
	}
	client.Close()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("node leases did not retire")
	}
}
