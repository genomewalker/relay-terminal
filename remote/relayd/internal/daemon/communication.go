package daemon

// Communication belongs to the host daemon. No desktop HTTP endpoint, GUI
// process, client connection, or laptop credential is needed by this service.
import (
	"bytes"
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

// These are build copies of the canonical native provider adapters. Both
// clients and the daemon use the same process/session/socket validation.
//
//go:embed communication_runtime/agent_conversation.py
var communicationDiscovery []byte

//go:embed communication_runtime/pane_messaging.py
var communicationAdapter []byte

type CommunicationRequest struct {
	GroupMembers               []CommunicationGroupMember `json:"group_members,omitempty"`
	RemoteLink                 *CommunicationRemoteLink   `json:"remote_link,omitempty"`
	ExpectedRemoteLinkRevision uint64                     `json:"expected_remote_link_revision,omitempty"`
	ExpectedIdentitySHA256     string                     `json:"expected_identity_sha256,omitempty"`
	PeerBinding                *CommunicationPeerBinding  `json:"peer_binding,omitempty"`
	RouteID                    string                     `json:"route_id,omitempty"`
	PeerNodeID                 string                     `json:"peer_node_id,omitempty"`
	TransportBindingID         string                     `json:"transport_binding_id,omitempty"`
	ExpectedRouteRevision      uint64                     `json:"expected_route_revision,omitempty"`
	GroupID                    string                     `json:"group_id,omitempty"`
	GroupName                  string                     `json:"group_name,omitempty"`
	MemberPaneIDs              []string                   `json:"member_pane_ids,omitempty"`
	ExpectedGroupRevision      uint64                     `json:"expected_group_revision,omitempty"`
	Operation                  string                     `json:"operation"`
	SourcePaneID               string                     `json:"source_pane_id,omitempty"`
	PaneID                     string                     `json:"pane_id,omitempty"`
	MessageID                  string                     `json:"message_id,omitempty"`
	Text                       string                     `json:"text,omitempty"`
	ClientID                   string                     `json:"client_id,omitempty"`
	ClientToken                string                     `json:"client_token,omitempty"`
	ActorPaneID                string                     `json:"actor_pane_id,omitempty"`
	CallerID                   string                     `json:"caller_id,omitempty"`
	Paused                     *bool                      `json:"paused,omitempty"`
	Policy                     *communicationPolicy       `json:"policy,omitempty"`
	Cursor                     int64                      `json:"cursor,omitempty"`
	LinkID                     string                     `json:"link_id,omitempty"`
}

type communicationMember struct {
	HostID      string         `json:"hostID"`
	Name        string         `json:"name"`
	PID         int            `json:"pid"`
	Start       string         `json:"start"`
	PaneID      string         `json:"paneID"`
	Provider    string         `json:"provider,omitempty"`
	SessionID   string         `json:"sessionID,omitempty"`
	Endpoint    map[string]any `json:"endpoint,omitempty"`
	Unavailable string         `json:"unavailable,omitempty"`
}
type communicationLink struct {
	Version          int                   `json:"version"`
	ID               string                `json:"id"`
	NodeID           string                `json:"node_id"`
	Members          []communicationMember `json:"members"`
	UpdatedAt        time.Time             `json:"updated_at"`
	Transport        string                `json:"transport"`
	ResolutionErrors map[string]string     `json:"resolutionErrors,omitempty"`
}

func communicationEvent(root, node, kind string, links []map[string]string) error {
	event := map[string]any{"schema_version": 1, "node_id": node, "occurred_at": time.Now().UTC(), "kind": kind, "links": links}
	data, err := json.Marshal(event)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	f, err := OpenPrivateFile(filepath.Join(root, "events.jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err = f.Write(data); err != nil {
		return err
	}
	return f.Sync()
}

type communicationReceipt struct {
	Version     int            `json:"version"`
	Fingerprint string         `json:"fingerprint"`
	CreatedAt   time.Time      `json:"created_at"`
	Result      map[string]any `json:"result"`
}

func communicationRoot() string { return filepath.Join(defaultWorkerStateDir(), "communication") }

func communicationAtomic(path string, value any) error {
	data, err := json.Marshal(value)
	if err != nil || len(data) > 128<<10 {
		return errors.New("communication record exceeds limit")
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".communication-*")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name)
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(data)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err = os.Rename(name, path); err != nil {
		return err
	}
	d, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

func communicationRead(path string, value any) error {
	if err := privateBindingObject(path, false); err != nil {
		return err
	}
	f, err := OpenPrivateFile(path, os.O_RDONLY)
	if err != nil {
		return err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 128<<10+1))
	if err != nil || len(data) > 128<<10 {
		return errors.New("invalid communication record")
	}
	return json.Unmarshal(data, value)
}

func communicationNative(pane string, packet map[string]any) (map[string]any, error) {
	if !validSessionID.MatchString(pane) {
		return nil, errors.New("invalid native pane")
	}
	helper, err := os.Executable()
	if err != nil {
		return nil, err
	}
	packet["requireAuthenticatedBinding"] = true
	data, err := json.Marshal(packet)
	if err != nil {
		return nil, err
	}
	source := "RELAY_DISCOVERY_SOURCE = '" + base64.StdEncoding.EncodeToString(communicationDiscovery) + "'\n" + string(communicationAdapter)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "python3", "-", "--daemon", helper, "--pane", pane,
		"--request", base64.StdEncoding.EncodeToString(data))
	cmd.Stdin = strings.NewReader(source)
	var output bytes.Buffer
	cmd.Stdout = &output
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("native communication adapter failed: %w", err)
	}
	if output.Len() > 128<<10 {
		return nil, errors.New("native communication response exceeds limit")
	}
	var result map[string]any
	if err := json.Unmarshal(output.Bytes(), &result); err != nil {
		return nil, err
	}
	return result, nil
}

