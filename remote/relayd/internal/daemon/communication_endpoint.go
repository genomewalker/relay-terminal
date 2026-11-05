package daemon

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/relay-terminal/relayd/internal/nativemsg"
)

// communicationEndpoint is a typed logical participant and its verified
// conversation binding. A Work task is never represented as a pane.
type communicationEndpoint struct {
	NodeID    string                  `json:"node_id"`
	Kind      string                  `json:"kind"`
	PaneID    string                  `json:"pane_id,omitempty"`
	Provider  string                  `json:"provider,omitempty"`
	SessionID string                  `json:"session_id,omitempty"`
	Work      *nativemsg.WorkEndpoint `json:"work,omitempty"`
}

func (e communicationEndpoint) valid() bool {
	if !canonicalRouteToken(e.NodeID) {
		return false
	}
	switch e.Kind {
	case "pane":
		return e.Work == nil && validSessionID.MatchString(e.PaneID) && (e.Provider == "claude" || e.Provider == "codex") && validSessionID.MatchString(e.SessionID)
	case "work":
		return e.PaneID == "" && e.Provider == "" && e.SessionID == "" && e.Work != nil && e.Work.Valid()
	default:
		return false
	}
}

// logicalKey deliberately excludes mutable session and process bindings. A
// link's revision and the entire pinned endpoint must still match on use.
func (e communicationEndpoint) logicalKey() string {
	if !e.valid() {
		return ""
	}
	if e.Kind == "pane" {
		return e.NodeID + ":pane:" + strings.ToLower(e.PaneID)
	}
	return e.NodeID + ":work:" + e.Work.Thread
}

func communicationEndpointPairID(a, b communicationEndpoint) string {
	x, y := a.logicalKey(), b.logicalKey()
	if x == "" || y == "" || x == y || a.NodeID == b.NodeID {
		return ""
	}
	keys := []string{x, y}
	sort.Strings(keys)
	digest := sha256.Sum256([]byte("relay-communication-endpoint-pair-v2\x00" + keys[0] + "\n" + keys[1]))
	return hex.EncodeToString(digest[:])
}

