package daemon

import (
	"context"
	"errors"
	"path/filepath"
	"sync"

	"github.com/relay-terminal/relayd/internal/rotationtext"
)

// The Go controller's text_backend calls: health validation and the budgeted
// Haiku journal, served in process by rotationtext over the Go ledger
// (rotation-text/ledger.log). Native pane probes run in Go
// (host_pane_health_maintenance.go). No Python co-process remains.

const paneHealthBackendReplyLimit = 4 << 20

// paneHealthTextBackend is one text journal per controller operation, as the
// former co-process opened one TextJournal for its lifetime. Calls exchange
// the co-process's JSON so values decode exactly as its replies did.
type paneHealthTextBackend struct {
	ctx    context.Context
	mutex  sync.Mutex
	text   *rotationtext.HealthText
	failed error
}

var errPaneHealthBackendLost = errors.New("pane health text backend unavailable")

func startPaneHealthTextBackend(ctx context.Context, workerDirectory string) (*paneHealthTextBackend, error) {
	text, err := rotationtext.OpenHealthText(ctx, filepath.Join(workerDirectory, "rotation-text"))
	if err != nil {
		return nil, err
	}
	return &paneHealthTextBackend{ctx: ctx, text: text}, nil
}

func (b *paneHealthTextBackend) call(operation string, args *pyObject) (value any, err error) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	if b.failed == nil && b.ctx.Err() != nil {
		// The former co-process exited on a SIGTERM between calls.
		b.failed = errPaneHealthBackendLost
	}
	if b.failed != nil {
		return nil, b.failed
	}
	defer func() {
		if recover() != nil {
			b.failed = errPaneHealthBackendLost
			value, err = nil, b.failed
		}
	}()
	reply, err := b.text.Call(b.ctx, operation, pyEncode(args, pyDumpsSortedASCII))
	var coded *rotationtext.HealthTextError
	if errors.As(err, &coded) {
		return nil, &paneHealthBackendError{code: coded.Code}
	}
	if err == nil && len(reply)+1 <= paneHealthBackendReplyLimit {
		value, err = pyDecode(reply)
	} else if err == nil {
		err = errors.New("host health reply exceeds limit")
	}
	if err != nil {
		b.failed = errPaneHealthBackendLost
		return nil, b.failed
	}
	return value, nil
}

func (b *paneHealthTextBackend) ValidatePanes(hostID, snapshotID, panes any) (any, error) {
	return b.call("validate_panes", pyObj("host_id", hostID, "snapshot_id", snapshotID, "panes", panes))
}

func (b *paneHealthTextBackend) ValidateMessages(messages, hostID, panes any) (any, error) {
	return b.call("validate_messages", pyObj("messages", messages, "host_id", hostID, "panes", panes))
}

func (b *paneHealthTextBackend) ValidateCalls(content, latest any) (any, error) {
	return b.call("validate_calls", pyObj("content", content, "latest", latest))
}

func (b *paneHealthTextBackend) Assess(request *pyObject) (any, error) {
	return b.call("assess", pyObj("request", request))
}

func (b *paneHealthTextBackend) Status(operationID any) (any, error) {
	return b.call("status", pyObj("operation_id", operationID))
}

// Close closes the journal.
func (b *paneHealthTextBackend) Close() {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	_ = b.text.Close()
}

// paneHealthNoBackend serves operations that never needed a backend
// (configure, check, status); any call fails like an unavailable backend.
type paneHealthNoBackend struct{}

func (paneHealthNoBackend) Probe(string) (any, error) { return nil, errPaneHealthBackendLost }
func (paneHealthNoBackend) ValidatePanes(any, any, any) (any, error) {
	return nil, errPaneHealthBackendLost
}
func (paneHealthNoBackend) ValidateMessages(any, any, any) (any, error) {
	return nil, errPaneHealthBackendLost
}
func (paneHealthNoBackend) ValidateCalls(any, any) (any, error) { return nil, errPaneHealthBackendLost }
func (paneHealthNoBackend) Assess(*pyObject) (any, error)       { return nil, errPaneHealthBackendLost }
func (paneHealthNoBackend) Status(any) (any, error)             { return nil, errPaneHealthBackendLost }

