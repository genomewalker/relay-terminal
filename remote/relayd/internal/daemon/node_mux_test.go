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
	if !containsCapability(nodeStatus.Capabilities, "viewport_commit_compat_v1") {
		t.Fatalf("node multiplexer did not advertise legacy viewport recovery: %#v", nodeStatus.Capabilities)
	}
	if !containsCapability(nodeStatus.Capabilities, "viewport_commit_compat_v2") {
		t.Fatalf("node multiplexer did not advertise exactly-once viewport recovery: %#v", nodeStatus.Capabilities)
	}

	heartbeat := []byte("heartbeat-1")
	if err := writer.Write(protocol.Frame{Type: protocol.Ping, Payload: heartbeat}); err != nil {
		t.Fatal(err)
	}
	pong, err := protocol.ReadFrame(client)
	if err != nil || pong.Type != protocol.Pong || string(pong.Payload) != string(heartbeat) {
		t.Fatalf("node heartbeat was not echoed: frame=%#v err=%v", pong, err)
	}

	// An invalid top-level frame is already fully framed and consumed. It must
	// not collapse every pane or stop the node-level heartbeat.
	if err := writer.Write(protocol.Frame{Type: protocol.Status, Payload: []byte("ignored")}); err != nil {
		t.Fatal(err)
	}
	heartbeat = []byte("heartbeat-after-invalid-route")
	if err := writer.Write(protocol.Frame{Type: protocol.Ping, Payload: heartbeat}); err != nil {
		t.Fatal(err)
	}
	pong, err = protocol.ReadFrame(client)
	if err != nil || pong.Type != protocol.Pong || string(pong.Payload) != string(heartbeat) {
		t.Fatalf("invalid route killed node heartbeat: frame=%#v err=%v", pong, err)
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

	// A virtual pane can close while the shared SSH/node stream remains alive
	// (for example when a fast TUI overflows its bounded viewer queue). The
	// client needs an explicit route-level signal so it can replay that pane.
	closedEnvelope, err := protocol.ReadFrame(client)
	if err != nil {
		t.Fatal(err)
	}
	closedSessionID, closedResponse, err := protocol.ParseHostEvent(closedEnvelope)
	if err != nil || closedSessionID != "pane-probe" || closedResponse.Type != protocol.Status {
		t.Fatalf("unexpected route-close response: session=%q frame=%#v err=%v", closedSessionID, closedResponse, err)
	}
	var closedStatus protocol.StatusPayload
	if protocol.DecodeJSON(closedResponse, &closedStatus) != nil || closedStatus.State != "route_closed" {
		t.Fatalf("virtual route closure was silent: %#v", closedResponse)
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

func TestMultiplexedSessionBackpressureIsRouteLocal(t *testing.T) {
	client, server := net.Pipe()
	defer server.Close()
	route := newMultiplexedSession(client, true, "pane-blocked")
	defer route.close()
	for index := 0; index < cap(route.outbound); index++ {
		if !route.enqueue(protocol.Frame{Type: protocol.Input, Payload: []byte{byte(index)}}) {
			t.Fatalf("route queue rejected frame %d before reaching capacity", index)
		}
	}
	started := time.Now()
	if route.enqueue(protocol.Frame{Type: protocol.Input, Payload: []byte("overflow")}) {
		t.Fatal("full route queue accepted an unbounded frame")
	}
	if elapsed := time.Since(started); elapsed > 50*time.Millisecond {
		t.Fatalf("full route queue blocked the node reader for %s", elapsed)
	}
}

func TestWorkerStartupLocksArePerSession(t *testing.T) {
	server := NewServer()
	if server.workerLock("pane-a") != server.workerLock("pane-a") {
		t.Fatal("one pane did not retain a stable startup lock")
	}
	if server.workerLock("pane-a") == server.workerLock("pane-b") {
		t.Fatal("unrelated panes still share a worker startup lock")
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

func TestMultiplexedSessionCachesWorkerViewportCapability(t *testing.T) {
	virtual := &multiplexedSession{}
	if known, supported := virtual.supportsExactViewportCommit(); known || supported {
		t.Fatalf("new route unexpectedly had cached capabilities")
	}
	status, err := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{
		State: "attached", Capabilities: []string{"viewport_commit_v2"},
	})
	if err != nil {
		t.Fatal(err)
	}
	virtual.observeWorkerFrame(status)
	if known, supported := virtual.supportsExactViewportCommit(); !known || !supported {
		t.Fatalf("attached worker capability was not cached: known=%v supported=%v", known, supported)
	}
}
