package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/protocol"
)

func TestHostRotationRPCRejectsUnknownAndAmbiguousRequests(t *testing.T) {
	for name, raw := range map[string]string{
		"duplicate":                   `{"v":1,"operation":"status","operation":"enroll"}`,
		"unknown":                     `{"v":1,"operation":"status","api_key":"must-not-be-read"}`,
		"trailing":                    `{"v":1,"operation":"status"}{}`,
		"unsupported":                 `{"v":1,"operation":"future_write"}`,
		"unbound_enroll":              `{"v":1,"operation":"enroll","id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}`,
		"candidate_write_fields":      `{"v":1,"operation":"native_candidate","cwd":"/shell"}`,
		"configuration_native_fields": `{"v":1,"operation":"text_configure","id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","text_settings":{},"agent_pid":123}`,
		"abandon_missing_id":          `{"v":1,"operation":"text_abandon"}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := decodeHostRotationRequest([]byte(raw)); err == nil {
				t.Fatal("unbound or ambiguous request accepted")
			}
		})
	}
	for _, raw := range []string{
		`{"v":1,"operation":"status"}`,
		`{"v":1,"operation":"native_candidate"}`,
		`{"v":1,"operation":"disable","id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}`,
		`{"v":1,"operation":"text_status"}`,
		`{"v":1,"operation":"text_status","text_operation_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}`,
		`{"v":1,"operation":"text_configure","id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","text_settings":{"enabled":false}}`,
		`{"v":1,"operation":"text_abandon","text_operation_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}`,
	} {
		if _, err := decodeHostRotationRequest([]byte(raw)); err != nil {
			t.Fatal("supported envelope refused", raw, err)
		}
	}
}

func TestHostRotationTextSettingsDoNotBlockHumanInput(t *testing.T) {
	for _, operation := range []string{"text_configure", "text_abandon"} {
		t.Run(operation, func(t *testing.T) {
			root, err := os.MkdirTemp("/tmp", "relay-text-rpc-")
			if err != nil {
				t.Fatal(err)
			}
			defer os.RemoveAll(root)
			listener, err := net.Listen("unix", filepath.Join(root, "test.sock"))
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			sink, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0)
			if err != nil {
				t.Fatal(err)
			}
			defer sink.Close()
			supervisor := newHostRotationSupervisor(filepath.Join(root, "rotation", "state.json"), func(context.Context, hostRotationEnrollment, time.Time) (json.RawMessage, error) {
				return nil, errors.New("unused")
			})
			defer supervisor.close()
			session := &Session{pty: sink, hostRotation: supervisor}
			if !session.acquireControl("controller") {
				t.Fatal("control unavailable")
			}
			started, release, served := make(chan struct{}), make(chan struct{}), make(chan struct{})
			var once sync.Once
			releaseService := func() { once.Do(func() { close(release) }) }
			defer releaseService()
			services := hostRotationRPCServices{textService: func(context.Context, string, string, any) (json.RawMessage, error) {
				close(started)
				<-release
				return json.RawMessage(`{"v":1,"status":"ready"}`), nil
			}}
			go func() {
				defer close(served)
				c, err := listener.Accept()
				if err != nil {
					return
				}
				defer c.Close()
				frame, err := protocol.ReadFrame(c)
				if err != nil {
					return
				}
				var hello protocol.HelloPayload
				if protocol.DecodeJSON(frame, &hello) != nil {
					return
				}
				serveHostRotationRequestWithServices(c, protocol.NewWriter(c), hello, session, WorkerConfig{SessionID: "fixture-pane"}, services)
			}()
			client, err := net.DialTimeout("unix", listener.Addr().String(), time.Second)
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			_ = client.SetDeadline(time.Now().Add(3 * time.Second))
			request := hostRotationRequest{Version: 1, Operation: operation}
			if operation == "text_configure" {
				request.ID = strings.Repeat("a", 32)
				request.TextSettings = json.RawMessage(`{"enabled":false}`)
			} else {
				request.TextOperationID = strings.Repeat("a", 32)
			}
			raw, _ := json.Marshal(request)
			frame, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{ClientID: "controller", HostRotation: raw})
			if err := protocol.NewWriter(client).Write(frame); err != nil {
				t.Fatal(err)
			}
			select {
			case <-started:
			case <-time.After(time.Second):
				t.Fatal("text service did not start")
			}
			inputDone := make(chan error, 1)
			go func() { inputDone <- session.input([]byte("human draft")) }()
			select {
			case err := <-inputDone:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(time.Second):
				releaseService()
				t.Fatal("saving settings blocked human input")
			}
			releaseService()
			frame, err = protocol.ReadFrame(client)
			if err != nil {
				t.Fatal(err)
			}
			var response struct {
				Status string `json:"status"`
			}
			if protocol.DecodeJSON(frame, &response) != nil || response.Status != "ready" {
				t.Fatal("text configuration response lost")
			}
			<-served
			if session.humanInputRevision != 1 {
				t.Fatal("human input was lost")
			}
		})
	}
}
