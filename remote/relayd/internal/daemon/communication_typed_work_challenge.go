package daemon

// The challenge uses the existing authenticated /relay-peer/message transport.
// These functions are not registered until a cross-node transition barrier is
// proven; a fresh observation alone is not a continuous admission fence.
import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"
)

type communicationTypedWorkChallenge struct {
	Version   int                           `json:"version"`
	Operation string                        `json:"operation"`
	Nonce     string                        `json:"nonce"`
	Message   communicationTypedWorkMessage `json:"message"`
}
type communicationTypedWorkChallengeResponse struct {
	Version     int    `json:"version"`
	Observation string `json:"observation"`
}

func communicationHandleTypedWorkChallenge(root, node string, d communicationSigningDeps) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		if r.Method != http.MethodPost || r.URL.Path != "/relay-peer/message" || r.URL.RawQuery != "" || r.TLS == nil || len(r.TLS.PeerCertificates) == 0 {
			http.Error(w, "rejected", http.StatusForbidden)
			return
		}
		data, err := io.ReadAll(io.LimitReader(r.Body, 128<<10+1))
		var q communicationTypedWorkChallenge
		if err != nil || len(data) > 128<<10 || communicationStrictWorkJSONLimit(data, &q, 128<<10) != nil || q.Version != 2 || q.Operation != "work_observe" || !remoteDigest(q.Nonce) {
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}
		observation, err := communicationSignTypedWorkObservation(r.Context(), root, node, peerFingerprint(r.TLS.PeerCertificates[0]), q.Nonce, q.Message, d)
		if err != nil {
			http.Error(w, "rejected", http.StatusForbidden)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(communicationTypedWorkChallengeResponse{Version: 2, Observation: observation})
	})
}

// communicationTypedWorkSourceFresh reuses the common mTLS peer route. It
// checks the route before and after transport, verifies a fresh nonce-bound
// observation and never treats the observation as an atomic transition fence.
func communicationTypedWorkSourceFresh(ctx context.Context, root, node string, m communicationTypedWorkMessage) error {
	ctx, cancel := context.WithTimeout(ctx, communicationWorkObservationTTL)
	defer cancel()
	var link communicationTypedRemoteLink
	var binding CommunicationPeerBinding
	var nonceBytes [32]byte
	if _, err := io.ReadFull(rand.Reader, nonceBytes[:]); err != nil {
		return err
	}
	nonce := hex.EncodeToString(nonceBytes[:])
	err := communicationFanoutLocked(root, func() error {
		var err error
		link, err = communicationReadTypedAuthorizedLink(ctx, root, node, m.LinkID)
		if err != nil {
			return err
		}
		if err = communicationVerifyTypedWorkDelivery(link, node, link.PeerCertificateSHA256, m, time.Now().UTC()); err != nil {
			return err
		}
		route, b, cert, err := activePeerRoute(root, node, link.RouteID)
		if err != nil || cert == nil || route.Revision != link.RouteRevision || peerFingerprint(cert) != link.PeerCertificateSHA256 {
			return errors.New("peer route changed")
		}
		binding = b
		return nil
	})
	if err != nil {
		return err
	}
	body, err := json.Marshal(communicationTypedWorkChallenge{Version: 2, Operation: "work_observe", Nonce: nonce, Message: m})
	if err != nil {
		return err
	}
	response, err := remotePeerPost(ctx, root, node, binding, body)
	if err != nil {
		return err
	}
	var result communicationTypedWorkChallengeResponse
	if communicationStrictWorkJSON(response, &result) != nil || result.Version != 2 || result.Observation == "" {
		return errors.New("invalid source observation response")
	}
	if err := communicationVerifyTypedWorkObservation(result.Observation, nonce, link, m, time.Now().UTC()); err != nil {
		return err
	}
	return communicationFanoutLocked(root, func() error {
		current, err := communicationReadTypedAuthorizedLink(ctx, root, node, m.LinkID)
		if err != nil {
			return err
		}
		if current.Revision != link.Revision || current.PeerRevision != link.PeerRevision || current.RouteID != link.RouteID || current.RouteRevision != link.RouteRevision || current.PeerCertificateSHA256 != link.PeerCertificateSHA256 || !communicationEndpointEqual(current.Local, link.Local) || !communicationEndpointEqual(current.Peer, link.Peer) {
			return errors.New("typed relationship changed during observation")
		}
		route, after, cert, err := activePeerRoute(root, node, current.RouteID)
		if err != nil || cert == nil || route.Revision != current.RouteRevision || peerFingerprint(cert) != current.PeerCertificateSHA256 || after != binding {
			return errors.New("peer route changed during observation")
		}
		return ctx.Err()
	})
}
