package daemon

// A minimal D-Bus client for the host vault unlock: one private connection to
// the user's session bus over a Unix socket, SASL EXTERNAL authentication and
// synchronous method calls. It marshals only the argument types the Secret
// Service calls use and decodes any reply, bounded in size and depth.

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	dbusMethodCall   = 1
	dbusMethodReturn = 2
	dbusError        = 3

	dbusFieldPath        = 1
	dbusFieldInterface   = 2
	dbusFieldMember      = 3
	dbusFieldErrorName   = 4
	dbusFieldReplySerial = 5
	dbusFieldDestination = 6
	dbusFieldSignature   = 8

	dbusMessageLimit = 64 << 10
	dbusDepthLimit   = 32
	dbusArrayLimit   = 4096
	dbusCallTimeout  = 25 * time.Second // libdbus's default reply timeout
)

// dbusSessionAddress is the session bus address the former Python helper's
// environment carried: an explicit address, else an owned private user bus.
func dbusSessionAddress() string {
	for _, pair := range hostSecretServiceEnvironment() {
		if value, ok := strings.CutPrefix(pair, "DBUS_SESSION_BUS_ADDRESS="); ok {
			return value
		}
	}
	return ""
}

// dbusDial connects to the first usable unix:path= or unix:abstract= entry
// of a D-Bus server address list.
func dbusDial(ctx context.Context, address string) (net.Conn, error) {
	var dialer net.Dialer
	for _, entry := range strings.Split(address, ";") {
		transport, parameters, ok := strings.Cut(entry, ":")
		if !ok || transport != "unix" {
			continue
		}
		for _, parameter := range strings.Split(parameters, ",") {
			key, value, _ := strings.Cut(parameter, "=")
			value, err := url.PathUnescape(value)
			if err != nil || value == "" {
				continue
			}
			switch key {
			case "path":
			case "abstract":
				value = "@" + value
			default:
				continue
			}
			if conn, err := dialer.DialContext(ctx, "unix", value); err == nil {
				return conn, nil
			}
		}
	}
	return nil, errors.New("no reachable session bus")
}

type dbusConn struct {
	conn   net.Conn
	reader *bufio.Reader
	serial uint32
}

// dbusConnect authenticates as this process's uid and registers with Hello.
func dbusConnect(ctx context.Context, conn net.Conn) (*dbusConn, error) {
	c := &dbusConn{conn: conn, reader: bufio.NewReaderSize(conn, 4096)}
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	}
	uid := hex.EncodeToString([]byte(strconv.Itoa(os.Getuid())))
	if _, err := conn.Write([]byte("\x00AUTH EXTERNAL " + uid + "\r\n")); err != nil {
		return nil, err
	}
	line, err := c.reader.ReadSlice('\n')
	if err != nil || !bytes.HasPrefix(line, []byte("OK ")) {
		return nil, errors.New("session bus refused authentication")
	}
	if _, err := conn.Write([]byte("BEGIN\r\n")); err != nil {
		return nil, err
	}
	if _, err := c.call(ctx, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello", "", nil, dbusCallTimeout); err != nil {
		return nil, err
	}
	return c, nil
}

func (c *dbusConn) Close() error { return c.conn.Close() }

// call sends one method call and returns the reply body, skipping signals and
// unrelated messages. An error reply is returned as its error name only.
func (c *dbusConn) call(ctx context.Context, destination, path, iface, member, signature string, body []byte, timeout time.Duration) ([]any, error) {
	deadline := time.Now().Add(timeout)
	if limit, ok := ctx.Deadline(); ok && limit.Before(deadline) {
		deadline = limit
	}
	if err := c.conn.SetDeadline(deadline); err != nil {
		return nil, err
	}
	c.serial++
	message := dbusMarshalCall(c.serial, destination, path, iface, member, signature, body)
	_, err := c.conn.Write(message)
	clear(message)
	if err != nil {
		return nil, err
	}
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		reply, err := dbusReadMessage(c.reader)
		if err != nil {
			return nil, err
		}
		if reply.kind != dbusMethodReturn && reply.kind != dbusError || reply.replySerial != c.serial {
			continue
		}
		if reply.kind == dbusError {
			return nil, fmt.Errorf("%s.%s failed: %s", iface, member, reply.errorName)
		}
		return reply.decodeBody()
	}
}

