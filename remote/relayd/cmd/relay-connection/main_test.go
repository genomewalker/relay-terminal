package main

import (
	"bytes"
	"fmt"
	"github.com/relay-terminal/relayd/internal/protocol"
	"net"
	"os"
	"os/exec"
	"strconv"
	"testing"
	"time"
)

func TestFakeNode(t *testing.T) {
	if os.Getenv("RELAY_BROKER_FIXTURE") != "1" {
		return
	}
	writer := protocol.NewScheduledWriter(os.Stdout)
	ready, _ := protocol.JSONFrame(protocol.Status, protocol.StatusPayload{State: "ready", Capabilities: []string{"node_mux_v2", "wire_fragments_v1"}, Message: strconv.Itoa(os.Getpid())})
	_ = writer.Write(ready)
	reader := protocol.NewFragmentReader(os.Stdin)
	for {
		f, err := reader.Read()
		if err != nil {
			os.Exit(0)
		}
		if f.Type == protocol.Capabilities {
			reader.Enabled = true
			writer.EnableFragments()
			continue
		}
		if f.Type == protocol.HostRequest {
			_ = writer.Write(protocol.Frame{Type: protocol.HostResponse, Payload: f.Payload})
			continue
		}
		if f.Type == protocol.Ping {
			_ = writer.Write(protocol.Frame{Type: protocol.Pong, Payload: f.Payload})
		}
	}
}
func TestFixtureBroker(t *testing.T) {
	if os.Getenv("RELAY_BROKER_FIXTURE") != "1" {
		return
	}
	err := serve(os.Getenv("RELAY_BROKER_SOCKET"), os.Args[0], []string{"-test.run=^TestFakeNode$"})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
	}
	os.Exit(0)
}
func TestBrokerSurvivesViewerExitAndClosesOnRemoteFailure(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "rb-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	socket := dir + "/broker.sock"
	cmd := exec.Command(os.Args[0], "-test.run=^TestFixtureBroker$")
	cmd.Env = append(os.Environ(), "RELAY_BROKER_FIXTURE=1", "RELAY_BROKER_SOCKET="+socket)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer cmd.Process.Kill()
	dial := func() net.Conn {
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			conn, err := net.DialTimeout("unix", socket, 50*time.Millisecond)
			if err == nil {
				_ = conn.SetDeadline(deadline)
				return conn
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatal("broker failed to start")
		return nil
	}
	first := dial()
	ready, err := protocol.ReadFrame(first)
	if err != nil {
		t.Fatal(err)
	}
	var status protocol.StatusPayload
	_ = protocol.DecodeJSON(ready, &status)
	_ = first.Close()
	second := dial()
	defer second.Close()
	reused, err := protocol.ReadFrame(second)
	if err != nil {
		t.Fatal(err)
	}
	var again protocol.StatusPayload
	_ = protocol.DecodeJSON(reused, &again)
	if again.Message != status.Message {
		t.Fatal("remote process recreated between viewers")
	}
	pid, err := strconv.Atoi(status.Message)
	if err != nil {
		t.Fatal(err)
	}
	fake, err := os.FindProcess(pid)
	if err != nil {
		t.Fatal(err)
	}
	_ = fake.Kill()
	if _, err := protocol.ReadFrame(second); err == nil {
		t.Fatal("remote death did not close viewer")
	}
	if err := cmd.Wait(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(socket); !os.IsNotExist(err) {
		t.Fatal("broker left stale socket")
	}
}

func TestBrokerLargeRPCSurvivesViewerFragmentIDReuse(t *testing.T) {
	dir, e := os.MkdirTemp("/tmp", "rb-fragments-")
	if e != nil {
		t.Fatal(e)
	}
	defer os.RemoveAll(dir)
	socket := dir + "/broker.sock"
	cmd := exec.Command(os.Args[0], "-test.run=^TestFixtureBroker$")
	cmd.Env = append(os.Environ(), "RELAY_BROKER_FIXTURE=1", "RELAY_BROKER_SOCKET="+socket)
	if e := cmd.Start(); e != nil {
		t.Fatal(e)
	}
	defer func() { cmd.Process.Kill(); cmd.Wait() }()
	payload := bytes.Repeat([]byte("native-discovery-payload"), 4000)
	var identity string
	for generation := 0; generation < 2; generation++ {
		var conn net.Conn
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			conn, e = net.DialTimeout("unix", socket, 50*time.Millisecond)
			if e == nil {
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
		if e != nil {
			t.Fatal(e)
		}
		conn.SetDeadline(time.Now().Add(5 * time.Second))
		ready, e := protocol.ReadFrame(conn)
		if e != nil {
			t.Fatal(e)
		}
		var status protocol.StatusPayload
		protocol.DecodeJSON(ready, &status)
		if generation > 0 && status.Message != identity {
			t.Fatal("remote was recreated")
		}
		identity = status.Message
		writer := protocol.NewWriter(conn)
		if e := writer.Write(protocol.Frame{Type: protocol.Capabilities, Payload: []byte(`{"wire_fragments":true}`)}); e != nil {
			t.Fatal(e)
		}
		for offset := 0; offset < len(payload); offset += protocol.FragmentChunkBytes {
			end := offset + protocol.FragmentChunkBytes
			if end > len(payload) {
				end = len(payload)
			}
			if e := writer.Write(protocol.FragmentFrame(1, protocol.HostRequest, len(payload), offset, payload[offset:end])); e != nil {
				t.Fatal(e)
			}
		}
		reader := protocol.NewFragmentReader(conn)
		reader.Enabled = true
		for {
			f, e := reader.Read()
			if e != nil {
				t.Fatal(e)
			}
			if f.Type == protocol.HostResponse {
				if !bytes.Equal(f.Payload, payload) {
					t.Fatal("large RPC reply changed")
				}
				break
			}
		}
		conn.Close()
	}
}
