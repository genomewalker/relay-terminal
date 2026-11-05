package daemon

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/net/websocket"

	"github.com/relay-terminal/relayd/internal/agentlaunch"
)

const stockCodexProxySource = "stock_app_server_proxy"

var errNoStockCodexProxy = errors.New("no stock Codex proxy")

// CodexProxyOptions attaches one stock CLI to an existing App Server. It does
// not start a provider, change its binary, submit a turn, or replace its socket.
type CodexProxyOptions struct {
	Pane              string
	Session           string
	BackendSocket     string
	BackendPID        int
	BackendStart      uint64
	TrackPrimary      bool
	ExitWithFrontend  bool
	ResumePermissions *agentlaunch.CodexPermissions
}

type StockCodexProxyProof struct {
	ProxyPID      int    `json:"proxy_pid"`
	ProxyStart    uint64 `json:"proxy_start"`
	ControlSocket string `json:"control_socket"`
	ControlDevice uint64 `json:"control_device"`
	ControlInode  uint64 `json:"control_inode"`
	Connection    uint64 `json:"connection"`
	Selection     uint64 `json:"selection"`
}

type codexProxyDescriptor struct {
	Version        int                 `json:"version"`
	Pane           string              `json:"pane"`
	Session        string              `json:"session"`
	TrackPrimary   bool                `json:"track_primary,omitempty"`
	ProxyPID       int                 `json:"proxy_pid"`
	ProxyStart     uint64              `json:"proxy_start"`
	WorkerPID      int                 `json:"worker_pid"`
	WorkerStart    uint64              `json:"worker_start"`
	ShellPID       int                 `json:"shell_pid"`
	FrontendSocket string              `json:"frontend_socket"`
	ControlSocket  string              `json:"control_socket"`
	ControlDevice  uint64              `json:"control_device"`
	ControlInode   uint64              `json:"control_inode"`
	Backend        NativeCodexEndpoint `json:"backend"`
}

type codexProxySelection struct {
	trackPrimary        bool
	wanted              string
	session             string
	path                string
	epoch               uint64
	pending             map[string]uint64
	resumeRequests      uint64
	resumeResponses     uint64
	lastFrontendMethod  string
	lastInvalidation    string
	lastFrontendThread  string
	confirmedResume     bool
	confirmedPath       string
	pendingTurns        map[string]codexProxyPendingTurn
	turnReconfirmations uint64
	temporaryRequests   map[string]struct{}
	temporaryThreads    map[string]struct{}
	temporaryConfirmed  uint64
}

type codexProxyPendingTurn struct {
	epoch  uint64
	method string
}

func (s *codexProxySelection) invalidate(reason string) {
	if reason == "connection_changed" {
		s.temporaryRequests, s.temporaryThreads = nil, nil
	}
	if reason == "connection_changed" || reason == "invalid_frontend_rpc" || reason == "invalid_backend_rpc" || reason == "non_text_frame" || reason == "thread/start" || reason == "thread/fork" || reason == "thread/resume" || reason == "temporary_tracking_limit" || reason == "temporary_identity_conflict" {
		s.confirmedResume, s.confirmedPath = false, ""
	}
	s.lastInvalidation = reason
	s.epoch++
	s.session, s.path = "", ""
	s.pending = make(map[string]uint64)
	s.pendingTurns = make(map[string]codexProxyPendingTurn)
}

// Inspect only routing metadata. Frames are never logged, persisted or replayed.
// Any possibly primary thread change invalidates the association immediately.
func (s *codexProxySelection) frontend(data []byte) error {
	var frame struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
		Params struct {
			ThreadID  string `json:"threadId"`
			Ephemeral bool   `json:"ephemeral"`
		} `json:"params"`
	}
	if json.Unmarshal(data, &frame) != nil {
		s.invalidate("invalid_frontend_rpc")
		return errors.New("invalid frontend RPC")
	}
	// Background reads populate the stock CLI agent list; they do not change
	// the primary conversation confirmed by its explicit resume RPC.
	s.lastFrontendMethod = frame.Method
	if frame.Params.ThreadID != "" {
		s.lastFrontendThread = frame.Params.ThreadID
	}
	switch frame.Method {
	case "thread/start", "thread/fork":
		// The same frontend also creates temporary helper conversations. Their
		// replies and turns must never become the pane's research conversation.
		if frame.Params.Ephemeral {
			_, primaryPending := s.pending[string(frame.ID)]
			_, turnPending := s.pendingTurns[string(frame.ID)]
			if !validProxyRPCID(frame.ID) || len(s.temporaryRequests) >= 64 {
				s.invalidate("temporary_tracking_limit")
				return nil
			}
			if primaryPending || turnPending {
				s.invalidate("temporary_identity_conflict")
				return nil
			}
			if s.temporaryRequests == nil {
				s.temporaryRequests = make(map[string]struct{})
			}
			s.temporaryRequests[string(frame.ID)] = struct{}{}
			return nil
		}
		s.invalidate(frame.Method)
		if s.trackPrimary && validProxyRPCID(frame.ID) {
			s.wanted = ""
			s.pending[string(frame.ID)] = s.epoch
		}
	case "thread/resume":
		if _, temporary := s.temporaryThreads[frame.Params.ThreadID]; temporary {
			return nil
		}
		s.invalidate(frame.Method)
		if s.trackPrimary {
			s.wanted = frame.Params.ThreadID
		}
		if frame.Params.ThreadID == s.wanted && validProxyRPCID(frame.ID) {
			s.resumeRequests++
			s.pending[string(frame.ID)] = s.epoch
		}
	case "turn/start", "turn/steer":
		if _, temporary := s.temporaryThreads[frame.Params.ThreadID]; temporary {
			return nil
		}
		if frame.Params.ThreadID != "" && frame.Params.ThreadID != s.session {
			s.invalidate(frame.Method)
			// A later successful turn can reconfirm a previously resumed primary.
			// The request alone and turns for other threads cannot establish identity.
			if frame.Params.ThreadID == s.wanted && s.confirmedResume && validProxyRPCID(frame.ID) {
				s.pendingTurns[string(frame.ID)] = codexProxyPendingTurn{s.epoch, frame.Method}
			}
		}
	case "thread/unsubscribe":
		// The TUI also unsubscribes from background and completed subagent
		// threads. Only releasing the confirmed primary breaks this binding.
		if frame.Params.ThreadID != "" && frame.Params.ThreadID == s.wanted {
			s.invalidate(frame.Method)
		}
	}
	return nil
}

