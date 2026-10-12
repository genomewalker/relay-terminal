package daemon

import (
	"bytes"
	"encoding/json"
	"github.com/relay-terminal/relayd/internal/programstatus"
	"github.com/relay-terminal/relayd/internal/protocol"
	"io"
	"net"
	"os"
	"testing"
	"time"
)

func TestSessionProgramStatusCollectsFreshOutputWithoutInputAuthority(t *testing.T) {
	session := &Session{clients: make(map[*client]struct{}), agentClients: make(map[*client]struct{}), terminalModes: newTerminalModeState()}
	chunks := [][]byte{[]byte("\x1b]7501;id=build:state=working:progress=04"), []byte("2\x07")}
	for _, chunk := range chunks {
		session.publish(chunk)
	}
	records := session.programStatusSnapshot()
	if len(records) != 1 || records[0].ID != "build" || records[0].State != "working" || records[0].Progress == nil || *records[0].Progress != 42 {
		t.Fatalf("fresh fragmented report not collected: %+v", records)
	}
	if session.controlClientID != "" || session.controlConnections != 0 || len(session.agentProcesses) != 0 || len(session.latestAgentEvent) != 0 || len(session.inputSequences) != 0 {
		t.Fatal("self-reported status acquired native authority")
	}
	if !bytes.Equal(session.replay[0].data, chunks[0]) || !bytes.Equal(session.replay[1].data, chunks[1]) {
		t.Fatal("collector changed original terminal output")
	}
	revision := records[0].Revision
	*records[0].Progress = 99
	records[0].State = "error"
	viewer, _, _, _, _ := session.attach(0, 0, false)
	session.detach(viewer)
	records = session.programStatusSnapshot()
	if records[0].Revision != revision || records[0].State != "working" || *records[0].Progress != 42 {
		t.Fatal("snapshot mutation or replay changed collector state")
	}
	session.publish([]byte("\x1b]7501;?\x07"))
	if session.programStatusSnapshot()[0].Revision != revision || session.controlClientID != "" {
		t.Fatal("detection query mutated status or ownership")
	}
	session.publish([]byte("\x1b]133;A\x07"))
	if len(session.programStatusSnapshot()) != 0 {
		t.Fatal("shell prompt retained running program")
	}
}

func TestSessionProgramStatusResetAndCompletionLifetime(t *testing.T) {
	session := &Session{terminalModes: newTerminalModeState()}
	session.publish([]byte("\x1b]7501;id=build:state=done\x07"))
	session.publish([]byte("\x1b]133;A\x07"))
	if len(session.programStatusSnapshot()) != 1 {
		t.Fatal("prompt removed completed result")
	}
	session.publish([]byte("\x1bc"))
	if len(session.programStatusSnapshot()) != 0 {
		t.Fatal("reset retained program metadata")
	}
}

