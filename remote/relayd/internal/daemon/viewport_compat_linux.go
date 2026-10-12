//go:build linux

package daemon

import (
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/creack/pty"
	"github.com/relay-terminal/relayd/internal/protocol"
)

const legacyRepaintHardDeadline = 750 * time.Millisecond
const legacyRepaintQuietPeriod = 20 * time.Millisecond

type legacyRepaintObserver struct {
	connection net.Conn
	writer     *protocol.Writer
	sequence   uint64
}

func openLegacyRepaintObserver(manifest workerManifest, clientID string) (*legacyRepaintObserver, error) {
	if clientID == "" {
		return nil, errors.New("legacy repaint requires the requesting client identity")
	}
	connection, err := net.DialTimeout("unix", manifest.SocketPath, time.Second)
	if err != nil {
		return nil, err
	}
	observer := &legacyRepaintObserver{
		connection: connection,
		writer:     protocol.NewWriter(connection),
		sequence:   manifest.LastSequence,
	}
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{
		Version: workerProtocolVersion, SessionID: manifest.SessionID,
		LastSeq: manifest.LastSequence, TerminalOnly: true,
		WorkerToken: manifest.Token,
		// Old workers retain the input lease after Detach. Use the requesting
		// terminal's identity so this short-lived helper cannot lock it out.
		ClientID: clientID,
	})
	if err := observer.writer.Write(hello); err != nil {
		connection.Close()
		return nil, err
	}
	if err := connection.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		connection.Close()
		return nil, err
	}
	for {
		frame, readErr := protocol.ReadFrame(connection)
		if readErr != nil {
			connection.Close()
			return nil, readErr
		}
		if sequence, _, parseErr := protocol.ParseOutput(frame); parseErr == nil {
			if sequence > observer.sequence {
				observer.sequence = sequence
			}
			continue
		}
		if frame.Type != protocol.Status {
			continue
		}
		var status protocol.StatusPayload
		if protocol.DecodeJSON(frame, &status) == nil && status.State == "caught_up" {
			_ = connection.SetReadDeadline(time.Time{})
			return observer, nil
		}
	}
}

func (observer *legacyRepaintObserver) close() {
	_ = observer.connection.SetDeadline(time.Time{})
	if observer.writer.Write(protocol.Frame{Type: protocol.Detach}) == nil {
		// The worker releases its input lease before closing the socket. Wait
		// briefly for EOF so a handoff to another viewer cannot race that
		// release; a stalled old worker remains bounded by this deadline.
		if unix, ok := observer.connection.(*net.UnixConn); ok {
			_ = unix.CloseWrite()
		}
		_ = observer.connection.SetReadDeadline(time.Now().Add(150 * time.Millisecond))
		for {
			if _, err := protocol.ReadFrame(observer.connection); err != nil {
				break
			}
		}
	}
	_ = observer.connection.Close()
}

// waitForOutput is an event-driven presentation barrier. It returns only after
// the worker has published post-resize output and that burst has gone quiet,
// or after a bounded deadline for a continuously updating TUI. This replaces
// fixed sleeps that could acknowledge before a loaded node scheduled redraw.
func (observer *legacyRepaintObserver) waitForOutput(after uint64) (uint64, error) {
	return observer.waitForOutputUntil(after, legacyRepaintHardDeadline, legacyRepaintQuietPeriod)
}

func (observer *legacyRepaintObserver) waitForOutputUntil(
	after uint64,
	hardTimeout, quietPeriod time.Duration,
) (uint64, error) {
	hardDeadline := time.Now().Add(hardTimeout)
	lastSequence := after
	var quietDeadline time.Time
	for {
		deadline := hardDeadline
		if !quietDeadline.IsZero() && quietDeadline.Before(deadline) {
			deadline = quietDeadline
		}
		if err := observer.connection.SetReadDeadline(deadline); err != nil {
			return lastSequence, err
		}
		frame, err := protocol.ReadFrame(observer.connection)
		if err != nil {
			var netErr net.Error
			if errors.As(err, &netErr) && netErr.Timeout() && lastSequence > after {
				observer.sequence = lastSequence
				return lastSequence, nil
			}
			return lastSequence, err
		}
		sequence, _, parseErr := protocol.ParseOutput(frame)
		if parseErr != nil || sequence <= after {
			continue
		}
		if sequence > lastSequence {
			lastSequence = sequence
		}
		quietDeadline = time.Now().Add(quietPeriod)
	}
}

func openLegacyTerminal(manifest workerManifest) (*os.File, error) {
	if err := validateWorkerIdentity(manifest); err != nil {
		return nil, err
	}
	return os.OpenFile(
		fmt.Sprintf("/proc/%d/fd/0", manifest.ShellPID),
		os.O_RDWR|syscall.O_NOCTTY,
		0,
	)
}

// A retained worker must repaint on the renderer's actual grid. The same
// validated terminal and input-lease fence used by viewport commits can signal
// an unchanged grid without emitting output for a temporary row count.
func pulseLegacyWorkerViewport(manifest workerManifest, cols, rows uint16, clientID string) error {
	_, err := commitLegacyWorkerViewport(manifest, cols, rows, clientID)
	return err
}

// commitLegacyWorkerViewport applies a final grid to a durable worker that
// predates viewport_commit_v2 and returns the sequence of its observed redraw.
func commitLegacyWorkerViewport(manifest workerManifest, cols, rows uint16, clientID string) (uint64, error) {
	if cols == 0 || rows == 0 {
		return 0, fmt.Errorf("invalid legacy viewport %dx%d", cols, rows)
	}
	observer, err := openLegacyRepaintObserver(manifest, clientID)
	if err != nil {
		return 0, err
	}
	defer observer.close()
	terminal, err := openLegacyTerminal(manifest)
	if err != nil {
		return 0, err
	}
	defer terminal.Close()
	current, currentErr := pty.GetsizeFull(terminal)
	knownCurrent := currentErr == nil && current != nil
	currentCols, currentRows := uint16(0), uint16(0)
	if knownCurrent {
		currentCols, currentRows = current.Cols, current.Rows
	}
	if err := pty.Setsize(terminal, &pty.Winsize{Cols: cols, Rows: rows}); err != nil {
		return 0, err
	}
	if viewportResizeNeedsExplicitSignal(currentCols, currentRows, cols, rows, knownCurrent) {
		processGroup, groupErr := foregroundProcessGroupFromProc(manifest.ShellPID)
		if groupErr != nil {
			return 0, groupErr
		}
		if processGroup > 0 {
			if killErr := syscall.Kill(-processGroup, syscall.SIGWINCH); killErr != nil && killErr != syscall.ESRCH {
				return 0, killErr
			}
		}
	}
	return observer.waitForOutput(observer.sequence)
}

func foregroundProcessGroupFromProc(pid int) (int, error) {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return 0, err
	}
	return parseForegroundProcessGroup(string(data))
}

func parseForegroundProcessGroup(stat string) (int, error) {
	closing := strings.LastIndexByte(stat, ')')
	if closing < 0 || closing+1 >= len(stat) {
		return 0, fmt.Errorf("invalid proc stat")
	}
	fields := strings.Fields(stat[closing+1:])
	if len(fields) <= 5 {
		return 0, fmt.Errorf("incomplete proc stat")
	}
	processGroup, err := strconv.Atoi(fields[5])
	if err != nil {
		return 0, fmt.Errorf("invalid proc tpgid: %w", err)
	}
	return processGroup, nil
}