func validProxyRPCID(id json.RawMessage) bool {
	if len(id) == 0 || len(id) > 256 {
		return false
	}
	var value any
	if json.Unmarshal(id, &value) != nil {
		return false
	}
	switch value.(type) {
	case string, float64:
		return true
	}
	return false
}

func (s *codexProxySelection) backend(data []byte) error {
	var frame struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
		Params struct {
			ThreadID string `json:"threadId"`
			Thread   struct {
				ID string `json:"id"`
			} `json:"thread"`
		} `json:"params"`
		Error  json.RawMessage `json:"error"`
		Result json.RawMessage `json:"result"`
	}
	if json.Unmarshal(data, &frame) != nil {
		s.invalidate("invalid_backend_rpc")
		return errors.New("invalid backend RPC")
	}
	if _, temporary := s.temporaryRequests[string(frame.ID)]; temporary {
		delete(s.temporaryRequests, string(frame.ID))
		var result struct {
			Thread struct {
				ID        string `json:"id"`
				Ephemeral bool   `json:"ephemeral"`
			} `json:"thread"`
		}
		if (len(frame.Error) == 0 || string(frame.Error) == "null") && json.Unmarshal(frame.Result, &result) == nil &&
			result.Thread.Ephemeral && validSessionID.MatchString(result.Thread.ID) {
			if result.Thread.ID == s.wanted || len(s.temporaryThreads) >= 64 {
				s.invalidate("temporary_identity_conflict")
				return nil
			}
			if s.temporaryThreads == nil {
				s.temporaryThreads = make(map[string]struct{})
			}
			s.temporaryThreads[result.Thread.ID] = struct{}{}
			s.temporaryConfirmed++
		}
		return nil
	}
	if frame.Method == "thread/closed" || frame.Method == "thread/unloaded" {
		delete(s.temporaryThreads, frame.Params.ThreadID)
	}
	if (frame.Method == "thread/closed" || frame.Method == "thread/unloaded") && frame.Params.ThreadID == s.wanted {
		s.invalidate(frame.Method)
	}
	if pending, ok := s.pendingTurns[string(frame.ID)]; ok {
		delete(s.pendingTurns, string(frame.ID))
		var result struct {
			Turn struct {
				ID string `json:"id"`
			} `json:"turn"`
			TurnID string `json:"turnId"`
		}
		if pending.epoch != s.epoch || !s.confirmedResume ||
			(len(frame.Error) != 0 && string(frame.Error) != "null") || json.Unmarshal(frame.Result, &result) != nil {
			return nil
		}
		if (pending.method == "turn/start" && !validSessionID.MatchString(result.Turn.ID)) ||
			(pending.method == "turn/steer" && !validSessionID.MatchString(result.TurnID)) {
			return nil
		}
		s.session, s.path = s.wanted, s.confirmedPath
		s.turnReconfirmations++
		return nil
	}
	epoch, ok := s.pending[string(frame.ID)]
	if !ok {
		return nil
	}
	delete(s.pending, string(frame.ID))
	var result struct {
		Thread struct {
			ID        string `json:"id"`
			Path      string `json:"path"`
			Ephemeral bool   `json:"ephemeral"`
		} `json:"thread"`
	}
	if epoch != s.epoch || (len(frame.Error) != 0 && string(frame.Error) != "null") || json.Unmarshal(frame.Result, &result) != nil ||
		result.Thread.Ephemeral || !validSessionID.MatchString(result.Thread.ID) || (result.Thread.ID != s.wanted && !(s.trackPrimary && s.wanted == "")) {
		s.invalidate("resume_response_mismatch")
		return nil
	}
	s.resumeResponses++
	s.session, s.path = result.Thread.ID, result.Thread.Path
	if s.trackPrimary {
		s.wanted = result.Thread.ID
	}
	s.confirmedResume, s.confirmedPath = true, result.Thread.Path
	return nil
}

