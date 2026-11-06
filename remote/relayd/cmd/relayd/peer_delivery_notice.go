package main

import (
	"net"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// sendPeerDeliveryNotice writes one content-free agent event to a pane's
// session over the supervisor's event-only socket, as a provider hook does.
func sendPeerDeliveryNotice(pane string, payload []byte) error {
	connection, err := net.DialTimeout("unix", defaultSocket(), 2*time.Second)
	if err != nil {
		return err
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(2 * time.Second))
	writer := protocol.NewWriter(connection)
	hello, err := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{Version: 1, SessionID: pane, EventOnly: true})
	if err != nil {
		return err
	}
	if err := writer.Write(hello); err != nil {
		return err
	}
	return writer.Write(protocol.Frame{Type: protocol.AgentEvent, Payload: payload})
}
