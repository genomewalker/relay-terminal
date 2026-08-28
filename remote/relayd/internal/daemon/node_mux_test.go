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
	if !containsCapability(nodeStatus.Capabilities, "node_mux_v2") {
		t.Fatalf("node multiplexer did not advertise independent routes: %#v", nodeStatus.Capabilities)
	}

	heartbeat := []byte("heartbeat-1")
	if err := writer.Write(protocol.Frame{Type: protocol.Ping, Payload: heartbeat}); err != nil {
		t.Fatal(err)
	}
	pong, err := protocol.ReadFrame(client)
	if err != nil || pong.Type != protocol.Pong || string(pong.Payload) != string(heartbeat) {
		t.Fatalf("node heartbeat was not echoed: frame=%#v err=%v", pong, err)
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

	observerHello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: 1, SessionID: "pane-probe", Probe: true,
	})
	if err := writer.Write(protocol.HostEventFrame("observer-pane-probe", observerHello)); err != nil {
		t.Fatal(err)
	}
	observerEnvelope, err := protocol.ReadFrame(client)
	if err != nil {
		t.Fatal(err)
	}
	routeID, observerResponse, err := protocol.ParseHostEvent(observerEnvelope)
	if err != nil || routeID != "observer-pane-probe" || observerResponse.Type != protocol.Status {
		t.Fatalf("independent observer route failed: route=%q frame=%#v err=%v", routeID, observerResponse, err)
	}
}

func containsCapability(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}