func communicationObserve(pane string) communicationMember {
	member := communicationMember{PaneID: pane}
	result, err := communicationNative(pane, map[string]any{"operation": "discover"})
	if err != nil {
		member.Unavailable = err.Error()
		return member
	}
	endpoint, ok := result["endpoint"].(map[string]any)
	if !ok {
		member.Unavailable, _ = result["error"].(string)
		return member
	}
	member.Endpoint = endpoint
	if pid, ok := endpoint["pid"].(float64); ok {
		member.PID = int(pid)
	}
	member.Start, _ = endpoint["start"].(string)
	member.Provider, _ = endpoint["provider"].(string)
	member.SessionID, _ = endpoint["sessionID"].(string)
	if endpoint["transport"] == "unavailable" {
		member.Unavailable = "provider has no verified messaging endpoint"
	}
	return member
}

func communicationPair(source, target string) (string, []string, error) {
	source, target = strings.ToLower(source), strings.ToLower(target)
	if source == target || !validSessionID.MatchString(source) || !validSessionID.MatchString(target) {
		return "", nil, errors.New("two distinct pane identities are required")
	}
	ids := []string{source, target}
	sort.Strings(ids)
	// The storage directory is the authoritative node scope. Process IDs and
	// provider session IDs never define the logical relationship identity.
	hash := sha256.Sum256([]byte(strings.Join(ids, "\n")))
	return hex.EncodeToString(hash[:]), ids, nil
}