type codexProxyPeer struct {
	uid, pid int
	start    uint64
}
type codexProxyPeerKey struct{}
type codexProxy struct {
	server            *Server
	manifest          workerManifest
	descriptor        codexProxyDescriptor
	mu                sync.Mutex
	active            bool
	auxiliary         *websocket.Conn
	connection        uint64
	frontend          codexProxyPeer
	selection         codexProxySelection
	frontendDone      chan struct{}
	codexHome         string
	resumePermissions *agentlaunch.CodexPermissions
}

func codexProxyDirectory(server *Server, pane string) string {
	return filepath.Join(server.stateDir, "codex-proxies", pane)
}

func codexProxySocketIdentity(path string) (uint64, uint64, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return 0, 0, err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(st.Uid) != os.Getuid() || info.Mode()&os.ModeSocket == 0 || info.Mode().Perm()&0077 != 0 {
		return 0, 0, errors.New("proxy socket is not private")
	}
	if err := privateBindingObject(filepath.Dir(path), true); err != nil {
		return 0, 0, err
	}
	return uint64(st.Dev), st.Ino, nil
}

func codexProxyBackendConnection(ctx context.Context, endpoint NativeCodexEndpoint) (net.Conn, error) {
	dev, ino, err := codexProxySocketIdentity(endpoint.Socket)
	if err != nil || dev != endpoint.Device || ino != endpoint.Inode {
		return nil, errors.New("proxy backend socket changed")
	}
	before, err := processStartTime(endpoint.DaemonPID)
	if err != nil || before != endpoint.DaemonStart {
		return nil, errors.New("proxy backend process changed")
	}
	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", endpoint.Socket)
	if err != nil {
		return nil, err
	}
	uid, pid, e := PeerCredentials(conn)
	after, startErr := processStartTime(endpoint.DaemonPID)
	devAfter, inoAfter, socketErr := codexProxySocketIdentity(endpoint.Socket)
	if e != nil || uid != os.Getuid() || pid != endpoint.DaemonPID || startErr != nil || after != before ||
		socketErr != nil || devAfter != dev || inoAfter != ino {
		conn.Close()
		return nil, errors.New("proxy backend kernel identity changed")
	}
	return conn, nil
}

func codexProxyManifest(server *Server, expected workerManifest) error {
	current, err := loadManifest(server.manifestPath(expected.SessionID))
	if err != nil || current.WorkerPID != expected.WorkerPID || current.WorkerStartTime != expected.WorkerStartTime ||
		current.ShellPID != expected.ShellPID || current.NodeBootID != expected.NodeBootID || validateWorkerIdentity(current) != nil {
		return errors.New("proxy retained worker changed")
	}
	start, err := processStartIdentity(current.ShellPID)
	if err != nil {
		return errors.New("proxy shell unavailable")
	}
	chain, err := networkAncestors(current.ShellPID, start)
	if err != nil {
		return errors.New("proxy shell ancestry unavailable")
	}
	for _, pid := range chain {
		if pid == current.WorkerPID {
			return nil
		}
	}
	return errors.New("proxy shell left retained worker")
}

func (p *codexProxy) verifyFrontend(peer codexProxyPeer) error {
	if peer.uid != os.Getuid() || peer.pid <= 1 || peer.start == 0 {
		return errors.New("proxy frontend credentials unavailable")
	}
	if err := codexProxyManifest(p.server, p.manifest); err != nil {
		return err
	}
	start, err := NativeAgentIncarnation(p.descriptor.Pane, peer.pid, "codex")
	if err != nil || start != peer.start {
		return errors.New("proxy frontend incarnation changed")
	}
	provider, pid := nativeBindingFrontend(p.manifest.ShellPID)
	if provider != "codex" || pid != peer.pid {
		return errors.New("proxy peer is not the original Codex frontend")
	}
	return nil
}