// communicationTypedRemoteLink extends the existing reciprocal, route-pinned
// relationship model without changing v1 pane-only link serialization.
type communicationTypedRemoteLink struct {
	Version               int                   `json:"version"`
	ID                    string                `json:"id"`
	Local                 communicationEndpoint `json:"local"`
	Peer                  communicationEndpoint `json:"peer"`
	RouteID               string                `json:"route_id"`
	RouteRevision         uint64                `json:"route_revision"`
	PeerCertificateSHA256 string                `json:"peer_certificate_sha256"`
	AllowedPeerCallers    []string              `json:"allowed_peer_callers"`
	PeerRevision          uint64                `json:"peer_revision"`
	Revision              uint64                `json:"revision"`
	// PinGeneration counts re-pins of the Work endpoint of this relationship.
	// It is monotonic on both hosts; zero means the pin was never repaired.
	PinGeneration uint64    `json:"pin_generation,omitempty"`
	Retired       bool      `json:"retired"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
}

func validTypedRemoteLink(link communicationTypedRemoteLink, localNode string) bool {
	if link.Version != 2 || !link.Local.valid() || !link.Peer.valid() || link.Local.NodeID != localNode ||
		link.Local.NodeID == link.Peer.NodeID || link.Local.Kind == link.Peer.Kind || link.ID != communicationEndpointPairID(link.Local, link.Peer) ||
		!canonicalRouteToken(link.RouteID) || link.RouteRevision == 0 || !remoteDigest(link.PeerCertificateSHA256) ||
		link.PeerRevision == 0 || link.Revision == 0 || link.CreatedAt.IsZero() || link.UpdatedAt.Before(link.CreatedAt) ||
		len(link.AllowedPeerCallers) == 0 || len(link.AllowedPeerCallers) > 128 {
		return false
	}
	previous := ""
	for _, caller := range link.AllowedPeerCallers {
		if !canonicalRouteToken(caller) || caller <= previous {
			return false
		}
		previous = caller
	}
	return true
}

// communicationTypedWorkMessage is the v2 common peer-message shape for a
// signed pane source and an exact Work target. It is not registered as a
// transport until link lifecycle and durable claims are integrated.
type communicationTypedWorkMessage struct {
	Version            int                   `json:"version"`
	LinkID             string                `json:"link_id"`
	Source             communicationEndpoint `json:"source"`
	Target             communicationEndpoint `json:"target"`
	SourceLinkRevision uint64                `json:"source_link_revision"`
	TargetLinkRevision uint64                `json:"target_link_revision"`
	CallerID           string                `json:"caller_id"`
	MessageID          string                `json:"message_id"`
	Fingerprint        string                `json:"fingerprint"`
	Text               string                `json:"text"`
	SourceSignature    string                `json:"source_signature"`
}

func communicationTypedWorkFingerprint(m communicationTypedWorkMessage) string {
	if m.Version != 2 || !m.Source.valid() || !m.Target.valid() || m.Source.Kind != "pane" || m.Target.Kind != "work" ||
		!remoteDigest(m.LinkID) || m.SourceLinkRevision == 0 || m.TargetLinkRevision == 0 ||
		!canonicalRouteToken(m.CallerID) || !validSessionID.MatchString(m.MessageID) ||
		len(m.Text) == 0 || len(m.Text) > 16384 || !utf8.ValidString(m.Text) || strings.TrimSpace(m.Text) == "" {
		return ""
	}
	canonical, err := json.Marshal(struct {
		Version            int                   `json:"version"`
		LinkID             string                `json:"link_id"`
		Source             communicationEndpoint `json:"source"`
		Target             communicationEndpoint `json:"target"`
		SourceLinkRevision uint64                `json:"source_link_revision"`
		TargetLinkRevision uint64                `json:"target_link_revision"`
		CallerID           string                `json:"caller_id"`
		MessageID          string                `json:"message_id"`
		TextSHA256         string                `json:"text_sha256"`
	}{m.Version, m.LinkID, m.Source, m.Target, m.SourceLinkRevision, m.TargetLinkRevision, m.CallerID, m.MessageID, communicationTextDigest(m.Text)})
	if err != nil {
		return ""
	}
	digest := sha256.Sum256(append([]byte("relay-communication-work-message-v2\x00"), canonical...))
	return hex.EncodeToString(digest[:])
}

// communicationVerifyTypedWorkDelivery binds a message to the previously
// authorized link, transport certificate and sender proof. The caller must
// additionally revalidate the active route and Work owner at admission, claim
// the message durably, and check them again immediately before delivery.
func communicationVerifyTypedWorkDelivery(link communicationTypedRemoteLink, localNode, peerCertificate string, m communicationTypedWorkMessage, now time.Time) error {
	if !validTypedRemoteLink(link, localNode) || link.Retired || link.Local.Kind != "work" || link.Peer.Kind != "pane" ||
		m.Source.Kind != "pane" || m.Target.Kind != "work" || m.LinkID != link.ID ||
		m.SourceLinkRevision != link.PeerRevision || m.TargetLinkRevision != link.Revision ||
		peerCertificate != link.PeerCertificateSHA256 || !containsCommunicationPane(link.AllowedPeerCallers, m.CallerID) ||
		!communicationEndpointEqual(m.Source, link.Peer) || !communicationEndpointEqual(m.Target, link.Local) ||
		m.Fingerprint == "" || m.Fingerprint != communicationTypedWorkFingerprint(m) {
		return errors.New("typed Work relationship changed or message invalid")
	}
	proof, err := communicationVerifyWorkMessage(m.SourceSignature,
		[]communicationTrustedNode{{NodeID: link.Peer.NodeID, CertificateSHA256: peerCertificate}}, now,
		m.Source.NodeID, m.Source.PaneID, m.Source.Provider, m.Source.SessionID, m.Target.NodeID, m.MessageID, m.LinkID, m.SourceLinkRevision, m.TargetLinkRevision, []byte(m.Text), *m.Target.Work)
	if err != nil {
		return err
	}
	if proof.Statement.ClientID != m.CallerID {
		return errors.New("signed caller does not match relationship")
	}
	return nil
}

func communicationEndpointEqual(a, b communicationEndpoint) bool {
	if a.NodeID != b.NodeID || a.Kind != b.Kind || a.PaneID != b.PaneID || a.Provider != b.Provider || a.SessionID != b.SessionID {
		return false
	}
	if a.Work == nil || b.Work == nil {
		return a.Work == nil && b.Work == nil
	}
	return *a.Work == *b.Work
}

// readTypedRemoteLink reads only the typed v2 format and rejects ambiguous
// storage. It never follows a different link on an identity conflict.
func readTypedRemoteLink(root, node, id string) (communicationTypedRemoteLink, error) {
	var link communicationTypedRemoteLink
	if !remoteDigest(id) {
		return link, errors.New("invalid typed relationship identity")
	}
	path := remoteLinkPath(root, id)
	if err := privateBindingObject(path, false); err != nil {
		return link, err
	}
	file, err := OpenPrivateFile(path, os.O_RDONLY)
	if err != nil {
		return link, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, communicationEnvelopeLimit+1))
	if err != nil || len(data) > communicationEnvelopeLimit || communicationStrictWorkJSON(data, &link) != nil || !validTypedRemoteLink(link, node) || link.ID != id {
		return communicationTypedRemoteLink{}, errors.New("typed relationship unavailable")
	}
	return link, nil
}

// communicationReadTypedAuthorizedLink runs under the existing communication
// metadata lock. It revalidates the relationship, receive policy and active
// pinned peer route without network I/O.
func communicationReadTypedAuthorizedLink(ctx context.Context, root, node, id string) (communicationTypedRemoteLink, error) {
	var empty communicationTypedRemoteLink
	if err := ctx.Err(); err != nil {
		return empty, err
	}
	if _, err := communicationAuthorize(root, CommunicationRequest{Operation: "remote_receive"}); err != nil {
		return empty, err
	}
	return communicationReadTypedActiveLink(ctx, root, node, id)
}

// communicationReadTypedActiveLink checks the local link and pinned transport;
// callers separately authorize the relevant send or receive policy.
func communicationReadTypedActiveLink(ctx context.Context, root, node, id string) (communicationTypedRemoteLink, error) {
	var empty communicationTypedRemoteLink
	if err := ctx.Err(); err != nil {
		return empty, err
	}
	link, err := readTypedRemoteLink(root, node, id)
	if err != nil || link.Retired {
		return empty, errors.New("typed relationship unavailable")
	}
	route, _, cert, err := activePeerRoute(root, node, link.RouteID)
	if err != nil || cert == nil || route.Revision != link.RouteRevision || route.PeerNodeID != link.Peer.NodeID || peerFingerprint(cert) != link.PeerCertificateSHA256 {
		return empty, errors.New("typed relationship route changed")
	}
	if err := ctx.Err(); err != nil {
		return empty, err
	}
	return link, nil
}
