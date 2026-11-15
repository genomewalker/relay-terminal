package loopbackproxy

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// RelayNode adds ephemeral, bounded loopback RPC to the new node client. Other
// frames continue to the retained supervisor unchanged. No host job, file or
// terminal command carries HTTP bytes; disconnect closes only owned sockets.
type HostRequestHandler func(context.Context, []byte) ([]byte, error)

// ErrClientSilent ends a node whose app stopped sending anything. The app
// heartbeats every 2 s and abandons a link after about 12 s of silence, then
// reconnects with a new node. When that link died without a FIN (a VPN or
// Wi-Fi change), sshd never noticed, and the orphaned node kept its pane
// attachments: every pane then reported a second viewer and Relay refused to
// restart or move it.
var ErrClientSilent = errors.New("relay app stopped sending heartbeats")

// Variables only so tests can shorten them.
var (
	nodeClientSilence = time.Minute
	nodeSilenceCheck  = 5 * time.Second
	nodeClock         = time.Now
)

// watchClientSilence arms once the client has sent a heartbeat Ping, so a
// client that never heartbeats is never cut off.
func watchClientSilence(ctx context.Context, last *atomic.Int64, armed <-chan struct{}, completed chan<- error) {
	select {
	case <-armed:
	case <-ctx.Done():
		return
	}
	ticker := time.NewTicker(nodeSilenceCheck)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if nodeClock().Sub(time.Unix(0, last.Load())) >= nodeClientSilence {
				select {
				case completed <- ErrClientSilent:
				default:
				}
				return
			}
		}
	}
}

func RelayNode(ctx context.Context, input io.Reader, output io.Writer, upstream net.Conn) error {
	return RelayNodeWithHostRequestHandler(ctx, input, output, upstream, nil)
}

// RelayNodeWithHostRequestHandler retains the same terminal and ordinary RPC
// streams, with an ephemeral worker control route owned by the new node client.
func RelayNodeWithHostRequestHandler(ctx context.Context, input io.Reader, output io.Writer, upstream net.Conn,
	hostRotation HostRequestHandler) error {
	return RelayNodeWithHostRequestHandlers(ctx, input, output, upstream, hostRotation, nil)
}