func programStatusFrames(t *testing.T, frames []protocol.Frame) []protocol.StatusPayload {
	t.Helper()
	var statuses []protocol.StatusPayload
	for _, f := range frames {
		if f.Type != protocol.Status {
			continue
		}
		var status protocol.StatusPayload
		if err := json.Unmarshal(f.Payload, &status); err != nil {
			t.Fatal(err)
		}
		if status.State == "program_status" {
			statuses = append(statuses, status)
		}
	}
	return statuses
}
func drainProgramFrames(viewer *client) []protocol.Frame {
	var frames []protocol.Frame
	for {
		select {
		case f := <-viewer.frames:
			frames = append(frames, f)
		default:
			return frames
		}
	}
}
func TestSessionProgramStatusNegotiatedSnapshots(t *testing.T) {
	session := &Session{clients: make(map[*client]struct{}), agentClients: make(map[*client]struct{}), terminalModes: newTerminalModeState()}
	legacy, replay, _, _, _ := session.attach(0, 0, false)
	defer session.detach(legacy)
	if len(programStatusFrames(t, replay)) != 0 {
		t.Fatal("legacy replay got new status")
	}
	observer, replay, _, _, _ := session.attachWithProgramStatus(0, 0, false, true)
	defer session.detach(observer)
	snapshots := programStatusFrames(t, replay)
	if len(snapshots) != 1 || !snapshots[0].ProgramStatusReplay || snapshots[0].ProgramStatus == nil || len(*snapshots[0].ProgramStatus) != 0 {
		t.Fatal("empty attach did not carry explicit replay snapshot")
	}
	drainProgramFrames(legacy)
	drainProgramFrames(observer)
	session.publish([]byte("\x1b]7501;state=blocked:kind=question\x07"))
	if len(programStatusFrames(t, drainProgramFrames(legacy))) != 0 {
		t.Fatal("legacy viewer got new metadata")
	}
	snapshots = programStatusFrames(t, drainProgramFrames(observer))
	if len(snapshots) != 1 || snapshots[0].ProgramStatusReplay || snapshots[0].ProgramStatusRevision != 1 || len(*snapshots[0].ProgramStatus) != 1 {
		t.Fatal("fresh replacement snapshot missing")
	}
	another, replay, _, _, _ := session.attachWithProgramStatus(session.sequence, 0, false, true)
	defer session.detach(another)
	snapshots = programStatusFrames(t, replay)
	if len(snapshots) != 1 || !snapshots[0].ProgramStatusReplay || snapshots[0].ProgramStatusRevision != 1 {
		t.Fatal("reconnect did not preserve freshness and replay marker")
	}
	session.publish([]byte("\x1bc"))
	snapshots = programStatusFrames(t, drainProgramFrames(observer))
	if len(snapshots) != 1 || snapshots[0].ProgramStatus == nil || len(*snapshots[0].ProgramStatus) != 0 || snapshots[0].ProgramStatusRevision != 2 {
		t.Fatal("clear did not send explicit empty replacement")
	}
	if session.controlClientID != "" || len(session.agentProcesses) != 0 {
		t.Fatal("status observers acquired authority")
	}
}
func TestSessionProgramStatusLaggedViewerReconnects(t *testing.T) {
	session := &Session{clients: make(map[*client]struct{}), terminalModes: newTerminalModeState()}
	viewer := newClient(1)
	viewer.includeProgramStatus = true
	session.clients[viewer] = struct{}{}
	viewer.frames <- protocol.OutputFrame(0, []byte("full"))
	session.publish([]byte("\x1b]7501;state=done\x07"))
	select {
	case <-viewer.lagged:
	default:
		t.Fatal("full observer was left stale")
	}
	if _, ok := session.clients[viewer]; ok {
		t.Fatal("lagged observer still attached")
	}
	if len(session.programStatusSnapshot()) != 1 {
		t.Fatal("backpressure lost authoritative status")
	}
}

func TestSessionProgramStatusFixedDetectionRepliesOnly(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	session := &Session{pty: writer, done: make(chan struct{}), programStatusReplies: make(chan int, 8), clients: make(map[*client]struct{}), terminalModes: newTerminalModeState()}
	go session.writeProgramStatusReplies()
	defer close(session.done)
	session.publish([]byte("\x1b]7501;state=working:msg=aGVsbG8=\x07"))
	if len(session.programStatusReplies) != 0 {
		t.Fatal("metadata caused input")
	}
	session.publish([]byte("\x1b]7501;?"))
	session.publish([]byte("\x07"))
	reader.SetReadDeadline(time.Now().Add(2 * time.Second))
	got := make([]byte, len(programstatus.DetectionReply))
	if _, err := io.ReadFull(reader, got); err != nil {
		t.Fatal(err)
	}
	if string(got) != programstatus.DetectionReply {
		t.Fatalf("unexpected response %q", got)
	}
	if session.controlClientID != "" || session.rotationHumanInputSeen || len(session.inputSequences) != 0 {
		t.Fatal("detection acquired input authority")
	}
	viewer, _, _, _, _ := session.attachWithProgramStatus(0, 0, false, true)
	session.detach(viewer)
	if len(session.programStatusReplies) != 0 {
		t.Fatal("replay queued detection")
	}
}
func TestSessionProgramStatusDetectionQueueBounded(t *testing.T) {
	session := &Session{programStatusReplies: make(chan int, 8)}
	for i := 0; i < 100; i++ {
		session.queueProgramStatusReplies(10000)
	}
	if len(session.programStatusReplies) != 8 {
		t.Fatal("reply queue was unbounded")
	}
	for len(session.programStatusReplies) > 0 {
		if n := <-session.programStatusReplies; n != 32 {
			t.Fatal("reply batch exceeded cap")
		}
	}
}

