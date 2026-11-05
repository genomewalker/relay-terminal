package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/relay-terminal/relayd/internal/nativemsg"
	"github.com/relay-terminal/relayd/internal/workorigin"
	"io"
	"os"
	"strconv"
	"strings"
	"time"
)

// WorkRequest contains no caller-selected source, destination or PID. The
// source comes from protected provider metadata plus the native pipe chain,
// or independently from the kernel ancestry of a native pane CLI.
type WorkRequest struct {
	Operation         string `json:"operation"`
	LinkID            string `json:"link_id"`
	MessageID         string `json:"message_id,omitempty"`
	Text              string `json:"text,omitempty"`
	ExpectedRevision  uint64 `json:"expected_revision,omitempty"`
	RequestID         string `json:"request_id,omitempty"`
	ProtectedThreadID string `json:"protected_thread_id,omitempty"`
	ClientToken       string `json:"client_token,omitempty"`
	// send_file only: the sender's own absolute file path and its declared digest.
	Path       string `json:"path,omitempty"`
	FileSHA256 string `json:"file_sha256,omitempty"`

	file *workAttachment
}

type workRequestOrigin struct {
	pane           string
	thread         string
	applicationPID int
	revalidate     func() error
}

func RunCommunicationWork(in io.Reader, out io.Writer) error {
	data, err := readWorkRequestFrame(in, 128<<10)
	if err != nil {
		return errors.New("invalid Work request")
	}
	var r WorkRequest
	if communicationStrictWorkJSONLimit(data, &r, 128<<10) != nil {
		return errors.New("invalid Work request")
	}
	if r.ClientToken == "" {
		r.ClientToken = os.Getenv("RELAY_MCP_CALLER_TOKEN")
	}
	origin, err := authenticateWorkRequest(r)
	if err != nil {
		return err
	}
	if r.ClientToken == "" && origin.pane != "" {
		r.ClientToken, err = readWorkCredential(communicationRoot(), currentCommunicationNodeID(), origin)
		if err != nil {
			return err
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	result, err := executeWorkRequest(ctx, communicationRoot(), currentCommunicationNodeID(), r, origin)
	if err != nil {
		return err
	}
	return json.NewEncoder(out).Encode(result)
}

func authenticateWorkRequest(r WorkRequest) (workRequestOrigin, error) {
	if r.ProtectedThreadID != "" {
		source, err := workorigin.AuthenticateCaller(os.Getpid(), r.ProtectedThreadID)
		if err != nil {
			return workRequestOrigin{}, errors.New("native Work caller unavailable")
		}
		return workRequestOrigin{thread: source.Thread, applicationPID: source.Transport.Application.PID, revalidate: source.Transport.Revalidate}, nil
	}
	actor, err := ReadCommunicationActor(os.Getppid())
	if err != nil {
		return workRequestOrigin{}, err
	}
	return workRequestOrigin{pane: actor.PaneID, revalidate: func() error {
		current, e := ReadCommunicationActor(os.Getppid())
		if e != nil {
			return e
		}
		if current != actor {
			return errors.New("native caller changed")
		}
		return nil
	}}, nil
}

func workOriginMatches(origin workRequestOrigin, endpoint communicationEndpoint) bool {
	return (endpoint.Kind == "work" && endpoint.Work != nil && origin.thread == endpoint.Work.Thread && origin.pane == "" && origin.applicationPID > 1 && strings.HasPrefix(endpoint.Work.Incarnation, strconv.Itoa(origin.applicationPID)+":")) ||
		(endpoint.Kind == "pane" && origin.pane == endpoint.PaneID && origin.thread == "")
}

func executeWorkRequest(ctx context.Context, root, node string, r WorkRequest, origin workRequestOrigin) (map[string]any, error) {
	if !remoteDigest(r.LinkID) || origin.revalidate == nil {
		return nil, errors.New("exact Work relationship required")
	}
	if err := origin.revalidate(); err != nil {
		return nil, err
	}
	if r.Operation == "send_file" {
		a, err := readWorkAttachment(r.Path, r.FileSHA256)
		if err != nil {
			return nil, err
		}
		if r.Text == "" {
			r.Text = workDefaultFileText(a)
		}
		r.file, r.Operation, r.Path = a, "send", ""
	} else if r.Path != "" || r.FileSHA256 != "" {
		return nil, errors.New("file fields require send_file")
	}
	var link communicationTypedRemoteLink
	var caller string
	err := communicationFanoutLocked(root, func() error {
		var e error
		link, e = communicationReadTypedActiveLink(ctx, root, node, r.LinkID)
		if e != nil {
			return e
		}
		if !workOriginMatches(origin, link.Local) {
			return errors.New("caller is not this relationship endpoint")
		}
		op := "remote_receipt"
		if r.Operation == "send" {
			op = "remote_send"
		}
		caller, e = communicationAuthorize(root, CommunicationRequest{Operation: op, ClientToken: r.ClientToken, ActorPaneID: origin.pane, SourcePaneID: origin.pane})
		return e
	})
	if err != nil {
		return nil, err
	}
	if err := origin.revalidate(); err != nil {
		return nil, err
	}
	switch r.Operation {
	case "status":
		current, e := workObserveEndpoint(ctx, link.Local)
		state := "local_ready"
		if e != nil || !communicationEndpointEqual(current, link.Local) {
			state = "stale"
		}
		return map[string]any{"link_id": link.ID, "revision": link.Revision, "local": link.Local, "peer": link.Peer, "state": state, "peer_observed": false, "authority": "relayd"}, nil
	case "repair":
		if r.ExpectedRevision != link.Revision || !validSessionID.MatchString(r.RequestID) {
			return nil, errors.New("relationship revision changed")
		}
		return nil, errors.New("same-endpoint recovery is not activated; no changes made")
	case "send", "receipt":
		if !validSessionID.MatchString(r.MessageID) {
			return nil, errors.New("valid message identity required")
		}
		return workSendOrReceipt(ctx, root, node, caller, r, origin, link)
	default:
		return nil, errors.New("unknown Work operation")
	}
}

func observeWorkEndpoint(ctx context.Context, e communicationEndpoint) (communicationEndpoint, error) {
	if e.Kind == "work" && e.Work != nil {
		w, err := nativemsg.ObserveWork(ctx, e.Work.Thread)
		if err != nil {
			return communicationEndpoint{}, err
		}
		e.Work = &w
		return e, nil
	}
	if e.Kind == "pane" {
		m := communicationObserve(e.PaneID)
		if m.Endpoint == nil || m.Unavailable != "" {
			return communicationEndpoint{}, errors.New("native pane unavailable")
		}
		e.Provider = m.Provider
		e.SessionID = m.SessionID
		return e, nil
	}
	return communicationEndpoint{}, errors.New("invalid endpoint")
}

// readWorkRequestFrame reads one request terminated by newline or EOF without
// waiting for EOF, so the caller's stdin writer stays open for origin proof.
func readWorkRequestFrame(in io.Reader, limit int) ([]byte, error) {
	data := make([]byte, 0, 4096)
	var b [1]byte
	for {
		n, err := in.Read(b[:])
		if n == 1 {
			if b[0] == '\n' {
				return data, nil
			}
			if len(data) >= limit {
				return nil, errors.New("invalid Work request")
			}
			data = append(data, b[0])
		}
		if err == io.EOF {
			return data, nil
		}
		if err != nil {
			return nil, err
		}
	}
}
