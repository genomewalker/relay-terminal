package daemon

import (
	"net"
	"strings"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

func TestFocusPayloadAcceptsOnlySessionRoutes(t *testing.T) {
	route := "0123456789abcdef0123"
	for _, c := range []struct {
		payload string
		ok      bool
		count   int
	}{
		{`{"routes":["` + route + `"]}`, true, 1},
		{`{"routes":[]}`, true, 0},
		{`{}`, true, 0},
		{`{"routes":["../etc"]}`, false, 0},
		{`{"routes":["` + route + `","` + route + `","` + route + `","` + route + `","` + route + `"]}`, false, 0},
		{`not json`, false, 0},
	} {
		routes, ok := ParseFocusRoutes([]byte(c.payload))
		if ok != c.ok || len(routes) != c.count {
			t.Errorf("%s: routes=%v ok=%v, want ok=%v count=%d", c.payload, routes, ok, c.ok, c.count)
		}
	}
}

// The node multiplexer advertises node_focus_v1, and a Focus frame (valid or
// not) neither answers nor closes the connection: the heartbeat still echoes.
func TestNodeMultiplexAcceptsFocusFrames(t *testing.T) {
	client, serverConnection := net.Pipe()
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(3 * time.Second))
	server := NewServer()
	go server.serveConnection(serverConnection)

	writer := protocol.NewWriter(client)
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{Version: 1, NodeMux: true})
	if err := writer.Write(hello); err != nil {
		t.Fatal(err)
	}
	ready, err := protocol.ReadFrame(client)
	if err != nil {
		t.Fatal(err)
	}
	var status protocol.StatusPayload
	if protocol.DecodeJSON(ready, &status) != nil || !containsCapability(status.Capabilities, "node_focus_v1") {
		t.Fatalf("node multiplexer did not advertise focus: %#v", status.Capabilities)
	}
	for i, payload := range []string{`{"routes":["0123456789abcdef0123"]}`, `{"routes":["bad/route"]}`, `{"routes":[]}`} {
		if err := writer.Write(protocol.Frame{Type: protocol.Focus, Payload: []byte(payload)}); err != nil {
			t.Fatal(err)
		}
		beat := []byte("after-focus-" + strings.Repeat("x", i))
		if err := writer.Write(protocol.Frame{Type: protocol.Ping, Payload: beat}); err != nil {
			t.Fatal(err)
		}
		pong, err := protocol.ReadFrame(client)
		if err != nil || pong.Type != protocol.Pong || string(pong.Payload) != string(beat) {
			t.Fatalf("focus frame %d disturbed the connection: %#v %v", i, pong, err)
		}
	}
}
