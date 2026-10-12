package daemon

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

// RunNativeRotationBridge is a pipe adapter launched by the native TUI itself.
// It never attaches an input controller, creates a worker, or submits terminal input.
func RunNativeRotationBridge(pane string, input io.Reader, output io.Writer) error {
	if !validSessionID.MatchString(pane) {
		return errors.New("invalid native rotation pane")
	}
	server := NewServer()
	manifest, err := loadManifest(server.manifestPath(pane))
	if err != nil || manifest.SessionID != pane || validateWorkerIdentity(manifest) != nil {
		return errors.New("native rotation worker unavailable")
	}
	connection, err := net.DialTimeout("unix", manifest.SocketPath, time.Second)
	if err != nil {
		return err
	}
	defer connection.Close()
	uid, pid, err := PeerCredentials(connection)
	if err != nil || uid != os.Getuid() || pid != manifest.WorkerPID {
		return errors.New("native rotation worker changed")
	}
	_ = connection.SetDeadline(time.Now().Add(5 * time.Second))
	writer := protocol.NewWriter(connection)
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{Version: workerProtocolVersion,
		SessionID: pane, WorkerToken: manifest.Token, Probe: true, NativeRotationBridge: true})
	if writer.Write(hello) != nil {
		return errors.New("native rotation handshake unavailable")
	}
	ready, err := protocol.ReadFrame(connection)
	var state struct {
		Version int    `json:"v"`
		State   string `json:"state"`
	}
	if err != nil || ready.Type != protocol.Status || json.Unmarshal(ready.Payload, &state) != nil ||
		state.Version != 1 || state.State != "native_rotation_ready" {
		return errors.New("native rotation bridge unavailable")
	}
	_ = connection.SetDeadline(time.Time{})
	if _, err := io.WriteString(output, "{\"v\":1,\"ready\":true}\n"); err != nil {
		return err
	}
	return forwardNativeRotationBridge(connection, writer, input, output)
}

func forwardNativeRotationBridge(connection net.Conn, writer *protocol.Writer, input io.Reader, output io.Writer) error {
	done := make(chan struct{})
	defer close(done)
	go func() {
		defer connection.Close()
		reader := bufio.NewReaderSize(input, nativeRotationWireLimit)
		for {
			line, err := reader.ReadSlice('\n')
			if err != nil || len(line) == 0 || len(line) > nativeRotationWireLimit {
				return
			}
			raw := line[:len(line)-1]
			if !rotationSourceJSONUnambiguous(raw) {
				return
			}
			select {
			case <-done:
				return
			default:
			}
			if writer.Write(protocol.Frame{Type: protocol.HostResponse, Payload: append([]byte(nil), raw...)}) != nil {
				return
			}
		}
	}()
	for {
		frame, err := protocol.ReadFrame(connection)
		if err != nil {
			return err
		}
		if frame.Type != protocol.HostRequest || len(frame.Payload)+1 > nativeRotationWireLimit ||
			!rotationSourceJSONUnambiguous(frame.Payload) {
			return errors.New("invalid native rotation command")
		}
		if _, err := output.Write(append(frame.Payload, '\n')); err != nil {
			return err
		}
	}
}
