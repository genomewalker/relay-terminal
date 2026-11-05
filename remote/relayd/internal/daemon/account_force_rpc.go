package daemon

import (
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
)

var forceRequestUUID = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// forceAccountRPCRequest is deliberately separate from the generic process
// signal request: a commit carries the exact argv that was shown in the card.
type forceAccountRPCRequest struct {
	ActionID     string             `json:"action_id,omitempty"`
	Target       forceAccountTarget `json:"target"`
	ReviewedArgv []string           `json:"reviewed_argv,omitempty"`
}

type forceAccountRPCBackend struct {
	reserve func(string) error
	preview func(forceAccountTarget) (any, error)
	commit  func(forceAccountTarget, []string) (forceAccountResult, error)
}

// dispatchForceAccountRPC is not wired into hostRPC until the app has an
// immutable, user-reviewed card and enforces both input and terminate grants.
// A reservation is consumed before a commit is attempted, including errors or
// an uncertain response. A caller must never retry with a replacement ID.
func dispatchForceAccountRPC(operation string, request *forceAccountRPCRequest, backend forceAccountRPCBackend) (any, error) {
	if request == nil {
		return nil, errors.New("force request required")
	}
	t := request.Target
	if !validSessionID.MatchString(t.Pane) || t.Session == "" || len(t.Session) > 256 ||
		(t.Provider != "claude" && t.Provider != "codex") || t.ProviderPID <= 1 ||
		t.BlockerPID <= 1 || t.ProviderPID == t.BlockerPID || t.ProviderStart == "" {
		return nil, errors.New("exact provider and distinct blocker identities required")
	}
	switch operation {
	case "account_force_preview":
		if request.ActionID != "" || t.CommandDigest != "" || len(request.ReviewedArgv) != 0 || backend.preview == nil {
			return nil, errors.New("invalid preview request")
		}
		return backend.preview(t)
	case "account_force_commit":
		if t.BlockerStart == "" || !forceRequestUUID.MatchString(request.ActionID) || backend.reserve == nil || backend.commit == nil {
			return nil, errors.New("force commit unavailable")
		}
		if err := forceAccountValidateReviewedArgv(t, request.ReviewedArgv); err != nil {
			return nil, err
		}
		if err := backend.reserve(request.ActionID); err != nil {
			return nil, err
		}
		result, err := backend.commit(t, request.ReviewedArgv)
		if err != nil {
			return nil, err
		}
		return map[string]any{"status": result}, nil
	default:
		return nil, errors.New("unknown force operation")
	}
}

func (s *Server) accountForceRPC(operation string, request *forceAccountRPCRequest) (any, error) {
	if !forceAccountDefaultStateRoot(s) {
		return nil, errors.New("custom host state root unsupported")
	}
	return dispatchForceAccountRPC(operation, request, forceAccountRPCBackend{
		reserve: func(id string) error { return reserveForceRequest(s.stateDir, id) },
		preview: func(t forceAccountTarget) (any, error) { return accountForcePreviewPlatform(s, t) },
		commit: func(t forceAccountTarget, argv []string) (forceAccountResult, error) {
			return accountForceCommitPlatform(s, t, argv)
		},
	})
}

// reserveForceRequest is a durable, single-use tombstone; it is created and
// synced before signaling and never removed by this feature. Duplicate IDs are
// rejected, including after an uncertain result or daemon restart.
func reserveForceRequest(stateDir, requestID string) error {
	if !forceRequestUUID.MatchString(requestID) {
		return errors.New("valid request_id required")
	}
	requestID = strings.ToLower(requestID)
	dir := filepath.Join(stateDir, "account-force-requests")
	if err := durableDirectory(dir); err != nil {
		return err
	}
	if err := EnsurePrivateRuntimeDir(dir); err != nil {
		return err
	}
	f, err := OpenPrivateFile(filepath.Join(dir, requestID), syscall.O_CREAT|syscall.O_EXCL|syscall.O_WRONLY)
	if err != nil {
		return errors.New("request already reserved or reservation unavailable")
	}
	if _, err = f.WriteString("reserved\n"); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	err = d.Sync()
	closeErr = d.Close()
	if err == nil {
		err = closeErr
	}
	return err
}