// ---- Marshalling (little-endian).

type dbusEncoder struct{ buf []byte }

func (e *dbusEncoder) align(n int) {
	for len(e.buf)%n != 0 {
		e.buf = append(e.buf, 0)
	}
}

func (e *dbusEncoder) byte(b byte) { e.buf = append(e.buf, b) }

func (e *dbusEncoder) uint32(v uint32) {
	e.align(4)
	e.buf = binary.LittleEndian.AppendUint32(e.buf, v)
}

// string encodes s or o.
func (e *dbusEncoder) string(s string) {
	e.uint32(uint32(len(s)))
	e.buf = append(append(e.buf, s...), 0)
}

func (e *dbusEncoder) signature(s string) {
	e.buf = append(append(append(e.buf, byte(len(s))), s...), 0)
}

func (e *dbusEncoder) bytes(b []byte) {
	e.uint32(uint32(len(b)))
	e.buf = append(e.buf, b...)
}

func dbusMarshalCall(serial uint32, destination, path, iface, member, signature string, body []byte) []byte {
	e := &dbusEncoder{buf: make([]byte, 0, 256+len(body))}
	e.buf = append(e.buf, 'l', dbusMethodCall, 0, 1)
	e.uint32(uint32(len(body)))
	e.uint32(serial)
	e.uint32(0) // header field array length, patched below
	e.align(8)
	start := len(e.buf)
	field := func(code byte, kind, value string) {
		e.align(8)
		e.byte(code)
		e.signature(kind)
		if kind == "g" {
			e.signature(value)
		} else {
			e.string(value)
		}
	}
	field(dbusFieldPath, "o", path)
	if iface != "" {
		field(dbusFieldInterface, "s", iface)
	}
	field(dbusFieldMember, "s", member)
	field(dbusFieldDestination, "s", destination)
	if signature != "" {
		field(dbusFieldSignature, "g", signature)
	}
	binary.LittleEndian.PutUint32(e.buf[12:16], uint32(len(e.buf)-start))
	e.align(8)
	return append(e.buf, body...)
}

// ---- Unmarshalling.

type dbusMessage struct {
	kind        byte
	replySerial uint32
	errorName   string
	signature   string
	body        []byte
	order       binary.ByteOrder
}

// dbusVariant is a decoded variant: its signature and value.
type dbusVariant struct {
	signature string
	value     any
}

func dbusReadMessage(reader io.Reader) (*dbusMessage, error) {
	fixed := make([]byte, 16)
	if _, err := io.ReadFull(reader, fixed); err != nil {
		return nil, err
	}
	var order binary.ByteOrder
	switch fixed[0] {
	case 'l':
		order = binary.LittleEndian
	case 'B':
		order = binary.BigEndian
	default:
		return nil, errors.New("invalid D-Bus byte order")
	}
	if fixed[3] != 1 {
		return nil, errors.New("unsupported D-Bus protocol version")
	}
	bodyLength, fieldsLength := uint64(order.Uint32(fixed[4:8])), uint64(order.Uint32(fixed[12:16]))
	headerLength := (16 + fieldsLength + 7) &^ 7
	if headerLength+bodyLength > dbusMessageLimit {
		return nil, errors.New("D-Bus message exceeds limit")
	}
	data := make([]byte, headerLength+bodyLength)
	copy(data, fixed)
	if _, err := io.ReadFull(reader, data[16:]); err != nil {
		return nil, err
	}
	d := &dbusDecoder{data: data[:16+fieldsLength], pos: 12, order: order}
	fields, err := d.value("a(yv)")
	if err != nil {
		return nil, err
	}
	message := &dbusMessage{kind: fixed[1]}
	for _, item := range fields.([]any) {
		pair := item.([]any)
		variant := pair[1].(dbusVariant)
		switch pair[0].(byte) {
		case dbusFieldReplySerial:
			if serial, ok := variant.value.(uint32); ok {
				message.replySerial = serial
			}
		case dbusFieldErrorName:
			message.errorName, _ = variant.value.(string)
		case dbusFieldSignature:
			message.signature, _ = variant.value.(string)
		}
	}
	message.body, message.order = data[headerLength:], order
	return message, nil
}