func (p *codexProxy) binding() (AgentBindingRecord, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	var empty AgentBindingRecord
	if !p.active || (!p.descriptor.TrackPrimary && p.selection.session != p.descriptor.Session) || p.selection.session == "" {
		return empty, errors.New("stock Codex has no verified current session")
	}
	if err := p.verifyFrontend(p.frontend); err != nil {
		return empty, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	conn, err := codexProxyBackendConnection(ctx, p.descriptor.Backend)
	if err != nil {
		return empty, err
	}
	conn.Close()
	path := p.selection.path
	if path != "" {
		if _, err := os.Lstat(path); errors.Is(err, os.ErrNotExist) {
			path = ""
		} else if err != nil || validateAccountTranscript(path, "codex", processAccountOverride(p.frontend.pid, "codex")) != nil {
			return empty, errors.New("stock Codex transcript ownership unavailable")
		}
	}
	proof := StockCodexProxyProof{p.descriptor.ProxyPID, p.descriptor.ProxyStart, p.descriptor.ControlSocket,
		p.descriptor.ControlDevice, p.descriptor.ControlInode, p.connection, p.selection.epoch}
	revisionData, _ := json.Marshal(struct {
		Producer agentProducer
		Session  string
		Path     string
		Proof    StockCodexProxyProof
		Backend  NativeCodexEndpoint
	}{
		agentProducer{PaneID: p.descriptor.Pane, Provider: "codex", ProcessID: p.frontend.pid, ProcessStart: p.frontend.start,
			ConfigDir: processAccountOverride(p.frontend.pid, "codex")},
		p.selection.session, path, proof, p.descriptor.Backend})
	sum := sha256.Sum256(revisionData)
	return AgentBindingRecord{Version: 1, Producer: agentProducer{PaneID: p.descriptor.Pane, Provider: "codex", ProcessID: p.frontend.pid, ProcessStart: p.frontend.start,
		ConfigDir: processAccountOverride(p.frontend.pid, "codex")},
		SessionID: p.selection.session, TranscriptPath: path, ObservedAt: time.Now().UTC(), Lifecycle: "unknown",
		Revision: hex.EncodeToString(sum[:]), Source: stockCodexProxySource, NativeEndpoint: &p.descriptor.Backend, StockProxy: &proof}, nil
}

// A --remote TUI cannot send permission flags, so a shared App Server resumes
// a thread with the server's default sandbox. When a resume request leaves the
// sandbox unset, ask for the one the thread last ran with. Other frames,
// explicit choices and threads without a readable record pass unchanged.
func (p *codexProxy) restoreResumeSandbox(data []byte) []byte {
	// A --remote TUI can encode its local default as an explicit Workspace
	// value. For the first primary task only, the user's resolved launch mode
	// is authoritative. Later /permissions choices remain ordinary frontend RPC.
	p.mu.Lock()
	initial := p.selection.session == ""
	p.mu.Unlock()
	if initial {
		permissions, configured, err := agentlaunch.CodexLaunchDefaults(p.codexHome)
		if p.resumePermissions != nil {
			permissions, configured = *p.resumePermissions, true
		}
		if err == nil && configured {
			if restored, applied := initialCodexPermissions(data, permissions); applied {
				return restored
			}
		}
	}
	restored, err := restoreCodexResumePermissions(data, p.codexHome, p.resumePermissions)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Relay could not restore this Codex conversation's saved sandbox; Codex defaults apply.")
		return data
	}
	return restored
}

func initialCodexPermissions(data []byte, permissions agentlaunch.CodexPermissions) ([]byte, bool) {
	if len(permissions.AppServerArguments()) == 0 {
		return data, false
	}
	var frame map[string]json.RawMessage
	var method string
	if json.Unmarshal(data, &frame) != nil || json.Unmarshal(frame["method"], &method) != nil || (method != "thread/start" && method != "thread/resume") {
		return data, false
	}
	var params map[string]json.RawMessage
	if json.Unmarshal(frame["params"], &params) != nil || params == nil {
		return data, false
	}
	if method == "thread/resume" {
		var thread string
		if json.Unmarshal(params["threadId"], &thread) != nil {
			return data, false
		}
		if _, valid := agentlaunch.CodexResumedThread([]string{"resume", thread}); !valid {
			return data, false
		}
	}
	params["sandbox"], _ = json.Marshal(permissions.SandboxMode)
	params["approvalPolicy"], _ = json.Marshal(permissions.ApprovalPolicy)
	frame["params"], _ = json.Marshal(params)
	restored, err := json.Marshal(frame)
	return restored, err == nil
}

func restoreCodexResumeSandbox(data []byte, codexHome string) ([]byte, error) {
	return restoreCodexResumePermissions(data, codexHome, nil)
}

func restoreCodexResumePermissions(data []byte, codexHome string, launch *agentlaunch.CodexPermissions) ([]byte, error) {
	var frame map[string]json.RawMessage
	var method string
	if json.Unmarshal(data, &frame) != nil || json.Unmarshal(frame["method"], &method) != nil || method != "thread/resume" {
		return data, nil
	}
	var params map[string]json.RawMessage
	var thread string
	if json.Unmarshal(frame["params"], &params) != nil || params == nil || json.Unmarshal(params["threadId"], &thread) != nil {
		return data, nil
	}
	if _, valid := agentlaunch.CodexResumedThread([]string{"resume", thread}); !valid {
		return data, nil
	}
	set := func(key string) bool {
		value, ok := params[key]
		return ok && string(value) != "null" && string(value) != `""`
	}
	// History and path resumes do not name the rollout by thread.
	if set("sandbox") || set("history") || set("path") || set("permissions") || set("permissionProfile") {
		return data, nil
	}
	approvalExplicit := set("approvalPolicy")
	if set("config") {
		var config map[string]json.RawMessage
		if json.Unmarshal(params["config"], &config) != nil {
			return data, nil
		}
		for key := range config {
			if key == "sandbox_mode" || strings.HasPrefix(key, "sandbox_") {
				return data, nil
			}
			if key == "approval_policy" || key == "approvals_reviewer" {
				approvalExplicit = true
			}
		}
	}
	permissions, configured, err := agentlaunch.CodexLaunchDefaults(codexHome)
	if err == nil && launch != nil {
		permissions, configured = *launch, true
		if len(permissions.AppServerArguments()) == 0 {
			return data, errors.New("invalid managed Codex resume permissions")
		}
	}
	if err == nil && !configured {
		permissions, err = agentlaunch.SavedCodexPermissions(codexHome, thread)
	}
	if err != nil {
		return data, err
	}
	params["sandbox"], _ = json.Marshal(permissions.SandboxMode)
	if configured && !approvalExplicit {
		params["approvalPolicy"], _ = json.Marshal(permissions.ApprovalPolicy)
	}
	encoded, err := json.Marshal(params)
	if err != nil {
		return data, err
	}
	frame["params"] = encoded
	return json.Marshal(frame)
}

