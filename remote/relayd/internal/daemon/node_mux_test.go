package daemon

import (
	"net"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

func TestNodeMultiplexRoutesVirtualProtocolConnection(t *testing.T) {
	client, serverConnection := net.Pipe()
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(3 * time.Second))
	server := NewServer()
	go server.serveConnection(serverConnection)

	writer := protocol.NewWriter(client)
	nodeHello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{Version: 1, NodeMux: true})
	if err := writer.Write(nodeHello); err != nil {
		t.Fatal(err)
	}
	ready, err := protocol.ReadFrame(client)
	if err != nil {
		t.Fatal(err)
	}
	var nodeStatus protocol.StatusPayload
	if protocol.DecodeJSON(ready, &nodeStatus) != nil || nodeStatus.State != "ready" {
		t.Fatalf("node multiplexer was not ready: %#v", ready)
	}

	probeHello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: 1, SessionID: "pane-probe", Probe: true,
	})
	if err := writer.Write(protocol.HostEventFrame("pane-probe", probeHello)); err != nil {
		t.Fatal(err)
	}
	envelope, err := protocol.ReadFrame(client)
	if err != nil {
		t.Fatal(err)
	}
	sessionID, response, err := protocol.ParseHostEvent(envelope)
	if err != nil || sessionID != "pane-probe" || response.Type != protocol.Status {
		t.Fatalf("unexpected routed response: session=%q frame=%#v err=%v", sessionID, response, err)
	}
	var status protocol.StatusPayload
	if protocol.DecodeJSON(response, &status) != nil || status.State != "ready" {
		t.Fatalf("virtual probe was not routed: %#v", response)
	}
}
