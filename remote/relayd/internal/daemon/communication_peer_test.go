package daemon

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func peerFixture(t *testing.T, node string) (string, string) {
	t.Helper()
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	if err := communicationAtomic(communicationPolicyPath(root), communicationPolicy{}); err != nil {
		t.Fatal(err)
	}
	result, err := communicationPeerConfiguration(root, node, CommunicationRequest{Operation: "route_identity_create"})
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal(result)
	if strings.Contains(string(encoded), "PRIVATE KEY") || strings.Contains(string(encoded), "private_key") {
		t.Fatal("private key exposed")
	}
	return root, result["certificate_pem"].(string)
}
func enrollPeer(t *testing.T, root, node, peer, endpoint, certificate string) {
	t.Helper()
	b := CommunicationPeerBinding{ID: "binding", PeerNodeID: peer, Endpoint: endpoint, CertificatePEM: certificate}
	if _, err := communicationPeerConfiguration(root, node, CommunicationRequest{Operation: "route_binding_set", PeerBinding: &b}); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationRouteOperation(root, node, CommunicationRequest{Operation: "route_set", RouteID: "route", PeerNodeID: peer, TransportBindingID: "binding"}); err != nil {
		t.Fatal(err)
	}
}
func peerFixtureServer(t *testing.T, root, node string) *httptest.Server {
	t.Helper()
	config, err := peerServerTLS(root, node)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewUnstartedServer(peerProbeHandler(root, node))
	server.TLS = config
	server.Config.ErrorLog = log.New(io.Discard, "", 0)
	server.StartTLS()
	t.Cleanup(server.Close)
	return server
}

func TestCommunicationPeerMutualTLSProbeAndRetirement(t *testing.T) {
	a, acert := peerFixture(t, "node-a")
	b, bcert := peerFixture(t, "node-b")
	server := peerFixtureServer(t, b, "node-b")
	enrollPeer(t, a, "node-a", "node-b", strings.TrimPrefix(server.URL, "https://"), bcert)
	enrollPeer(t, b, "node-b", "node-a", "127.0.0.1:1", acert)
	r := CommunicationRequest{Operation: "route_probe", RouteID: "route", ExpectedRouteRevision: 1}
	result, err := communicationPeerProbe(a, "node-a", r)
	if err != nil {
		t.Fatal(err)
	}
	if result["connectivity"] != "verified" || result["delivery_enabled"] != false || result["peer_node_id"] != "node-b" {
		t.Fatal(result)
	}
	// Retirement on the receiving daemon revokes trust on the next handshake.
	if _, err := communicationRouteOperation(b, "node-b", CommunicationRequest{Operation: "route_retire", RouteID: "route", ExpectedRouteRevision: 1}); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationPeerProbe(a, "node-a", r); err == nil {
		t.Fatal("retired receiving route accepted")
	}
}

func TestCommunicationPeerRejectsUnreviewedClientAndWrongServerPin(t *testing.T) {
	a, acert := peerFixture(t, "node-a")
	b, bcert := peerFixture(t, "node-b")
	server := peerFixtureServer(t, b, "node-b")
	enrollPeer(t, a, "node-a", "node-b", strings.TrimPrefix(server.URL, "https://"), bcert)
	r := CommunicationRequest{Operation: "route_probe", RouteID: "route", ExpectedRouteRevision: 1}
	if _, err := communicationPeerProbe(a, "node-a", r); err == nil {
		t.Fatal("unenrolled client accepted")
	}
	enrollPeer(t, b, "node-b", "node-a", "127.0.0.1:1", acert)
	_, otherCert := peerFixture(t, "node-b")
	var binding CommunicationPeerBinding
	path := filepath.Join(a, "peer-binding-binding.json")
	if err := communicationRead(path, &binding); err != nil {
		t.Fatal(err)
	}
	binding.CertificatePEM = otherCert
	if err := communicationAtomic(path, binding); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationPeerProbe(a, "node-a", r); err == nil {
		t.Fatal("wrong server certificate accepted")
	}
}

