package daemon

import (
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"golang.org/x/net/websocket"
)

func TestCodexProxyAuxiliaryAdmissionPreservesPrimary(t *testing.T) {
	p := &codexProxy{}
	peer := codexProxyPeer{uid: 2, pid: 10, start: 11}
	primary := &websocket.Conn{}
	if p.reserveFrontend(peer, primary) != codexFrontendPrimary {
		t.Fatal("primary refused")
	}
	p.selection.session = "primary-session"
	aux := &websocket.Conn{}
	if p.reserveFrontend(codexProxyPeer{uid: 2, pid: 10, start: 12}, aux) != codexFrontendDenied {
		t.Fatal("changed incarnation accepted")
	}
	if p.reserveFrontend(peer, aux) != codexFrontendAuxiliary {
		t.Fatal("same frontend auxiliary refused")
	}
	if p.reserveFrontend(peer, &websocket.Conn{}) != codexFrontendDenied {
		t.Fatal("extra auxiliary accepted")
	}
	p.releaseAuxiliary(aux)
	if !p.active || p.connection != 1 || p.selection.session != "primary-session" {
		t.Fatal("auxiliary changed primary")
	}
	if p.reserveFrontend(peer, aux) != codexFrontendAuxiliary {
		t.Fatal("second auxiliary refused after release")
	}
	if p.retirePrimary() != aux || p.active || p.auxiliary != nil || p.selection.session != "" {
		t.Fatal("primary retirement did not revoke auxiliary and selection")
	}
	p.releaseAuxiliary(aux)
}

func TestCodexProxyAuxiliaryRelaysWithoutChangingPrimary(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "relay-aux-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	path := filepath.Join(dir, "backend.sock")
	backend, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	dev, ino, err := codexProxySocketIdentity(path)
	if err != nil {
		t.Fatal(err)
	}
	start, err := processStartTime(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	go http.Serve(backend, websocket.Handler(func(c *websocket.Conn) {
		defer c.Close()
		var frame codexProxyFrame
		if codexProxyFrameCodec.Receive(c, &frame) == nil {
			_ = codexProxyFrameCodec.Send(c, frame)
		}
	}))
	p := &codexProxy{active: true, frontendDone: make(chan struct{}, 1), descriptor: codexProxyDescriptor{Backend: NativeCodexEndpoint{Socket: path, Device: dev, Inode: ino, DaemonPID: os.Getpid(), DaemonStart: start}}}
	p.selection.session = "primary-session"
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	finished := make(chan struct{})
	go http.Serve(listener, websocket.Handler(func(c *websocket.Conn) { p.serveAuxiliary(c); close(finished) }))
	client, err := websocket.Dial("ws://"+listener.Addr().String()+"/", "", "http://localhost/")
	if err != nil {
		t.Fatal(err)
	}
	message := codexProxyFrame{kind: websocket.TextFrame, data: []byte(`{"id":1,"method":"thread/list","params":{}}`)}
	if err := codexProxyFrameCodec.Send(client, message); err != nil {
		t.Fatal(err)
	}
	var response codexProxyFrame
	if err := codexProxyFrameCodec.Receive(client, &response); err != nil {
		t.Fatal(err)
	}
	if string(response.data) != string(message.data) {
		t.Fatal("frame changed")
	}
	client.Close()
	<-finished
	if !p.active || p.selection.session != "primary-session" {
		t.Fatal("primary changed")
	}
	select {
	case <-p.frontendDone:
		t.Fatal("auxiliary signalled primary exit")
	default:
	}
}

func TestCodexProxyAuxiliaryConcurrentAdmissionBounded(t *testing.T) {
	p := &codexProxy{}
	peer := codexProxyPeer{uid: 2, pid: 10, start: 11}
	p.reserveFrontend(peer, &websocket.Conn{})
	var wg sync.WaitGroup
	roles := make(chan codexFrontendRole, 32)
	for i := 0; i < cap(roles); i++ {
		wg.Add(1)
		go func() { defer wg.Done(); roles <- p.reserveFrontend(peer, &websocket.Conn{}) }()
	}
	wg.Wait()
	close(roles)
	accepted := 0
	for r := range roles {
		if r == codexFrontendAuxiliary {
			accepted++
		}
	}
	if accepted != 1 {
		t.Fatalf("accepted %d auxiliaries", accepted)
	}
}
