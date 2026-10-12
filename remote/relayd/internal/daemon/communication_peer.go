package daemon

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Public enrollment data. Private identity keys never leave their local file.
type CommunicationPeerBinding struct {
	Version        int    `json:"version"`
	ID             string `json:"id"`
	NodeID         string `json:"node_id"`
	PeerNodeID     string `json:"peer_node_id"`
	Endpoint       string `json:"endpoint"`
	CertificatePEM string `json:"certificate_pem"`
}
type communicationPeerIdentity struct {
	Version        int    `json:"version"`
	NodeID         string `json:"node_id"`
	CertificatePEM string `json:"certificate_pem"`
	PrivateKeyPEM  string `json:"private_key_pem"`
}
type communicationPeerProof struct {
	Version int    `json:"version"`
	NodeID  string `json:"node_id"`
	Nonce   string `json:"nonce"`
}

func peerCertificate(text, node string) (*x509.Certificate, error) {
	return peerCertificateValidation(text, node, true)
}
func peerCertificateValidation(text, node string, checkTime bool) (*x509.Certificate, error) {
	block, rest := pem.Decode([]byte(text))
	if block == nil || block.Type != "CERTIFICATE" || len(bytes.TrimSpace(rest)) != 0 || len(text) > 8192 {
		return nil, errors.New("one peer certificate required")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, errors.New("invalid peer certificate")
	}
	now := time.Now()
	if !cert.IsCA || !cert.BasicConstraintsValid || (checkTime && (now.Before(cert.NotBefore) || !now.Before(cert.NotAfter))) ||
		cert.VerifyHostname(node+".relay.invalid") != nil || cert.CheckSignatureFrom(cert) != nil {
		return nil, errors.New("peer certificate identity or validity mismatch")
	}
	return cert, nil
}
func peerFingerprint(cert *x509.Certificate) string {
	hash := sha256.Sum256(cert.Raw)
	return hex.EncodeToString(hash[:])
}
func peerIdentity(root, node string) (communicationPeerIdentity, tls.Certificate, error) {
	var identity communicationPeerIdentity
	err := communicationRead(filepath.Join(root, "peer-identity.json"), &identity)
	if err != nil {
		return identity, tls.Certificate{}, err
	}
	if identity.Version != 1 || identity.NodeID != node {
		return identity, tls.Certificate{}, errors.New("peer identity node mismatch")
	}
	if _, err := peerCertificate(identity.CertificatePEM, node); err != nil {
		return identity, tls.Certificate{}, err
	}
	pair, err := tls.X509KeyPair([]byte(identity.CertificatePEM), []byte(identity.PrivateKeyPEM))
	return identity, pair, err
}
func peerBinding(root, node, id string) (CommunicationPeerBinding, *x509.Certificate, error) {
	var b CommunicationPeerBinding
	if !canonicalRouteToken(id) {
		return b, nil, errors.New("valid binding identity required")
	}
	if err := communicationRead(filepath.Join(root, "peer-binding-"+id+".json"), &b); err != nil {
		return b, nil, err
	}
	cert, err := validPeerBinding(b, node)
	if b.ID != id {
		return b, nil, errors.New("peer binding file identity mismatch")
	}
	return b, cert, err
}
func validPeerBinding(b CommunicationPeerBinding, node string) (*x509.Certificate, error) {
	host, port, err := net.SplitHostPort(b.Endpoint)
	n, numberErr := strconv.Atoi(port)
	if b.Version != 1 || b.NodeID != node || !canonicalRouteToken(b.ID) || !canonicalRouteToken(b.PeerNodeID) ||
		b.PeerNodeID == node || err != nil || host == "" || strings.ContainsAny(host, "/\\?#@ \t\r\n") || numberErr != nil || n < 1 || n > 65535 {
		return nil, errors.New("invalid peer binding")
	}
	return peerCertificate(b.CertificatePEM, b.PeerNodeID)
}
func communicationPeerConfiguration(root, node string, r CommunicationRequest) (map[string]any, error) {
	switch r.Operation {
	case "route_identity_rotate":
		var previous communicationPeerIdentity
		if err := communicationRead(filepath.Join(root, "peer-identity.json"), &previous); err != nil {
			return nil, err
		}
		if previous.Version != 1 || previous.NodeID != node {
			return nil, errors.New("peer identity node mismatch")
		}
		cert, err := peerCertificateValidation(previous.CertificatePEM, node, false)
		if err != nil {
			return nil, err
		}
		if _, err := tls.X509KeyPair([]byte(previous.CertificatePEM), []byte(previous.PrivateKeyPEM)); err != nil {
			return nil, errors.New("invalid peer identity key")
		}
		fingerprint := peerFingerprint(cert)
		if r.ExpectedIdentitySHA256 != fingerprint {
			return nil, errors.New("peer identity fingerprint conflict")
		}
		archivePath := filepath.Join(root, "peer-identity-retired-"+fingerprint+".json")
		var archived communicationPeerIdentity
		archiveErr := communicationRead(archivePath, &archived)
		if archiveErr == nil && archived != previous {
			return nil, errors.New("retired identity archive mismatch")
		}
		if archiveErr != nil {
			if !errors.Is(archiveErr, os.ErrNotExist) {
				return nil, archiveErr
			}
			archives, err := filepath.Glob(filepath.Join(root, "peer-identity-retired-*.json"))
			if err != nil {
				return nil, err
			}
			if len(archives) >= 32 {
				return nil, errors.New("retired identity archive limit reached")
			}
			if err := communicationAtomic(archivePath, previous); err != nil {
				return nil, err
			}
		}
		identity, err := newPeerIdentity(node)
		if err != nil {
			return nil, err
		}
		if err := communicationAtomic(filepath.Join(root, "peer-identity.json"), identity); err != nil {
			return nil, err
		}
		if err := communicationEvent(root, node, "communication_peer_identity_rotated", []map[string]string{{"retired_certificate_sha256": fingerprint}}); err != nil {
			return nil, errors.New("peer identity rotated but event append failed; inspect current fingerprint before recovery")
		}
		return communicationPeerConfiguration(root, node, CommunicationRequest{Operation: "route_identity_get"})
	case "route_identity_create", "route_identity_get":
		identity, _, err := peerIdentity(root, node)
		if errors.Is(err, os.ErrNotExist) && r.Operation == "route_identity_create" {
			identity, err = newPeerIdentity(node)
			if err != nil {
				return nil, err
			}
			if err := communicationAtomic(filepath.Join(root, "peer-identity.json"), identity); err != nil {
				return nil, err
			}
			if err := communicationEvent(root, node, "communication_peer_identity_created", nil); err != nil {
				return nil, errors.New("peer identity saved but event append failed; inspect before recovery")
			}
		} else if err != nil {
			return nil, err
		}
		cert, err := peerCertificate(identity.CertificatePEM, node)
		if err != nil {
			return nil, err
		}
		return map[string]any{"node_id": node, "certificate_pem": identity.CertificatePEM, "certificate_sha256": peerFingerprint(cert), "authority": "relayd"}, nil
	case "route_binding_set":
		if r.PeerBinding == nil {
			return nil, errors.New("peer binding required")
		}
		b := *r.PeerBinding
		b.Version, b.NodeID = 1, node
		b.ID, b.PeerNodeID = strings.ToLower(b.ID), strings.ToLower(b.PeerNodeID)
		cert, err := validPeerBinding(b, node)
		if err != nil {
			return nil, err
		}
		previous, _, readErr := peerBinding(root, node, b.ID)
		if readErr == nil {
			if previous != b {
				return nil, errors.New("peer binding is immutable; use a new binding identity")
			}
		} else {
			if !errors.Is(readErr, os.ErrNotExist) {
				return nil, readErr
			}
			paths, err := filepath.Glob(filepath.Join(root, "peer-binding-*.json"))
			if err != nil {
				return nil, err
			}
			if len(paths) >= communicationMaxRoutes {
				return nil, errors.New("peer binding limit reached")
			}
			if err := communicationAtomic(filepath.Join(root, "peer-binding-"+b.ID+".json"), b); err != nil {
				return nil, err
			}
			if err := communicationEvent(root, node, "communication_peer_binding_created", []map[string]string{{"binding_id": b.ID, "peer_node_id": b.PeerNodeID}}); err != nil {
				return nil, errors.New("binding saved but event append failed; inspect before recovery")
			}
		}
		return map[string]any{"binding": b, "certificate_sha256": peerFingerprint(cert), "authority": "relayd", "connectivity": "unverified"}, nil
	case "route_binding_get":
		b, cert, err := peerBinding(root, node, strings.ToLower(r.TransportBindingID))
		if err != nil {
			return nil, err
		}
		return map[string]any{"binding": b, "certificate_sha256": peerFingerprint(cert), "authority": "relayd", "connectivity": "unverified"}, nil
	}
	return nil, errors.New("unsupported peer configuration operation")
}