func TestCommunicationPeerConfigurationPinsAndKeepsKeysPrivate(t *testing.T) {
	a, _ := peerFixture(t, "node-a")
	_, bcert := peerFixture(t, "node-b")
	first, err := communicationPeerConfiguration(a, "node-a", CommunicationRequest{Operation: "route_identity_get"})
	if err != nil {
		t.Fatal(err)
	}
	second, err := communicationPeerConfiguration(a, "node-a", CommunicationRequest{Operation: "route_identity_create"})
	if err != nil || first["certificate_sha256"] != second["certificate_sha256"] {
		t.Fatal("identity regenerated", err)
	}
	info, err := os.Stat(filepath.Join(a, "peer-identity.json"))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("identity permissions", err)
	}
	b := CommunicationPeerBinding{ID: "binding", PeerNodeID: "node-b", Endpoint: "127.0.0.1:1", CertificatePEM: bcert}
	for _, endpoint := range []string{"https://example.invalid", "example.invalid:0", "example.invalid:65536", "user@host:12", "host/path:12"} {
		bad := b
		bad.Endpoint = endpoint
		if _, err := communicationPeerConfiguration(a, "node-a", CommunicationRequest{Operation: "route_binding_set", PeerBinding: &bad}); err == nil {
			t.Fatal("unsafe endpoint accepted", endpoint)
		}
	}
	bad := b
	bad.PeerNodeID = "other-peer"
	if _, err := communicationPeerConfiguration(a, "node-a", CommunicationRequest{Operation: "route_binding_set", PeerBinding: &bad}); err == nil {
		t.Fatal("certificate identity mismatch accepted")
	}
	if _, err := communicationPeerConfiguration(a, "node-a", CommunicationRequest{Operation: "route_binding_set", PeerBinding: &b}); err != nil {
		t.Fatal(err)
	}
	b.Endpoint = "127.0.0.1:2"
	if _, err := communicationPeerConfiguration(a, "node-a", CommunicationRequest{Operation: "route_binding_set", PeerBinding: &b}); err == nil {
		t.Fatal("binding repointed")
	}
}

func TestCommunicationPeerProbeRequiresCurrentRouteAndOwner(t *testing.T) {
	a, acert := peerFixture(t, "node-a")
	b, bcert := peerFixture(t, "node-b")
	server := peerFixtureServer(t, b, "node-b")
	enrollPeer(t, a, "node-a", "node-b", strings.TrimPrefix(server.URL, "https://"), bcert)
	enrollPeer(t, b, "node-b", "node-a", "127.0.0.1:1", acert)
	for _, r := range []CommunicationRequest{
		{Operation: "route_probe", RouteID: "route", ExpectedRouteRevision: 2},
		{Operation: "route_probe", RouteID: "route", ExpectedRouteRevision: 1, ClientToken: "provider-token"},
		{Operation: "route_probe", RouteID: "route", ExpectedRouteRevision: 1, ActorPaneID: testGroupA},
	} {
		if _, err := communicationPeerProbe(a, "node-a", r); err == nil {
			t.Fatal("invalid probe authorized")
		}
	}
}

func TestCommunicationPeerHandlerRejectsIdentitySpoofAndOversize(t *testing.T) {
	_, acert := peerFixture(t, "node-a")
	b, _ := peerFixture(t, "node-b")
	enrollPeer(t, b, "node-b", "node-a", "127.0.0.1:1", acert)
	clientCert, err := peerCertificate(acert, "node-a")
	if err != nil {
		t.Fatal(err)
	}
	for _, body := range []string{
		`{"version":1,"node_id":"spoofed-node","nonce":"` + strings.Repeat("a", 64) + `"}`,
		`{"version":1,"node_id":"node-a","nonce":"short"}`,
		strings.Repeat("x", 1025),
	} {
		request := httptest.NewRequest(http.MethodPost, "https://relay.invalid/relay-peer/probe", strings.NewReader(body))
		request.TLS = &tls.ConnectionState{PeerCertificates: []*x509.Certificate{clientCert}}
		response := httptest.NewRecorder()
		peerProbeHandler(b, "node-b").ServeHTTP(response, request)
		if response.Code == http.StatusOK {
			t.Fatal("invalid peer proof accepted")
		}
	}
}

