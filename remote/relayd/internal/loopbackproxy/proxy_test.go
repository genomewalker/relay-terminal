package loopbackproxy

import (
	"bytes"
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"golang.org/x/net/websocket"
)

func serverPort(t *testing.T, server *httptest.Server) int {
	t.Helper()
	_, port, err := net.SplitHostPort(server.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	value, err := strconv.Atoi(port)
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func TestHTTPHalfCloseKeepsCompleteResponse(t *testing.T) {
	payload := bytes.Repeat([]byte("render-bytes"), 128<<10)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-HTTPGD-TOKEN") != "fixture-token" {
			t.Error("header changed")
		}
		w.Header().Set("Content-Type", "image/png")
		w.Header().Set("Content-Length", strconv.Itoa(len(payload)))
		w.Write(payload)
	}))
	defer server.Close()
	request := "GET /plot HTTP/1.1\r\nHost: 127.0.0.1\r\nX-HTTPGD-TOKEN: fixture-token\r\nConnection: close\r\n\r\n"
	var output bytes.Buffer
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := Serve(ctx, serverPort(t, server), strings.NewReader(request), &output); err != nil {
		t.Fatal(err)
	}
	if !bytes.HasSuffix(output.Bytes(), payload) {
		t.Fatal("truncated response after request EOF")
	}
	if bytes.Contains(output.Bytes(), []byte("fixture-token")) {
		t.Fatal("request credential leaked to output")
	}
}

func TestWebSocketUpgradeAndBidirectionalBytes(t *testing.T) {
	server := httptest.NewServer(websocket.Handler(func(ws *websocket.Conn) {
		defer ws.Close()
		var incoming []byte
		if err := websocket.Message.Receive(ws, &incoming); err != nil {
			return
		}
		websocket.Message.Send(ws, incoming)
	}))
	defer server.Close()
	client, proxy := net.Pipe()
	defer client.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- Serve(ctx, serverPort(t, server), proxy, proxy) }()
	config, err := websocket.NewConfig(server.URL+"/", "http://127.0.0.1/")
	if err != nil {
		t.Fatal(err)
	}
	config.Location.Scheme = "ws"
	ws, err := websocket.NewClient(config, client)
	if err != nil {
		t.Fatal(err)
	}
	data := bytes.Repeat([]byte{0, 1, 255, 127}, 16<<10)
	if err := websocket.Message.Send(ws, data); err != nil {
		t.Fatal(err)
	}
	var echoed []byte
	if err := websocket.Message.Receive(ws, &echoed); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(echoed, data) {
		t.Fatal("WebSocket bytes changed")
	}
	ws.Close()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("proxy did not retire after peer close")
	}
}

func TestCancellationClosesOwnedConnection(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	port := listener.Addr().(*net.TCPAddr).Port
	accepted := make(chan net.Conn, 1)
	go func() {
		conn, err := listener.Accept()
		if err == nil {
			accepted <- conn
		}
	}()
	reader, writer := io.Pipe()
	defer writer.Close()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- Serve(ctx, port, reader, io.Discard) }()
	peer := <-accepted
	defer peer.Close()
	cancel()
	select {
	case err := <-done:
		if err != context.Canceled {
			t.Fatalf("cancellation: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("proxy did not cancel")
	}
}

func TestInvalidPortsDoNotOpenConnections(t *testing.T) {
	for _, port := range []int{-1, 0, 65536} {
		if err := Serve(context.Background(), port, strings.NewReader(""), io.Discard); err == nil {
			t.Fatal("invalid port accepted")
		}
	}
}