func newPeerIdentity(node string) (communicationPeerIdentity, error) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return communicationPeerIdentity{}, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return communicationPeerIdentity{}, err
	}
	now := time.Now().UTC()
	template := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: node}, DNSNames: []string{node + ".relay.invalid"},
		NotBefore: now.Add(-time.Minute), NotAfter: now.Add(90 * 24 * time.Hour), IsCA: true, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, public, private)
	if err != nil {
		return communicationPeerIdentity{}, err
	}
	key, err := x509.MarshalPKCS8PrivateKey(private)
	if err != nil {
		return communicationPeerIdentity{}, err
	}
	return communicationPeerIdentity{Version: 1, NodeID: node, CertificatePEM: string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})),
		PrivateKeyPEM: string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key}))}, nil
}

func activePeerRoute(root, node, id string) (communicationRoute, CommunicationPeerBinding, *x509.Certificate, error) {
	var route communicationRoute
	if !canonicalRouteToken(id) {
		return route, CommunicationPeerBinding{}, nil, errors.New("valid route identity required")
	}
	if err := communicationRead(filepath.Join(root, "route-"+id+".json"), &route); err != nil {
		return route, CommunicationPeerBinding{}, nil, err
	}
	if !validCommunicationRoute(route, node) || route.ID != id || route.Retired {
		return route, CommunicationPeerBinding{}, nil, errors.New("active local route required")
	}
	b, cert, err := peerBinding(root, node, route.TransportBindingID)
	if err == nil && b.PeerNodeID != route.PeerNodeID {
		err = errors.New("route peer binding mismatch")
	}
	return route, b, cert, err
}