func TestWorkerProgramStatusPostAttachNegotiationReadOnly(t *testing.T) {
	session := &Session{clients: make(map[*client]struct{}), agentClients: make(map[*client]struct{}), terminalModes: newTerminalModeState(), controlClientID: "human", controlConnections: 1}
	session.publish([]byte("\x1b]7501;id=fixture:state=blocked:kind=question\x07"))
	server, clientConn := net.Pipe()
	defer clientConn.Close()
	_ = clientConn.SetDeadline(time.Now().Add(3 * time.Second))
	config := WorkerConfig{SessionID: "negotiation-fixture", Token: "fixture-secret"}
	go serveWorkerConnection(server, config, session)
	writer := protocol.NewWriter(clientConn)
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{Version: 1, SessionID: config.SessionID, WorkerToken: config.Token, ClientID: "observer", TerminalOnly: true})
	if err := writer.Write(hello); err != nil {
		t.Fatal(err)
	}
	for {
		frame, err := protocol.ReadFrame(clientConn)
		if err != nil {
			t.Fatal(err)
		}
		if frame.Type != protocol.Status {
			continue
		}
		var status protocol.StatusPayload
		if protocol.DecodeJSON(frame, &status) != nil {
			t.Fatal("decode")
		}
		if status.State == "program_status" {
			t.Fatal("unnegotiated status")
		}
		if status.State == "attached" && (status.ControlGranted == nil || *status.ControlGranted || !statusSupportsCapability(status.Capabilities, "program_status_negotiation_v1")) {
			t.Fatal("incorrect authority/capability")
		}
		if status.State == "caught_up" {
			break
		}
	}
	negotiation := protocol.Frame{Type: protocol.Capabilities, Payload: []byte(`{"observe_program_status":true}`)}
	if err := writer.Write(negotiation); err != nil {
		t.Fatal(err)
	}
	readStatus := func() protocol.StatusPayload {
		for {
			frame, err := protocol.ReadFrame(clientConn)
			if err != nil {
				t.Fatal(err)
			}
			if frame.Type != protocol.Status {
				continue
			}
			var status protocol.StatusPayload
			if protocol.DecodeJSON(frame, &status) != nil {
				t.Fatal("decode")
			}
			if status.State == "program_status" {
				return status
			}
		}
	}
	replay := readStatus()
	if !replay.ProgramStatusReplay || replay.ProgramStatus == nil || len(*replay.ProgramStatus) != 1 {
		t.Fatal("missing replay")
	}
	session.publish([]byte("\x1b]7501;id=fixture:state=done\x07"))
	fresh := readStatus()
	if fresh.ProgramStatusReplay || fresh.ProgramStatusRevision <= replay.ProgramStatusRevision || (*fresh.ProgramStatus)[0].State != "done" {
		t.Fatal("missing ordered fresh update")
	}
	session.mu.Lock()
	defer session.mu.Unlock()
	if session.controlClientID != "human" || session.controlConnections != 1 || len(session.inputSequences) != 0 {
		t.Fatal("observation altered input authority")
	}
}

func TestSessionProgramStatusPostAttachIdempotenceAndBounds(t *testing.T) {
	session := &Session{clients: make(map[*client]struct{}), terminalModes: newTerminalModeState()}
	viewer := newClient(1)
	session.clients[viewer] = struct{}{}
	session.setProgramStatusObservation(viewer, true)
	session.setProgramStatusObservation(viewer, true)
	if len(viewer.frames) != 1 {
		t.Fatal("duplicate replay")
	}
	session.setProgramStatusObservation(viewer, false)
	drainProgramFrames(viewer)
	session.publish([]byte("\x1b]7501;state=done\x07"))
	if len(programStatusFrames(t, drainProgramFrames(viewer))) != 0 {
		t.Fatal("disabled observer notified")
	}
	viewer.frames <- protocol.OutputFrame(0, nil)
	session.setProgramStatusObservation(viewer, true)
	select {
	case <-viewer.lagged:
	default:
		t.Fatal("full viewer not retired")
	}
	session.setProgramStatusObservation(viewer, false)
	if !viewer.includeProgramStatus {
		t.Fatal("detached viewer mutated")
	}
}