type codexProxyFrame struct {
	data []byte
	kind byte
}

var codexProxyFrameCodec = websocket.Codec{
	Marshal: func(v any) ([]byte, byte, error) {
		f, ok := v.(codexProxyFrame)
		if !ok {
			return nil, 0, errors.New("invalid proxy frame")
		}
		return f.data, f.kind, nil
	},
	Unmarshal: func(data []byte, kind byte, v any) error {
		f, ok := v.(*codexProxyFrame)
		if !ok {
			return errors.New("invalid proxy frame destination")
		}
		f.data, f.kind = data, kind
		return nil
	},
}

type codexFrontendRole uint8

const (
	codexFrontendDenied codexFrontendRole = iota
	codexFrontendPrimary
	codexFrontendAuxiliary
)

// The caller must first verify the peer against the retained worker.
func (p *codexProxy) reserveFrontend(peer codexProxyPeer, front *websocket.Conn) codexFrontendRole {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.active {
		if p.frontend != peer || p.auxiliary != nil {
			return codexFrontendDenied
		}
		p.auxiliary = front
		return codexFrontendAuxiliary
	}
	p.active = true
	p.connection++
	p.frontend = peer
	p.selection.invalidate("connection_changed")
	return codexFrontendPrimary
}

func (p *codexProxy) releaseAuxiliary(front *websocket.Conn) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.auxiliary == front {
		p.auxiliary = nil
	}
}

func (p *codexProxy) retirePrimary() *websocket.Conn {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.active = false
	aux := p.auxiliary
	p.auxiliary = nil
	p.selection.invalidate("connection_changed")
	return aux
}

func (p *codexProxy) serveFrontend(front *websocket.Conn) {
	peer, ok := front.Request().Context().Value(codexProxyPeerKey{}).(codexProxyPeer)
	if !ok || p.verifyFrontend(peer) != nil {
		return
	}
	p.serveVerifiedFrontend(peer, front)
}