func communicationPeerProbe(root, node string, r CommunicationRequest) (map[string]any, error) {
	var route communicationRoute
	var b CommunicationPeerBinding
	var cert *x509.Certificate
	var pair tls.Certificate
	err := communicationFanoutLocked(root, func() error {
		if _, err := communicationAuthorize(root, r); err != nil {
			return err
		}
		var err error
		route, b, cert, err = activePeerRoute(root, node, strings.ToLower(r.RouteID))
		if err != nil {
			return err
		}
		if r.ExpectedRouteRevision != route.Revision {
			return errors.New("communication route revision conflict")
		}
		_, pair, err = peerIdentity(root, node)
		return err
	})
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	pool.AddCert(cert)
	transport := &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS13, ServerName: b.PeerNodeID + ".relay.invalid", RootCAs: pool, Certificates: []tls.Certificate{pair},
		VerifyConnection: func(state tls.ConnectionState) error {
			if len(state.PeerCertificates) == 0 || !state.PeerCertificates[0].Equal(cert) {
				return errors.New("peer certificate pin mismatch")
			}
			return nil
		}},
		DialContext: (&net.Dialer{Timeout: 3 * time.Second}).DialContext, TLSHandshakeTimeout: 3 * time.Second, ResponseHeaderTimeout: 3 * time.Second, MaxResponseHeaderBytes: 8192, DisableKeepAlives: true}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("peer redirect rejected") }}
	nonceBytes := make([]byte, 32)
	if _, err := rand.Read(nonceBytes); err != nil {
		return nil, err
	}
	proof := communicationPeerProof{Version: 1, NodeID: node, Nonce: hex.EncodeToString(nonceBytes)}
	body, _ := json.Marshal(proof)
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://"+b.Endpoint+"/relay-peer/probe", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	response, err := client.Do(req)
	if err != nil {
		return nil, errors.New("peer probe unavailable or authentication failed")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, errors.New("peer probe rejected")
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, 1025))
	var reply communicationPeerProof
	if err != nil || len(data) > 1024 || json.Unmarshal(data, &reply) != nil || reply.Version != 1 || reply.NodeID != b.PeerNodeID || reply.Nonce != proof.Nonce {
		return nil, errors.New("peer proof mismatch")
	}
	err = communicationFanoutLocked(root, func() error {
		if _, err := communicationAuthorize(root, r); err != nil {
			return err
		}
		current, _, _, err := activePeerRoute(root, node, route.ID)
		if err != nil {
			return err
		}
		if current.Revision != route.Revision {
			return errors.New("route changed during probe")
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{"authority": "relayd", "route_id": route.ID, "route_revision": route.Revision, "peer_node_id": b.PeerNodeID,
		"certificate_sha256": peerFingerprint(cert), "connectivity": "verified", "verified_at": time.Now().UTC(), "delivery_enabled": false}, nil
}

// Trust is rebuilt from active route records for every TLS handshake, and
// checked again per request. Retirement does not leave a cached authorization.
func peerServerTLS(root, node string) (*tls.Config, error) {
	_, pair, err := peerIdentity(root, node)
	if err != nil {
		return nil, err
	}
	return &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{pair}, GetConfigForClient: func(*tls.ClientHelloInfo) (*tls.Config, error) {
		_, currentPair, err := peerIdentity(root, node)
		if err != nil {
			return nil, err
		}
		pool := x509.NewCertPool()
		pins := map[string]bool{}
		err = communicationFanoutLocked(root, func() error {
			routes, err := communicationReadRoutes(root, node)
			if err != nil {
				return err
			}
			for _, route := range routes {
				if route.Retired {
					continue
				}
				_, _, cert, err := activePeerRoute(root, node, route.ID)
				if err != nil {
					return err
				}
				pool.AddCert(cert)
				pins[peerFingerprint(cert)] = true
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
		return &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{currentPair}, ClientAuth: tls.RequireAndVerifyClientCert, ClientCAs: pool,
			VerifyConnection: func(state tls.ConnectionState) error {
				if len(state.PeerCertificates) == 0 || !pins[peerFingerprint(state.PeerCertificates[0])] {
					return errors.New("unreviewed peer certificate")
				}
				return nil
			}}, nil
	}}, nil
}
func peerProbeHandler(root, node string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		if r.Method != http.MethodPost || r.URL.Path != "/relay-peer/probe" || r.URL.RawQuery != "" || r.TLS == nil || len(r.TLS.PeerCertificates) == 0 {
			http.Error(w, "rejected", http.StatusForbidden)
			return
		}
		data, err := io.ReadAll(io.LimitReader(r.Body, 1025))
		var proof communicationPeerProof
		if err != nil || len(data) > 1024 || json.Unmarshal(data, &proof) != nil || proof.Version != 1 || !canonicalRouteToken(proof.NodeID) {
			http.Error(w, "invalid proof", http.StatusBadRequest)
			return
		}
		nonce, nonceErr := hex.DecodeString(proof.Nonce)
		if nonceErr != nil || len(nonce) != 32 || proof.Nonce != strings.ToLower(proof.Nonce) {
			http.Error(w, "invalid nonce", http.StatusBadRequest)
			return
		}
		err = communicationFanoutLocked(root, func() error {
			routes, err := communicationReadRoutes(root, node)
			if err != nil {
				return err
			}
			for _, route := range routes {
				if route.Retired || route.PeerNodeID != proof.NodeID {
					continue
				}
				_, _, cert, err := activePeerRoute(root, node, route.ID)
				if err != nil {
					return err
				}
				if r.TLS.PeerCertificates[0].Equal(cert) {
					return nil
				}
			}
			return errors.New("unreviewed peer")
		})
		if err != nil {
			http.Error(w, "unreviewed peer", http.StatusForbidden)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(communicationPeerProof{Version: 1, NodeID: node, Nonce: proof.Nonce})
	})
}

// The owner explicitly starts this service; no existing daemon/pane is replaced.
func ServeCommunicationPeers(address string) error {
	root, node := communicationRoot(), currentCommunicationNodeID()
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return err
	}
	defer listener.Close()
	return serveCommunicationPeerListener(root, node, listener)
}

func serveCommunicationPeerListener(root, node string, listener net.Listener) error {
	config, err := peerServerTLS(root, node)
	if err != nil {
		return err
	}
	server := &http.Server{Handler: peerHandler(root, node, communicationGroupNative{observe: communicationObserve, send: communicationNative}), TLSConfig: config,
		ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 35 * time.Second, IdleTimeout: 5 * time.Second, MaxHeaderBytes: 8192}
	bounded := &peerLimitedListener{Listener: listener, slots: make(chan struct{}, 64), done: make(chan struct{})}
	defer bounded.Close()
	return server.Serve(tls.NewListener(bounded, config))
}

type peerLimitedListener struct {
	net.Listener
	slots chan struct{}
	done  chan struct{}
	once  sync.Once
}

func (l *peerLimitedListener) Close() error {
	l.once.Do(func() { close(l.done) })
	return l.Listener.Close()
}
func (l *peerLimitedListener) Accept() (net.Conn, error) {
	select {
	case l.slots <- struct{}{}:
	case <-l.done:
		return nil, net.ErrClosed
	}
	connection, err := l.Listener.Accept()
	if err != nil {
		<-l.slots
		return nil, err
	}
	return &peerLimitedConn{Conn: connection, release: func() { <-l.slots }}, nil
}

type peerLimitedConn struct {
	net.Conn
	once    sync.Once
	release func()
}

func (c *peerLimitedConn) Close() error {
	err := c.Conn.Close()
	c.once.Do(c.release)
	return err
}