// decodeBody decodes the body by its signature. Only the awaited reply is
// decoded, so an unrelated signal of any type is skipped unread.
func (m *dbusMessage) decodeBody() ([]any, error) {
	d := &dbusDecoder{data: m.body, order: m.order}
	var values []any
	for signature := m.signature; signature != ""; {
		value, rest, err := d.next(signature, 0)
		if err != nil {
			return nil, err
		}
		values = append(values, value)
		signature = rest
	}
	if d.pos != len(d.data) {
		return nil, errors.New("D-Bus body has trailing bytes")
	}
	return values, nil
}

type dbusDecoder struct {
	data  []byte
	pos   int
	order binary.ByteOrder
}

var errDBusTruncated = errors.New("truncated D-Bus message")

func (d *dbusDecoder) align(n int) error {
	next := (d.pos + n - 1) / n * n
	if next > len(d.data) {
		return errDBusTruncated
	}
	d.pos = next
	return nil
}

func (d *dbusDecoder) take(n int) ([]byte, error) {
	if n < 0 || n > len(d.data)-d.pos {
		return nil, errDBusTruncated
	}
	d.pos += n
	return d.data[d.pos-n : d.pos], nil
}

// value decodes exactly one complete type.
func (d *dbusDecoder) value(signature string) (any, error) {
	value, rest, err := d.next(signature, 0)
	if err == nil && rest != "" {
		err = errors.New("signature is not a single complete type")
	}
	return value, err
}

