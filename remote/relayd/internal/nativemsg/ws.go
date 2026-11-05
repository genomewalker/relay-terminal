package nativemsg

import (
	"bytes"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"strings"
	"time"
)

const (
	frameLimit    = 65536
	responseLimit = 2 << 20
	websocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
)

// webSocket is a bounded RFC 6455 client over an already-existing private
// Unix socket (the adapter's UnixWebSocket). It never creates the socket.
type webSocket struct {
	r       *runner
	socket  *pySocket
	pending []byte
	nextID  int64
	// randomBytes is os.urandom; tests replace it.
	randomBytes func(int) []byte
}

func urandom(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}

// openWebSocket connects to path whose socket identity must still be
// incarnation, checks the kernel peer when peerPID is truthy, performs the
// opening handshake and the initialize exchange.
func (r *runner) openWebSocket(path string, incarnation any, peerPID any) (*webSocket, error) {
	identity, err := r.socketIdentity(path)
	if err != nil {
		return nil, err
	}
	if !pyEqual(identity, incarnation) {
		return nil, valueError("Native socket changed")
	}
	socket, err := dialUnix(r.ctx, path, 8*time.Second)
	if err != nil {
		return nil, err
	}
	ws := &webSocket{r: r, socket: socket, randomBytes: r.random}
	if err := ws.handshake(path, incarnation, peerPID); err != nil {
		socket.close()
		return nil, err
	}
	return ws, nil
}

func (ws *webSocket) handshake(path string, incarnation, peerPID any) error {
	if pyTruthy(peerPID) {
		if err := checkDaemonPeer(ws.socket, peerPID, ws.r.uid); err != nil {
			return err
		}
	}
	identity, err := ws.r.socketIdentity(path)
	if err != nil {
		return err
	}
	if !pyEqual(identity, incarnation) {
		return valueError("Native socket changed while connecting")
	}
	key := base64.StdEncoding.EncodeToString(ws.randomBytes(16))
	request := "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n" +
		"Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n" +
		"Sec-WebSocket-Key: " + key + "\r\n\r\n"
	if err := ws.socket.sendall([]byte(request)); err != nil {
		return err
	}
	for !bytes.Contains(ws.pending, []byte("\r\n\r\n")) {
		chunk, err := ws.socket.recv(4096)
		if err != nil {
			return err
		}
		if len(chunk) == 0 {
			return connectionError("Native websocket closed")
		}
		ws.pending = append(ws.pending, chunk...)
		if len(ws.pending) > 16384 {
			return valueError("Invalid native websocket handshake")
		}
	}
	header, rest, _ := bytes.Cut(ws.pending, []byte("\r\n\r\n"))
	ws.pending = append([]byte(nil), rest...)
	for i, c := range header {
		if c >= 0x80 {
			return &pyErr{class: classUnicode, msg: fmt.Sprintf(
				"'ascii' codec can't decode byte 0x%02x in position %d: ordinal not in range(128)", c, i)}
		}
	}
	lines := strings.Split(string(header), "\r\n")
	headers := map[string]string{}
	for _, line := range lines[1:] {
		if name, value, ok := strings.Cut(line, ":"); ok {
			headers[strings.ToLower(name)] = pyStrip(value)
		}
	}
	digest := sha1.Sum([]byte(key + websocketGUID))
	expected := base64.StdEncoding.EncodeToString(digest[:])
	status := pySplit(lines[0])
	if len(status) < 2 {
		return &pyErr{class: classIndex, msg: "list index out of range"}
	}
	if status[1] != "101" || headers["sec-websocket-accept"] != expected ||
		strings.ToLower(headers["upgrade"]) != "websocket" {
		return valueError("Native websocket rejected connection")
	}
	if _, err := ws.rpc("initialize", obj{
		{"clientInfo", obj{{"name", "relay_pane_messaging"}, {"version", "1"}}},
		{"capabilities", obj{{"experimentalApi", true}}},
	}); err != nil {
		return err
	}
	return ws.send(1, []byte(dumps(obj{{"method", "initialized"}}, false)))
}

func (ws *webSocket) close() { ws.socket.close() }