// Account settings use the authenticated host connection, independently of
// terminal sessions. All ephemeral routes share the bounded dispatcher.
func RelayNodeWithHostRequestHandlers(ctx context.Context, input io.Reader, output io.Writer, upstream net.Conn,
	hostRotation, hostAccounts HostRequestHandler) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	defer upstream.Close()
	if closer, ok := input.(io.Closer); ok {
		defer closer.Close()
	}
	manager := NewManager(ctx)
	defer manager.Close()
	clientReader := protocol.NewFragmentReader(input)
	upstreamReader := protocol.NewFragmentReader(upstream)
	upstreamWriter := protocol.NewScheduledWriter(upstream)
	stats := newNodeStats(time.Now)
	clientWriter := protocol.NewScheduledWriter(timedWriter{out: output, stats: stats})
	measuring := make(chan struct{})
	var startMeasuring sync.Once
	statsDone := make(chan struct{})
	go func() {
		defer close(statsDone)
		runNodeStats(ctx, stats, clientWriter, upstreamWriter, measuring)
	}()
	// The node process exits as soon as this returns (stdin EOF included), so
	// wait for the stats loop to remove its snapshot file first.
	defer func() {
		cancel()
		<-statsDone
	}()
	var negotiated atomic.Bool
	var upstreamFragments atomic.Bool
	completed := make(chan error, 3)
	slots := make(chan struct{}, 64)
	var lastClientFrame atomic.Int64
	heartbeats := make(chan struct{})
	var startWatchdog sync.Once
	go watchClientSilence(ctx, &lastClientFrame, heartbeats, completed)
	go func() {
		for {
			frame, err := clientReader.Read()
			if err != nil {
				completed <- err
				return
			}
			lastClientFrame.Store(nodeClock().UnixNano())
			if frame.Type == protocol.Ping {
				startWatchdog.Do(func() { close(heartbeats) })
			}
			startMeasuring.Do(func() { close(measuring) })
			if frame.Type == protocol.Pong && stats.pong(frame.Payload) {
				continue
			}
			if frame.Type == protocol.Capabilities {
				var capabilities struct {
					WireFragments bool `json:"wire_fragments"`
					NodePingEcho  bool `json:"node_ping_echo"`
				}
				if json.Unmarshal(frame.Payload, &capabilities) == nil && capabilities.NodePingEcho {
					stats.enableRTT()
				}
				if json.Unmarshal(frame.Payload, &capabilities) == nil && capabilities.WireFragments {
					clientReader.Enabled = true
					clientWriter.EnableFragments()
					negotiated.Store(true)
				}
			}
			if frame.Type == protocol.HostRequest {
				var head struct {
					Operation string `json:"operation"`
					RequestID string `json:"request_id"`
				}
				parsed := json.Unmarshal(frame.Payload, &head) == nil
				isLoopback := parsed && len(head.Operation) >= 9 && head.Operation[:9] == "loopback_"
				isHostRotation := parsed && head.Operation == "host_rotation" && hostRotation != nil
				isHostAccounts := parsed && head.Operation == "host_accounts" && hostAccounts != nil
				if isLoopback || isHostRotation || isHostAccounts {
					select {
					case slots <- struct{}{}:
					default:
						message := "loopback RPC capacity reached"
						if isHostRotation {
							message = "host rotation RPC capacity reached"
						}
						if isHostAccounts {
							message = "host account RPC capacity reached"
						}
						answer, _ := protocol.JSONFrame(protocol.HostResponse, map[string]any{
							"request_id": head.RequestID, "error": message, "result": nil})
						if err := clientWriter.Write(answer); err != nil {
							completed <- err
							return
						}
						continue
					}
					go func(payload []byte) {
						defer func() { <-slots }()
						var response []byte
						if isHostRotation || isHostAccounts {
							var err error
							handler := hostRotation
							if isHostAccounts {
								handler = hostAccounts
							}
							response, err = handler(ctx, payload)
							if err != nil {
								response, _ = json.Marshal(map[string]any{
									"request_id": head.RequestID, "error": err.Error(), "result": nil})
							}
						} else {
							_, response = manager.Handle(payload)
						}
						if clientWriter.Write(protocol.Frame{Type: protocol.HostResponse, Payload: response}) != nil {
							cancel()
							upstream.Close()
						}
					}(frame.Payload)
					continue
				}
			}
			if frame.Type == protocol.Capabilities && !upstreamFragments.Load() {
				continue
			}
			if err := upstreamWriter.Write(frame); err != nil {
				completed <- err
				return
			}
			if frame.Type == protocol.Capabilities && negotiated.Load() {
				upstreamWriter.EnableFragments()
			}
		}
	}()
	go func() {
		for {
			// Accept backend fragments once its own ready status advertises
			// support. No other goroutine mutates this reader's state.
			frame, err := upstreamReader.Read()
			if err != nil {
				completed <- err
				return
			}
			if frame.Type == protocol.Status {
				var status map[string]json.RawMessage
				if json.Unmarshal(frame.Payload, &status) == nil && string(status["state"]) == `"ready"` {
					var caps []string
					_ = json.Unmarshal(status["capabilities"], &caps)
					hasFragments := false
					for _, cap := range caps {
						if cap == "wire_fragments_v1" {
							hasFragments = true
						}
					}
					upstreamFragments.Store(hasFragments)
					upstreamReader.Enabled = hasFragments
					if !hasFragments {
						caps = append(caps, "wire_fragments_v1")
					}
					caps = append(caps, "loopback_stream_v1")
					if hostRotation != nil {
						caps = append(caps, "host_rotation_client_v1")
					}
					if hostAccounts != nil {
						caps = append(caps, "host_accounts_v1")
						caps = append(caps, "pane_health_tools_v1")
						caps = append(caps, "relay_assistant_v1")
					}
					status["capabilities"], _ = json.Marshal(caps)
					if encoded, err := json.Marshal(status); err == nil {
						frame.Payload = encoded
					}
				}
			}
			if err := clientWriter.Write(frame); err != nil {
				completed <- err
				return
			}
		}
	}()
	select {
	case err := <-completed:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}