// next decodes the first complete type of signature and returns the rest.
func (d *dbusDecoder) next(signature string, depth int) (any, string, error) {
	if signature == "" || depth > dbusDepthLimit {
		return nil, "", errors.New("invalid D-Bus signature")
	}
	fixed := func(size int) ([]byte, error) {
		if err := d.align(size); err != nil {
			return nil, err
		}
		return d.take(size)
	}
	code, rest := signature[0], signature[1:]
	switch code {
	case 'y':
		b, err := d.take(1)
		if err != nil {
			return nil, "", err
		}
		return b[0], rest, nil
	case 'b', 'u', 'i', 'h':
		b, err := fixed(4)
		if err != nil {
			return nil, "", err
		}
		v := d.order.Uint32(b)
		switch code {
		case 'b':
			if v > 1 {
				return nil, "", errors.New("invalid D-Bus boolean")
			}
			return v == 1, rest, nil
		case 'i':
			return int32(v), rest, nil
		}
		return v, rest, nil
	case 'n', 'q':
		b, err := fixed(2)
		if err != nil {
			return nil, "", err
		}
		return d.order.Uint16(b), rest, nil
	case 'x', 't', 'd':
		b, err := fixed(8)
		if err != nil {
			return nil, "", err
		}
		return d.order.Uint64(b), rest, nil
	case 's', 'o':
		b, err := fixed(4)
		if err != nil {
			return nil, "", err
		}
		text, err := d.take(int(d.order.Uint32(b)) + 1)
		if err != nil || text[len(text)-1] != 0 {
			return nil, "", errDBusTruncated
		}
		return string(text[:len(text)-1]), rest, nil
	case 'g':
		length, err := d.take(1)
		if err != nil {
			return nil, "", err
		}
		text, err := d.take(int(length[0]) + 1)
		if err != nil || text[len(text)-1] != 0 {
			return nil, "", errDBusTruncated
		}
		return string(text[:len(text)-1]), rest, nil
	case 'v':
		inner, _, err := d.next("g", depth+1)
		if err != nil {
			return nil, "", err
		}
		value, err := d.valueAt(inner.(string), depth+1)
		if err != nil {
			return nil, "", err
		}
		return dbusVariant{signature: inner.(string), value: value}, rest, nil
	case 'a':
		element, after, err := dbusSplitType(rest)
		if err != nil {
			return nil, "", err
		}
		b, err := fixed(4)
		if err != nil {
			return nil, "", err
		}
		length := int(d.order.Uint32(b))
		if err := d.align(dbusAlignment(element[0])); err != nil {
			return nil, "", err
		}
		if length > len(d.data)-d.pos {
			return nil, "", errDBusTruncated
		}
		end := d.pos + length
		if element == "y" {
			raw, _ := d.take(length)
			return append([]byte(nil), raw...), after, nil
		}
		// The array's byte length is a hard end: elements decode within it,
		// each must consume bytes, and their number is capped.
		bounded := &dbusDecoder{data: d.data[:end], pos: d.pos, order: d.order}
		items := []any{}
		for bounded.pos < end {
			if len(items) == dbusArrayLimit {
				return nil, "", errors.New("D-Bus array has too many elements")
			}
			start := bounded.pos
			var item any
			var err error
			if element[0] == '{' {
				item, _, err = bounded.structure(element[1:], '}', depth+1)
			} else {
				item, _, err = bounded.next(element, depth+1)
			}
			if err != nil {
				return nil, "", err
			}
			if bounded.pos == start {
				return nil, "", errors.New("D-Bus array element consumed no bytes")
			}
			items = append(items, item)
		}
		d.pos = bounded.pos
		return items, after, nil
	case '(':
		return d.structure(rest, ')', depth)
	}
	return nil, "", errors.New("unsupported D-Bus type")
}

// structure decodes struct members up to closing. A struct has at least one
// member; a dict entry, valid only as an array element, has exactly two.
func (d *dbusDecoder) structure(rest string, closing byte, depth int) ([]any, string, error) {
	if err := d.align(8); err != nil {
		return nil, "", err
	}
	var items []any
	for {
		if rest == "" {
			return nil, "", errors.New("unterminated D-Bus struct")
		}
		if rest[0] == closing {
			if len(items) == 0 || closing == '}' && len(items) != 2 {
				return nil, "", errors.New("invalid D-Bus struct")
			}
			return items, rest[1:], nil
		}
		item, after, err := d.next(rest, depth+1)
		if err != nil {
			return nil, "", err
		}
		items = append(items, item)
		rest = after
	}
}

func (d *dbusDecoder) valueAt(signature string, depth int) (any, error) {
	value, rest, err := d.next(signature, depth)
	if err == nil && rest != "" {
		err = errors.New("variant is not a single complete type")
	}
	return value, err
}

// dbusSplitType splits the first complete type from a signature.
func dbusSplitType(signature string) (string, string, error) {
	if signature == "" {
		return "", "", errors.New("invalid D-Bus signature")
	}
	switch signature[0] {
	case 'a':
		element, rest, err := dbusSplitType(signature[1:])
		return "a" + element, rest, err
	case '(', '{':
		depth := 0
		for i := 0; i < len(signature); i++ {
			switch signature[i] {
			case '(', '{':
				depth++
			case ')', '}':
				depth--
				if depth == 0 {
					return signature[:i+1], signature[i+1:], nil
				}
			}
		}
		return "", "", errors.New("unterminated D-Bus struct")
	}
	return signature[:1], signature[1:], nil
}

func dbusAlignment(code byte) int {
	switch code {
	case 'y', 'g', 'v':
		return 1
	case 'n', 'q':
		return 2
	case 'x', 't', 'd', '(', '{':
		return 8
	}
	return 4
}