func (p *codexProxy) serveVerifiedFrontend(peer codexProxyPeer, front *websocket.Conn) {
	role := p.reserveFrontend(peer, front)
	if role == codexFrontendDenied {
		return
	}
	if role == codexFrontendAuxiliary {
		defer p.releaseAuxiliary(front)
		p.serveAuxiliary(front)
		return
	}
	var retired sync.Once
	retire := func() {
		retired.Do(func() {
			if aux := p.retirePrimary(); aux != nil {
				aux.Close()
			}
		})
	}
	defer func() {
		retire()
		if p.frontendDone != nil {
			select {
			case p.frontendDone <- struct{}{}:
			default:
			}
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := codexProxyBackendConnection(ctx, p.descriptor.Backend)
	if err != nil {
		return
	}
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	config, err := websocket.NewConfig("ws://localhost/", "http://localhost/")
	if err != nil {
		conn.Close()
		return
	}
	back, err := websocket.NewClient(config, conn)
	if err != nil {
		conn.Close()
		return
	}
	defer back.Close()
	conn.SetDeadline(time.Time{})
	front.MaxPayloadBytes, back.MaxPayloadBytes = 64<<20, 64<<20
	done := make(chan struct{}, 2)
	copyFrames := func(dst, src *websocket.Conn, frontend bool) {
		defer func() { done <- struct{}{} }()
		for {
			var frame codexProxyFrame
			if codexProxyFrameCodec.Receive(src, &frame) != nil {
				return
			}
			if frontend && frame.kind == websocket.TextFrame {
				frame.data = p.restoreResumeSandbox(frame.data)
			}
			p.mu.Lock()
			var inspectErr error
			if frame.kind != websocket.TextFrame {
				p.selection.invalidate("non_text_frame")
			} else if frontend {
				inspectErr = p.selection.frontend(frame.data)
			} else {
				inspectErr = p.selection.backend(frame.data)
			}
			if inspectErr == nil && p.descriptor.TrackPrimary && p.descriptor.Session != p.selection.session {
				p.descriptor.Session = p.selection.session
				inspectErr = persistCodexProxyDescriptor(codexProxyDirectory(p.server, p.descriptor.Pane), p.descriptor)
			}
			p.mu.Unlock()
			if inspectErr != nil || codexProxyFrameCodec.Send(dst, frame) != nil {
				return
			}
		}
	}
	go copyFrames(back, front, true)
	go copyFrames(front, back, false)
	<-done
	// Clear identity before closing either side. Never replay pending frames.
	retire()
	front.Close()
	back.Close()
	<-done
}

// Auxiliary connections are owned by the same authenticated frontend. They
// must never change the primary selection or signal primary termination.
func (p *codexProxy) serveAuxiliary(front *websocket.Conn) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := codexProxyBackendConnection(ctx, p.descriptor.Backend)
	if err != nil {
		return
	}
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	config, err := websocket.NewConfig("ws://localhost/", "http://localhost/")
	if err != nil {
		conn.Close()
		return
	}
	back, err := websocket.NewClient(config, conn)
	if err != nil {
		conn.Close()
		return
	}
	defer back.Close()
	conn.SetDeadline(time.Time{})
	front.MaxPayloadBytes, back.MaxPayloadBytes = 64<<20, 64<<20
	done := make(chan struct{}, 2)
	copyFrames := func(dst, src *websocket.Conn, frontend bool) {
		defer func() { done <- struct{}{} }()
		for {
			var frame codexProxyFrame
			if codexProxyFrameCodec.Receive(src, &frame) != nil {
				return
			}
			if frontend && frame.kind == websocket.TextFrame {
				frame.data = p.restoreResumeSandbox(frame.data)
			}
			if codexProxyFrameCodec.Send(dst, frame) != nil {
				return
			}
		}
	}
	go copyFrames(back, front, true)
	go copyFrames(front, back, false)
	<-done
	front.Close()
	back.Close()
	<-done
}

func (p *codexProxy) serveControl(conn net.Conn) {
	defer conn.Close()
	if RequirePeerUID(conn, os.Getuid()) != nil {
		return
	}
	conn.SetDeadline(time.Now().Add(4 * time.Second))
	var request struct {
		Method string `json:"method"`
	}
	if json.NewDecoder(io.LimitReader(conn, 1025)).Decode(&request) != nil {
		return
	}
	if request.Method == "state" {
		p.mu.Lock()
		state := map[string]any{"active": p.active, "frontend_pid": p.frontend.pid, "frontend_start": p.frontend.start,
			"primary_session": p.selection.session, "wanted_session": p.selection.wanted, "selection_epoch": p.selection.epoch,
			"resume_requests": p.selection.resumeRequests, "resume_responses": p.selection.resumeResponses,
			"last_frontend_method": p.selection.lastFrontendMethod, "last_invalidation": p.selection.lastInvalidation}
		state["last_frontend_thread"] = p.selection.lastFrontendThread
		state["turn_reconfirmations"] = p.selection.turnReconfirmations
		state["temporary_threads"] = len(p.selection.temporaryThreads)
		state["temporary_requests"] = len(p.selection.temporaryRequests)
		state["temporary_confirmations"] = p.selection.temporaryConfirmed
		p.mu.Unlock()
		_ = json.NewEncoder(conn).Encode(state)
		return
	}
	if request.Method != "binding" {
		return
	}
	record, err := p.binding()
	if err != nil {
		_ = json.NewEncoder(conn).Encode(map[string]string{"error": err.Error()})
		return
	}
	_ = json.NewEncoder(conn).Encode(record)
}

// ServeStockCodexProxy forwards standard RPC without provider patches. A private
// descriptor locates a read-only live identity endpoint; it is never a lease.
func ServeStockCodexProxy(ctx context.Context, options CodexProxyOptions, ready io.Writer) error {
	if !validSessionID.MatchString(options.Pane) || (!validSessionID.MatchString(options.Session) && !(options.TrackPrimary && options.Session == "")) || !filepath.IsAbs(options.BackendSocket) ||
		options.BackendPID <= 1 || options.BackendStart == 0 {
		return errors.New("invalid stock proxy scope")
	}
	server := NewServer()
	manifest, err := loadManifest(server.manifestPath(options.Pane))
	if err != nil || codexProxyManifest(server, manifest) != nil || manifest.SessionID != options.Pane {
		return errors.New("stock proxy retained worker unavailable")
	}
	dev, ino, err := codexProxySocketIdentity(options.BackendSocket)
	if err != nil {
		return err
	}
	start, err := processStartTime(os.Getpid())
	if err != nil {
		return err
	}
	p := &codexProxy{server: server, manifest: manifest, selection: codexProxySelection{wanted: options.Session, trackPrimary: options.TrackPrimary},
		codexHome: agentlaunch.CodexHome(os.Environ()), resumePermissions: options.ResumePermissions}
	if options.ExitWithFrontend {
		p.frontendDone = make(chan struct{}, 1)
	}
	p.descriptor = codexProxyDescriptor{Version: 1, Pane: options.Pane, Session: options.Session, TrackPrimary: options.TrackPrimary, ProxyPID: os.Getpid(), ProxyStart: start,
		WorkerPID: manifest.WorkerPID, WorkerStart: manifest.WorkerStartTime, ShellPID: manifest.ShellPID,
		Backend: NativeCodexEndpoint{Socket: options.BackendSocket, DaemonPID: options.BackendPID, DaemonStart: options.BackendStart, Device: dev, Inode: ino}}
	checkCtx, checkCancel := context.WithTimeout(ctx, 3*time.Second)
	conn, err := codexProxyBackendConnection(checkCtx, p.descriptor.Backend)
	checkCancel()
	if err != nil {
		return err
	}
	conn.Close()
	parent := filepath.Join(server.stateDir, "codex-proxies")
	if err := EnsurePrivateRuntimeDir(parent); err != nil {
		return err
	}
	directory := codexProxyDirectory(server, options.Pane)
	// Exclusive creation prevents replacing another proxy or uncertain startup.
	if err := os.Mkdir(directory, 0700); err != nil {
		return errors.New("stock proxy scope already exists")
	}
	defer os.RemoveAll(directory)
	runtimeParent := filepath.Join("/tmp", fmt.Sprintf("relay-codex-proxies-%d", os.Getuid()))
	if err := EnsurePrivateRuntimeDir(runtimeParent); err != nil {
		return err
	}
	runtimeDirectory, err := os.MkdirTemp(runtimeParent, "codex-proxy-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(runtimeDirectory)
	p.descriptor.FrontendSocket = filepath.Join(runtimeDirectory, "frontend.sock")
	p.descriptor.ControlSocket = filepath.Join(runtimeDirectory, "binding.sock")
	frontend, err := net.Listen("unix", p.descriptor.FrontendSocket)
	if err != nil {
		return err
	}
	defer frontend.Close()
	control, err := net.Listen("unix", p.descriptor.ControlSocket)
	if err != nil {
		return err
	}
	defer control.Close()
	if os.Chmod(p.descriptor.FrontendSocket, 0600) != nil || os.Chmod(p.descriptor.ControlSocket, 0600) != nil {
		return errors.New("stock proxy socket permissions unavailable")
	}
	p.descriptor.ControlDevice, p.descriptor.ControlInode, err = codexProxySocketIdentity(p.descriptor.ControlSocket)
	if err != nil {
		return err
	}
	if err := persistCodexProxyDescriptor(directory, p.descriptor); err != nil {
		return err
	}
	httpServer := &http.Server{ReadHeaderTimeout: 5 * time.Second, MaxHeaderBytes: 16384, ErrorLog: log.New(io.Discard, "", 0),
		ConnContext: func(ctx context.Context, conn net.Conn) context.Context {
			uid, pid, err := PeerCredentials(conn)
			if err != nil {
				return ctx
			}
			start, err := processStartTime(pid)
			if err != nil {
				return ctx
			}
			return context.WithValue(ctx, codexProxyPeerKey{}, codexProxyPeer{uid, pid, start})
		},
		Handler: websocket.Server{Handshake: func(_ *websocket.Config, r *http.Request) error {
			peer, ok := r.Context().Value(codexProxyPeerKey{}).(codexProxyPeer)
			if !ok {
				return errors.New("stock proxy peer unavailable")
			}
			return p.verifyFrontend(peer)
		}, Handler: p.serveFrontend}}
	finished := make(chan error, 2)
	go func() { finished <- httpServer.Serve(frontend) }()
	go func() {
		for {
			conn, err := control.Accept()
			if err != nil {
				finished <- err
				return
			}
			go p.serveControl(conn)
		}
	}()
	if err := json.NewEncoder(ready).Encode(map[string]any{"version": 1, "pane": options.Pane, "session": options.Session, "frontend_socket": p.descriptor.FrontendSocket, "control_socket": p.descriptor.ControlSocket}); err != nil {
		httpServer.Close()
		return err
	}
	select {
	case <-p.frontendDone:
		httpServer.Close()
		return nil
	case <-ctx.Done():
		httpServer.Close()
		return ctx.Err()
	case err := <-finished:
		httpServer.Close()
		return err
	}
}

// Keep the current confirmed session in the v1 descriptor so retained
// supervisors can verify this proxy without a supervisor/worker replacement.
func persistCodexProxyDescriptor(directory string, descriptor codexProxyDescriptor) error {
	data, err := json.Marshal(descriptor)
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(directory, ".descriptor-")
	if err != nil {
		return err
	}
	name := file.Name()
	defer os.Remove(name)
	if _, err = file.Write(data); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err := os.Rename(name, filepath.Join(directory, "descriptor.json")); err != nil {
		return err
	}
	parent, err := os.Open(directory)
	if err != nil {
		return err
	}
	defer parent.Close()
	return parent.Sync()
}

func readStockCodexProxyDescriptor(server *Server, pane string) (codexProxyDescriptor, error) {
	var descriptor codexProxyDescriptor
	directory := codexProxyDirectory(server, pane)
	if _, err := os.Lstat(directory); errors.Is(err, os.ErrNotExist) {
		return descriptor, errNoStockCodexProxy
	}
	if privateBindingObject(filepath.Dir(directory), true) != nil || privateBindingObject(directory, true) != nil {
		return descriptor, errors.New("stock proxy descriptor directory unavailable")
	}
	path := filepath.Join(directory, "descriptor.json")
	if privateBindingObject(path, false) != nil {
		return descriptor, errors.New("stock proxy descriptor unavailable")
	}
	file, err := os.Open(path)
	if err != nil {
		return descriptor, err
	}
	defer file.Close()
	before, err := file.Stat()
	after, statErr := os.Lstat(path)
	if err != nil || statErr != nil || !os.SameFile(before, after) {
		return descriptor, errors.New("stock proxy descriptor changed")
	}
	data, err := io.ReadAll(io.LimitReader(file, 65537))
	if err != nil || len(data) > 65536 || json.Unmarshal(data, &descriptor) != nil || descriptor.Version != 1 ||
		descriptor.Pane != pane || (!validSessionID.MatchString(descriptor.Session) && !(descriptor.TrackPrimary && descriptor.Session == "")) || descriptor.ProxyPID <= 1 || descriptor.ProxyStart == 0 {
		return descriptor, errors.New("invalid stock proxy descriptor")
	}
	return descriptor, nil
}

func readStockCodexProxyBinding(pane string) (AgentBindingRecord, error) {
	var empty AgentBindingRecord
	server := NewServer()
	before, err := readStockCodexProxyDescriptor(server, pane)
	if err != nil {
		return empty, err
	}
	dev, ino, err := codexProxySocketIdentity(before.ControlSocket)
	if err != nil || dev != before.ControlDevice || ino != before.ControlInode {
		return empty, errors.New("stock proxy control socket changed")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", before.ControlSocket)
	if err != nil {
		return empty, err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(4 * time.Second))
	uid, pid, err := PeerCredentials(conn)
	start, startErr := processStartTime(before.ProxyPID)
	if err != nil || uid != os.Getuid() || pid != before.ProxyPID || startErr != nil || start != before.ProxyStart {
		return empty, errors.New("stock proxy control process changed")
	}
	if json.NewEncoder(conn).Encode(map[string]string{"method": "binding"}) != nil {
		return empty, errors.New("stock proxy identity request failed")
	}
	data, err := bufio.NewReader(io.LimitReader(conn, 65537)).ReadBytes('\n')
	var record AgentBindingRecord
	if err != nil || len(data) > 65536 || json.Unmarshal(data, &record) != nil {
		return empty, errors.New("stock proxy identity response unavailable")
	}
	var responseError struct {
		Error string `json:"error"`
	}
	if json.Unmarshal(data, &responseError) == nil && responseError.Error != "" {
		return empty, fmt.Errorf("stock proxy binding unavailable: %s", responseError.Error)
	}
	proof := record.StockProxy
	if record.Version != 1 || record.Source != stockCodexProxySource || !validSessionID.MatchString(record.SessionID) || (!before.TrackPrimary && record.SessionID != before.Session) || record.NativeEndpoint == nil ||
		*record.NativeEndpoint != before.Backend || proof == nil || proof.ProxyPID != before.ProxyPID || proof.ProxyStart != before.ProxyStart ||
		proof.ControlSocket != before.ControlSocket || proof.ControlDevice != dev || proof.ControlInode != ino || proof.Connection == 0 || proof.Selection == 0 ||
		record.Producer.PaneID != pane || record.Producer.Provider != "codex" || record.ObservedAt.IsZero() || time.Since(record.ObservedAt) > 5*time.Second ||
		record.ObservedAt.After(time.Now().Add(time.Second)) {
		return empty, errors.New("invalid stock proxy identity proof")
	}
	manifest, err := loadManifest(server.manifestPath(pane))
	if err != nil || manifest.WorkerPID != before.WorkerPID || manifest.WorkerStartTime != before.WorkerStart || manifest.ShellPID != before.ShellPID || codexProxyManifest(server, manifest) != nil {
		return empty, errors.New("stock proxy retained worker changed")
	}
	start, err = NativeAgentIncarnation(pane, record.Producer.ProcessID, "codex")
	provider, front := nativeBindingFrontend(manifest.ShellPID)
	if err != nil || start != record.Producer.ProcessStart || provider != "codex" || front != record.Producer.ProcessID {
		return empty, errors.New("stock proxy frontend changed")
	}
	if record.TranscriptPath != "" && validateAccountTranscript(record.TranscriptPath, "codex", processAccountOverride(record.Producer.ProcessID, "codex")) != nil {
		return empty, errors.New("stock proxy transcript changed")
	}
	backend, err := codexProxyBackendConnection(ctx, before.Backend)
	if err != nil {
		return empty, err
	}
	backend.Close()
	after, err := readStockCodexProxyDescriptor(server, pane)
	devAfter, inoAfter, socketErr := codexProxySocketIdentity(before.ControlSocket)
	proxyAfter, startErr := processStartTime(before.ProxyPID)
	if err != nil || after != before || socketErr != nil || devAfter != dev || inoAfter != ino || startErr != nil || proxyAfter != before.ProxyStart {
		return empty, errors.New("stock proxy changed during observation")
	}
	return record, nil
}