// ExecuteCommunication is also used by the node-local MCP transport. Native
// process and recipient session checks are repeated on the server per send.
func ExecuteCommunication(r CommunicationRequest) (map[string]any, error) {
	if r.Operation == "group_receipt" {
		qualified, err := communicationUseQualifiedFanout(communicationRoot(), currentCommunicationNodeID(), r)
		if err != nil {
			return nil, err
		}
		if qualified {
			return communicationQualifiedGroupReceipt(communicationRoot(), currentCommunicationNodeID(), r)
		}
	}
	if r.Operation == "remote_send" || r.Operation == "remote_receipt" {
		return communicationSendRemote(communicationRoot(), currentCommunicationNodeID(), r,
			communicationGroupNative{observe: communicationObserve, send: communicationNative})
	}
	if r.Operation == "route_link_set" {
		return communicationRemoteLinkSet(communicationRoot(), currentCommunicationNodeID(), r,
			communicationGroupNative{observe: communicationObserve, send: communicationNative})
	}
	if r.Operation == "route_probe" {
		return communicationPeerProbe(communicationRoot(), currentCommunicationNodeID(), r)
	}
	r.SourcePaneID, r.PaneID = strings.ToLower(r.SourcePaneID), strings.ToLower(r.PaneID)
	r.MessageID, r.LinkID = strings.ToLower(r.MessageID), strings.ToLower(r.LinkID)
	if r.Operation == "group_send" {
		return communicationGroupSend(communicationRoot(), currentCommunicationNodeID(), r,
			communicationGroupNative{observe: communicationObserve, send: communicationNative})
	}
	root := communicationRoot()
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, err
	}
	if err := privateBindingObject(root, true); err != nil {
		return nil, err
	}
	lock, err := OpenPrivateFile(filepath.Join(root, "lock"), os.O_CREATE|os.O_RDWR)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return nil, err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	if strings.HasPrefix(r.Operation, "caller_") {
		return communicationPolicyAdmin(root, r)
	}
	identity, err := communicationAuthorize(root, r)
	if err != nil {
		return nil, err
	}
	r.ClientID = identity
	nodeID, _ := currentNodeIdentity()
	if strings.HasPrefix(r.Operation, "route_") {
		return communicationRouteOperation(root, nodeID, r)
	}
	if strings.HasPrefix(r.Operation, "group_") {
		known := map[string]string{}
		if r.Operation == "group_set" {
			catalog, err := NewServer().CatalogSnapshot()
			if err != nil {
				return nil, err
			}
			for _, pane := range catalog.Panes {
				if pane.NodeID == nodeID {
					known[strings.ToLower(pane.PaneID)] = pane.Title
				}
			}
		}
		return communicationGroupOperation(root, nodeID, r, known)
	}
	switch r.Operation {
	case "unlink":
		if len(r.LinkID) != 64 {
			return nil, errors.New("invalid communication relationship identity")
		}
		if _, err := hex.DecodeString(r.LinkID); err != nil {
			return nil, errors.New("invalid communication relationship identity")
		}
		path := filepath.Join(root, "link-"+r.LinkID+".json")
		var link communicationLink
		if err := communicationRead(path, &link); errors.Is(err, os.ErrNotExist) {
			return map[string]any{"status": "not_found", "prior_removal": "unknown"}, nil
		} else if err != nil {
			return nil, err
		}
		if r.SourcePaneID != "" {
			member := false
			for _, saved := range link.Members {
				member = member || saved.PaneID == r.SourcePaneID
			}
			if !member {
				return nil, errors.New("only a relationship member can retire this pair")
			}
		}
		if err := os.Rename(path, filepath.Join(root, ".retired-"+r.LinkID+"-"+fmt.Sprint(time.Now().UnixNano())+".json")); err != nil {
			return nil, err
		}
		if err := communicationEvent(root, nodeID, "communication_pair_retired", nil); err != nil {
			return nil, err
		}
		return map[string]any{"status": "retired", "history": "retained", "message_receipts": "retained"}, nil
	case "events":
		if r.Cursor < 0 {
			return nil, errors.New("invalid event cursor")
		}
		f, err := OpenPrivateFile(filepath.Join(root, "events.jsonl"), os.O_RDONLY)
		if errors.Is(err, os.ErrNotExist) {
			return map[string]any{"data": "", "next_cursor": r.Cursor, "authority": "relayd"}, nil
		}
		if err != nil {
			return nil, err
		}
		defer f.Close()
		info, err := f.Stat()
		if err != nil {
			return nil, err
		}
		if r.Cursor > info.Size() {
			return nil, errors.New("event cursor exceeds server history")
		}
		data, err := io.ReadAll(io.NewSectionReader(f, r.Cursor, 64<<10))
		if err != nil {
			return nil, err
		}
		return map[string]any{"data": base64.StdEncoding.EncodeToString(data), "next_cursor": r.Cursor + int64(len(data)), "node_id": nodeID, "authority": "relayd"}, nil
	case "list":
		paths, err := filepath.Glob(filepath.Join(root, "link-*.json"))
		if err != nil {
			return nil, err
		}
		if len(paths) > 256 {
			return nil, errors.New("communication membership limit exceeded")
		}
		links := []communicationLink{}
		for _, path := range paths {
			var link communicationLink
			if err := communicationRead(path, &link); err != nil {
				return nil, err
			}
			links = append(links, link)
		}
		return map[string]any{"node_id": nodeID, "links": links, "authority": "relayd", "process_revalidated": false, "desktop_required": false}, nil
	case "discover":
		return communicationNative(r.PaneID, map[string]any{"operation": "discover"})
	case "receipt":
		if !validSessionID.MatchString(r.MessageID) {
			return nil, errors.New("valid message identity required")
		}
		var receipt communicationReceipt
		err := communicationRead(filepath.Join(root, "message-"+strings.ToLower(r.MessageID)+".json"), &receipt)
		if errors.Is(err, os.ErrNotExist) {
			return map[string]any{"status": "unknown", "replay_permitted": false}, nil
		}
		if err != nil {
			return nil, err
		}
		return receipt.Result, nil
	case "link", "send":
		id, ids, err := communicationPair(r.SourcePaneID, r.PaneID)
		if err != nil {
			return nil, err
		}
		path := filepath.Join(root, "link-"+id+".json")
		if r.Operation == "link" {
			catalog, err := NewServer().CatalogSnapshot()
			if err != nil {
				return nil, err
			}
			known := map[string]bool{}
			names := map[string]string{}
			for _, pane := range catalog.Panes {
				known[strings.ToLower(pane.PaneID)] = true
				names[strings.ToLower(pane.PaneID)] = pane.Title
			}
			if !known[ids[0]] || !known[ids[1]] {
				return nil, errors.New("both panes must belong to this daemon; remote peers require a server route")
			}
			if _, err := os.Lstat(path); errors.Is(err, os.ErrNotExist) {
				paths, _ := filepath.Glob(filepath.Join(root, "link-*.json"))
				if len(paths) >= 256 {
					return nil, errors.New("communication membership limit reached")
				}
			}
			hostHash := sha256.Sum256([]byte(nodeID))
			hostID := fmt.Sprintf("%x-%x-%x-%x-%x", hostHash[:4], hostHash[4:6], hostHash[6:8], hostHash[8:10], hostHash[10:16])
			link := communicationLink{Version: 1, ID: id, NodeID: nodeID, UpdatedAt: time.Now().UTC(), Transport: "relay_native_socket", ResolutionErrors: map[string]string{}}
			for _, pane := range ids {
				member := communicationObserve(pane)
				member.HostID = hostID
				member.Name = names[pane]
				if member.Unavailable != "" {
					link.ResolutionErrors[pane] = member.Unavailable
					link.Transport = "unavailable"
				}
				link.Members = append(link.Members, member)
			}
			if err := communicationAtomic(path, link); err != nil {
				return nil, err
			}
			if err := communicationEvent(root, nodeID, "communication_pair_saved", []map[string]string{{"from": "pane:" + ids[0], "to": "pane:" + ids[1], "kind": "communication_member"}}); err != nil {
				return nil, err
			}
			return map[string]any{"link": link, "state": "membership_saved", "desktop_required": false}, nil
		}
		if !validSessionID.MatchString(r.MessageID) || len(r.Text) == 0 || len(r.Text) > 16384 || strings.TrimSpace(r.Text) == "" {
			return nil, errors.New("a message UUID and 1-16384 bytes of text are required")
		}
		// Credentials and administrative fields never define message identity.
		encoded, _ := json.Marshal(struct {
			Source, Target, Message, Text string
		}{r.SourcePaneID, r.PaneID, r.MessageID, r.Text})
		hash := sha256.Sum256(encoded)
		fingerprint := hex.EncodeToString(hash[:])
		receiptPath := filepath.Join(root, "message-"+strings.ToLower(r.MessageID)+".json")
		var receipt communicationReceipt
		if err := communicationRead(receiptPath, &receipt); err == nil {
			if receipt.Fingerprint != fingerprint {
				return nil, errors.New("message identity conflicts with a previous request")
			}
			return receipt.Result, nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
		var link communicationLink
		if err := communicationRead(path, &link); err != nil {
			return nil, errors.New("save the communication pair on this daemon before sending")
		}
		source, target := communicationObserve(r.SourcePaneID), communicationObserve(r.PaneID)
		if source.Endpoint == nil || target.Endpoint == nil || target.Unavailable != "" {
			return nil, errors.New("a pane has no verified native communication endpoint")
		}
		for _, saved := range link.Members {
			live := source
			if saved.PaneID == r.PaneID {
				live = target
			}
			if saved.SessionID != "" && (saved.SessionID != live.SessionID || saved.Provider != live.Provider) {
				return nil, errors.New("linked conversation changed; review the pair before sending")
			}
		}
		receipt = communicationReceipt{Version: 1, Fingerprint: fingerprint, CreatedAt: time.Now().UTC(), Result: map[string]any{
			"message_id": r.MessageID, "source_pane_id": r.SourcePaneID, "pane_id": r.PaneID, "status": "outcome_unknown", "replay_permitted": false,
			"source_authentication": "claimed_pane_label", "submitting_client_id": identity,
			"authority": "relayd", "desktop_required": false}}
		// Persist the claim before the only native delivery. A lost client or
		// daemon crash can never cause this message ID to be submitted again.
		if err := communicationAtomic(receiptPath, receipt); err != nil {
			return nil, err
		}
		if err := communicationEvent(root, nodeID, "message_claimed", []map[string]string{{"from": "pane:" + r.SourcePaneID, "to": "message:" + r.MessageID, "kind": "submitted"}, {"from": "message:" + r.MessageID, "to": "pane:" + r.PaneID, "kind": "addressed_to"}}); err != nil {
			return receipt.Result, err
		}
		packet := map[string]any{"operation": "send", "expected": target.Endpoint, "messageID": r.MessageID,
			"targetPaneID": r.PaneID, "text": r.Text, "submittingClientID": r.ClientID,
			"source": map[string]any{"hostID": nodeID, "paneID": r.SourcePaneID, "sessionID": source.SessionID}}
		result, err := communicationNative(r.PaneID, packet)
		for key, value := range communicationNativeOutcome(result, err) {
			receipt.Result[key] = value
		}
		if err := communicationAtomic(receiptPath, receipt); err != nil {
			return nil, err
		}
		if err := communicationEvent(root, nodeID, "message_outcome", []map[string]string{{"from": "message:" + r.MessageID, "to": fmt.Sprint(receipt.Result["status"]), "kind": "status"}}); err != nil {
			return receipt.Result, err
		}
		return receipt.Result, nil
	default:
		return nil, errors.New("unknown daemon communication operation")
	}
}