func TestCommunicationPeerSubprocessHelper(t *testing.T) {
	root := os.Getenv("RELAY_TEST_PEER_ROOT")
	if root == "" {
		return
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	_, _ = io.WriteString(os.Stdout, listener.Addr().String()+"\n")
	if err := serveCommunicationPeerListener(root, "node-b", listener); err != nil {
		t.Fatal(err)
	}
}

func TestCommunicationPeerSeparateDaemonProcess(t *testing.T) {
	a, acert := peerFixture(t, "node-a")
	b, bcert := peerFixture(t, "node-b")
	enrollPeer(t, b, "node-b", "node-a", "127.0.0.1:1", acert)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestCommunicationPeerSubprocessHelper$")
	command.Env = append(os.Environ(), "RELAY_TEST_PEER_ROOT="+b)
	stdout, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	command.Stderr = io.Discard
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { cancel(); _ = command.Wait() }()
	address, err := bufio.NewReader(stdout).ReadString('\n')
	if err != nil {
		t.Fatal("peer process readiness", err)
	}
	enrollPeer(t, a, "node-a", "node-b", strings.TrimSpace(address), bcert)
	result, err := communicationPeerProbe(a, "node-a", CommunicationRequest{Operation: "route_probe", RouteID: "route", ExpectedRouteRevision: 1})
	if err != nil || result["connectivity"] != "verified" {
		t.Fatal("separate process proof", result, err)
	}
}

func TestCommunicationPeerRetirementRevokesExistingConnection(t *testing.T) {
	_, acert := peerFixture(t, "node-a")
	b, _ := peerFixture(t, "node-b")
	enrollPeer(t, b, "node-b", "node-a", "127.0.0.1:1", acert)
	cert, err := peerCertificate(acert, "node-a")
	if err != nil {
		t.Fatal(err)
	}
	request := func() *http.Request {
		r := httptest.NewRequest(http.MethodPost, "https://relay.invalid/relay-peer/probe", strings.NewReader(`{"version":1,"node_id":"node-a","nonce":"`+strings.Repeat("a", 64)+`"}`))
		r.TLS = &tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}}
		return r
	}
	response := httptest.NewRecorder()
	peerProbeHandler(b, "node-b").ServeHTTP(response, request())
	if response.Code != http.StatusOK {
		t.Fatal("reviewed peer rejected")
	}
	if _, err := communicationRouteOperation(b, "node-b", CommunicationRequest{Operation: "route_retire", RouteID: "route", ExpectedRouteRevision: 1}); err != nil {
		t.Fatal(err)
	}
	response = httptest.NewRecorder()
	peerProbeHandler(b, "node-b").ServeHTTP(response, request())
	if response.Code != http.StatusForbidden {
		t.Fatal("existing TLS state retained authority after retirement")
	}
}