func (ws *webSocket) read(length uint64) ([]byte, error) {
	for uint64(len(ws.pending)) < length {
		want := length - uint64(len(ws.pending))
		if want > 65536 {
			want = 65536
		}
		chunk, err := ws.socket.recv(int(want))
		if err != nil {
			return nil, err
		}
		if len(chunk) == 0 {
			return nil, connectionError("Native websocket closed")
		}
		ws.pending = append(ws.pending, chunk...)
	}
	result := append([]byte(nil), ws.pending[:length]...)
	ws.pending = ws.pending[length:]
	return result, nil
}

// send writes one masked, final frame.
func (ws *webSocket) send(opcode byte, payload []byte) error {
	if len(payload) > frameLimit {
		return valueError("Native message exceeds frame limit")
	}
	mask := ws.randomBytes(4)
	header := []byte{0x80 | opcode}
	length := len(payload)
	switch {
	case length < 126:
		header = append(header, 0x80|byte(length))
	case length < 65536:
		header = append(header, 0x80|126)
		header = binary.BigEndian.AppendUint16(header, uint16(length))
	default:
		header = append(header, 0x80|127)
		header = binary.BigEndian.AppendUint64(header, uint64(length))
	}
	frame := append(header, mask...)
	for i, v := range payload {
		frame = append(frame, v^mask[i%4])
	}
	return ws.socket.sendall(frame)
}

// receive assembles one text message: pings are answered, pongs skipped,
// a close frame ends the connection.
func (ws *webSocket) receive() (any, error) {
	var assembled []byte
	started := false
	for {
		head, err := ws.read(2)
		if err != nil {
			return nil, err
		}
		first, second := head[0], head[1]
		opcode := first & 15
		if first&0x70 != 0 || second&0x80 != 0 {
			return nil, valueError("Invalid native websocket frame")
		}
		length := uint64(second & 127)
		switch length {
		case 126:
			extended, err := ws.read(2)
			if err != nil {
				return nil, err
			}
			length = uint64(binary.BigEndian.Uint16(extended))
		case 127:
			extended, err := ws.read(8)
			if err != nil {
				return nil, err
			}
			length = binary.BigEndian.Uint64(extended)
		}
		if length > responseLimit || uint64(len(assembled))+length > responseLimit {
			return nil, valueError("Native response exceeds limit")
		}
		data, err := ws.read(length)
		if err != nil {
			return nil, err
		}
		switch {
		case opcode == 8:
			return nil, connectionError("Native websocket closed")
		case opcode == 9:
			if err := ws.send(10, data); err != nil {
				return nil, err
			}
			continue
		case opcode == 10:
			continue
		case opcode == 1 && !started:
			started = true
		case opcode != 0 || !started:
			return nil, valueError("Invalid native websocket continuation")
		}
		assembled = append(assembled, data...)
		if first&0x80 != 0 {
			return loadsText(assembled)
		}
	}
}

// rpc sends one JSON-RPC request and returns its result. Requests the
// server makes of this connection are refused; it never owns approvals.
func (ws *webSocket) rpc(method string, params any) (any, error) {
	ws.nextID++
	requestID := ws.nextID
	request := obj{{"id", requestID}, {"method", method}, {"params", params}}
	if err := ws.send(1, []byte(dumps(request, false))); err != nil {
		return nil, err
	}
	deadline := time.Now().Add(8 * time.Second)
	for i := 0; i < 1024; i++ {
		remaining := time.Until(deadline)
		if remaining < 10*time.Millisecond {
			remaining = 10 * time.Millisecond
		}
		ws.socket.timeout = remaining
		reply, err := ws.receive()
		if err != nil {
			return nil, err
		}
		id, err := pyGet(reply, "id", nil)
		if err != nil {
			return nil, err
		}
		if !pyEqual(id, requestID) {
			hasID, _ := pyHas(reply, "id")
			hasMethod, _ := pyHas(reply, "method")
			if hasID && hasMethod {
				refusal := obj{{"id", id}, {"error", obj{{"code", int64(-32601)},
					{"message", "Relay messaging does not own this request"}}}}
				if err := ws.send(1, []byte(dumps(refusal, false))); err != nil {
					return nil, err
				}
			}
			continue
		}
		if failed, _ := pyHas(reply, "error"); failed {
			return nil, valueError("Native provider rejected " + method)
		}
		return pyIndex(reply, "result")
	}
	return nil, valueError("Native response limit reached")
}