// paneHealthNativeBackend probes panes in-process and opens the text journal
// only for the first text_backend call of its operation. A tick that never
// assesses therefore never opens (or imports) the ledger.
type paneHealthNativeBackend struct {
	ctx              context.Context
	root, executable string
	probe            func(ctx context.Context, pane, executable string) *pyObject
	startText        func(ctx context.Context, root string) (*paneHealthTextBackend, error)
	// textMutex makes the lazy start single: one operation never opens two
	// journals.
	textMutex       sync.Mutex
	text            *paneHealthTextBackend
	textUnavailable bool
}

func newPaneHealthNativeBackend(ctx context.Context, root, executable string) *paneHealthNativeBackend {
	return &paneHealthNativeBackend{ctx: ctx, root: root, executable: executable,
		probe: func(ctx context.Context, pane, executable string) *pyObject {
			return newPHReader(ctx).probe(pane, executable)
		},
		startText: startPaneHealthTextBackend}
}

// Probe returns the proof exactly as the former backend's JSON reply decoded:
// a failure outside the probe's own handlers is an uncoded backend error, and
// a cancelled operation loses the backend instead of publishing a partial,
// unverified observation.
func (b *paneHealthNativeBackend) Probe(pane string) (value any, err error) {
	if b.ctx.Err() != nil {
		return nil, errPaneHealthBackendLost
	}
	defer func() {
		if recover() != nil {
			value, err = nil, &paneHealthBackendError{}
		}
		if b.ctx.Err() != nil {
			value, err = nil, errPaneHealthBackendLost
		}
	}()
	reply := pyEncode(b.probe(b.ctx, pane, b.executable), pyEncodeOptions{itemSep: ", ", keySep: ": "})
	if len(reply)+1 > paneHealthBackendReplyLimit {
		return nil, errPaneHealthBackendLost
	}
	if value, err = pyDecode(reply); err != nil {
		return nil, errPaneHealthBackendLost
	}
	return value, nil
}

func (b *paneHealthNativeBackend) textBackend() (*paneHealthTextBackend, error) {
	b.textMutex.Lock()
	defer b.textMutex.Unlock()
	if b.text == nil && !b.textUnavailable {
		text, err := b.startText(b.ctx, b.root)
		if err != nil {
			b.textUnavailable = true
		} else {
			b.text = text
		}
	}
	if b.text == nil {
		return nil, errPaneHealthBackendLost
	}
	return b.text, nil
}

func (b *paneHealthNativeBackend) ValidatePanes(hostID, snapshotID, panes any) (any, error) {
	text, err := b.textBackend()
	if err != nil {
		return nil, err
	}
	return text.ValidatePanes(hostID, snapshotID, panes)
}

func (b *paneHealthNativeBackend) ValidateMessages(messages, hostID, panes any) (any, error) {
	text, err := b.textBackend()
	if err != nil {
		return nil, err
	}
	return text.ValidateMessages(messages, hostID, panes)
}

func (b *paneHealthNativeBackend) ValidateCalls(content, latest any) (any, error) {
	text, err := b.textBackend()
	if err != nil {
		return nil, err
	}
	return text.ValidateCalls(content, latest)
}

func (b *paneHealthNativeBackend) Assess(request *pyObject) (any, error) {
	text, err := b.textBackend()
	if err != nil {
		return nil, err
	}
	return text.Assess(request)
}

func (b *paneHealthNativeBackend) Status(operationID any) (any, error) {
	text, err := b.textBackend()
	if err != nil {
		return nil, err
	}
	return text.Status(operationID)
}

// Close closes the text journal, if one was opened.
func (b *paneHealthNativeBackend) Close() {
	b.textMutex.Lock()
	defer b.textMutex.Unlock()
	if b.text != nil {
		b.text.Close()
	}
}