func TestCommunicationPeerIdentityRotationCASAndLiveHandshake(t *testing.T) {
	a, acert := peerFixture(t, "node-a")
	b, bcert := peerFixture(t, "node-b")
	server := peerFixtureServer(t, b, "node-b")
	enrollPeer(t, a, "node-a", "node-b", strings.TrimPrefix(server.URL, "https://"), bcert)
	enrollPeer(t, b, "node-b", "node-a", "127.0.0.1:1", acert)
	var previous communicationPeerIdentity
	if err := communicationRead(filepath.Join(b, "peer-identity.json"), &previous); err != nil {
		t.Fatal(err)
	}
	cert, err := peerCertificate(bcert, "node-b")
	if err != nil {
		t.Fatal(err)
	}
	fingerprint := peerFingerprint(cert)
	r := CommunicationRequest{Operation: "route_identity_rotate", ExpectedIdentitySHA256: fingerprint}
	wrong := r
	wrong.ExpectedIdentitySHA256 = strings.Repeat("0", 64)
	if _, err := communicationRouteOperation(b, "node-b", wrong); err == nil {
		t.Fatal("identity rotation ignored expected fingerprint")
	}
	result, err := communicationRouteOperation(b, "node-b", r)
	if err != nil || result["certificate_sha256"] == fingerprint {
		t.Fatal("rotation failed", err)
	}
	if _, err := communicationRouteOperation(b, "node-b", r); err == nil {
		t.Fatal("rotation replay accepted")
	}
	var archive communicationPeerIdentity
	archivePath := filepath.Join(b, "peer-identity-retired-"+fingerprint+".json")
	if err := communicationRead(archivePath, &archive); err != nil || archive != previous {
		t.Fatal("old identity not retained", err)
	}
	info, err := os.Stat(archivePath)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("archive permissions", err)
	}
	probe := CommunicationRequest{Operation: "route_probe", RouteID: "route", ExpectedRouteRevision: 1}
	if _, err := communicationPeerProbe(a, "node-a", probe); err == nil {
		t.Fatal("running service kept old identity on new handshake")
	}
	if _, err := communicationRouteOperation(a, "node-a", CommunicationRequest{Operation: "route_retire", RouteID: "route", ExpectedRouteRevision: 1}); err != nil {
		t.Fatal(err)
	}
	newBinding := CommunicationPeerBinding{ID: "renewed-binding", PeerNodeID: "node-b", Endpoint: strings.TrimPrefix(server.URL, "https://"), CertificatePEM: result["certificate_pem"].(string)}
	if _, err := communicationPeerConfiguration(a, "node-a", CommunicationRequest{Operation: "route_binding_set", PeerBinding: &newBinding}); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationRouteOperation(a, "node-a", CommunicationRequest{Operation: "route_set", RouteID: "renewed-route", PeerNodeID: "node-b", TransportBindingID: newBinding.ID}); err != nil {
		t.Fatal(err)
	}
	probe.RouteID = "renewed-route"
	if _, err := communicationPeerProbe(a, "node-a", probe); err != nil {
		t.Fatal("renewed pin handshake failed", err)
	}
	if err := communicationAtomic(communicationPolicyPath(b), communicationPolicy{LegacyPaused: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := communicationAuthorize(b, CommunicationRequest{Operation: "route_identity_rotate"}); err == nil {
		t.Fatal("paused owner rotation authorized")
	}
}

func TestCommunicationPeerExpiredIdentityCanBeExplicitlyRenewed(t *testing.T) {
	root, _ := peerFixture(t, "node-a")
	var identity communicationPeerIdentity
	path := filepath.Join(root, "peer-identity.json")
	if err := communicationRead(path, &identity); err != nil {
		t.Fatal(err)
	}
	cert, err := peerCertificate(identity.CertificatePEM, "node-a")
	if err != nil {
		t.Fatal(err)
	}
	keyBlock, _ := pem.Decode([]byte(identity.PrivateKeyPEM))
	key, err := x509.ParsePKCS8PrivateKey(keyBlock.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	cert.NotBefore, cert.NotAfter = time.Now().Add(-2*time.Hour), time.Now().Add(-time.Hour)
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, cert.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	identity.CertificatePEM = string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
	if err := communicationAtomic(path, identity); err != nil {
		t.Fatal(err)
	}
	if _, _, err := peerIdentity(root, "node-a"); err == nil {
		t.Fatal("expired identity accepted for TLS")
	}
	expired, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := communicationRouteOperation(root, "node-a", CommunicationRequest{Operation: "route_identity_rotate", ExpectedIdentitySHA256: peerFingerprint(expired)}); err != nil {
		t.Fatal("expired identity renewal failed", err)
	}
	if _, _, err := peerIdentity(root, "node-a"); err != nil {
		t.Fatal("renewed identity unusable", err)
	}
}

func TestCommunicationPeerBoundedConnectionCloseReleasesOnce(t *testing.T) {
	a, b := net.Pipe()
	defer b.Close()
	slots := make(chan struct{}, 1)
	slots <- struct{}{}
	connection := &peerLimitedConn{Conn: a, release: func() { <-slots }}
	_ = connection.Close()
	_ = connection.Close()
	if len(slots) != 0 {
		t.Fatal("connection slot leaked")
	}
}
