// Package desktoproute implements the explicitly selected desktop peer routes.
// Messages remain untrusted collaborator input; a socket write is not a read
// receipt, and an uncertain mutation is never retried.
package desktoproute

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

const messageLimit = 65536

var identifier = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]{0,109}$`)
var messageID = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,110}$`)
var numericStart = regexp.MustCompile(`^[0-9]{1,24}$`)
var clientID = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
var errReplay = errors.New("message ID already used; do not retry")
var errIdentity = errors.New("recipient changed; explicit rebinding required")

// decodeJSON rejects ambiguous duplicate keys at every depth before typed
// decoding. Input size and nesting are bounded independently of the decoder.
func decodeJSON(data []byte, limit int, result any) error {
	if len(data) > limit || !utf8.Valid(data) {
		return errors.New("invalid or oversized JSON")
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	var value func(int) error
	value = func(depth int) error {
		if depth > 32 {
			return errors.New("JSON nesting exceeds 32")
		}
		t, e := d.Token()
		if e != nil {
			return e
		}
		switch t {
		case json.Delim('{'):
			seen := map[string]bool{}
			for d.More() {
				k, e := d.Token()
				if e != nil {
					return e
				}
				key, ok := k.(string)
				if !ok || seen[key] {
					return errors.New("duplicate or invalid JSON key")
				}
				seen[key] = true
				if e = value(depth + 1); e != nil {
					return e
				}
			}
			end, e := d.Token()
			if e != nil || end != json.Delim('}') {
				return errors.New("truncated JSON object")
			}
		case json.Delim('['):
			for d.More() {
				if e := value(depth + 1); e != nil {
					return e
				}
			}
			end, e := d.Token()
			if e != nil || end != json.Delim(']') {
				return errors.New("truncated JSON array")
			}
		case json.Delim('}'), json.Delim(']'):
			return errors.New("unexpected JSON delimiter")
		}
		return nil
	}
	if e := value(0); e != nil {
		return e
	}
	if _, e := d.Token(); e != io.EOF {
		return errors.New("trailing JSON")
	}
	d = json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	return d.Decode(result)
}

func readBounded(in io.Reader, limit int) ([]byte, error) {
	b, e := io.ReadAll(io.LimitReader(in, int64(limit)+1))
	if e != nil {
		return nil, e
	}
	if len(b) > limit {
		return nil, errors.New("input exceeds limit")
	}
	return b, nil
}
func validStart(host, s string) bool {
	if len(s) == 0 || len(s) > 128 || strings.IndexFunc(s, func(r rune) bool { return r < 32 || r == 127 }) >= 0 {
		return false
	}
	return host == "laptop" || numericStart.MatchString(s)
}
func uuid() string {
	var b [16]byte
	if _, e := rand.Read(b[:]); e != nil {
		panic(e)
	}
	b[6] = (b[6] & 15) | 64
	b[8] = (b[8] & 63) | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}
func hash(data []byte) string { h := sha256.Sum256(data); return hex.EncodeToString(h[:]) }

type Config struct {
	Host          string `json:"host"`
	LocalName     string `json:"localName"`
	Thread        string `json:"thread"`
	RemoteName    string `json:"remoteName"`
	RemoteSession string `json:"remoteSession"`
	RemotePID     int    `json:"remotePID"`
	RemoteStart   string `json:"remoteStart"`
	// RemoteAccount is the owner process's own Claude account directory, recorded
	// so a replacement after the owner exits is searched only there. Empty for
	// routes not yet verified; it is then backfilled from the live owner.
	RemoteAccount string `json:"remoteAccount,omitempty"`
	Socket        string `json:"socket"`
}

func (c Config) Validate() error {
	for _, s := range []string{c.Host, c.LocalName, c.Thread, c.RemoteName, c.RemoteSession} {
		if !identifier.MatchString(s) {
			return errors.New("invalid route identifier")
		}
	}
	if c.RemotePID <= 0 || c.RemotePID > math.MaxInt32 || !validStart(c.Host, c.RemoteStart) {
		return errors.New("invalid remote incarnation")
	}
	if !filepath.IsAbs(c.Socket) || strings.ContainsRune(c.Socket, 0) {
		return errors.New("desktop socket must be absolute")
	}
	if c.RemoteAccount != "" && (!filepath.IsAbs(c.RemoteAccount) || filepath.Clean(c.RemoteAccount) != c.RemoteAccount || len(c.RemoteAccount) > 4096 || strings.ContainsRune(c.RemoteAccount, 0)) {
		return errors.New("recorded owner account must be absolute and clean")
	}
	return nil
}
func ParseConfig(data []byte) (Config, error) {
	var c Config
	if e := decodeJSON(data, 16384, &c); e != nil {
		return c, e
	}
	return c, c.Validate()
}
func routeKey(c Config) string {
	// Identifiers are ASCII, so this is byte-identical to the original compact
	// JSON [task,host,session] key. Names/PIDs never become task identity.
	b, _ := json.Marshal([]string{c.Thread, c.Host, c.RemoteSession})
	return hash(b)[:32]
}

type Mailbox struct {
	Type  string `json:"type,omitempty"`
	PID   int    `json:"pid"`
	Start string `json:"start"`
	Name  string `json:"name,omitempty"`
	Peer  string `json:"peer,omitempty"`
	Drain int    `json:"drain,omitempty"`
}
type RouteState struct {
	Schema            int      `json:"schema"`
	PID               int      `json:"pid"`
	Host              string   `json:"host"`
	LocalName         string   `json:"localName"`
	LocalSession      string   `json:"localSession"`
	RemoteName        string   `json:"remoteName"`
	RemoteSession     string   `json:"remoteSession"`
	RemotePID         int      `json:"remotePID"`
	RemoteStart       string   `json:"remoteStart"`
	State             string   `json:"state"`
	UpdatedAt         string   `json:"updatedAt"`
	Heartbeat         float64  `json:"heartbeatEpoch,omitempty"`
	Mailbox           *Mailbox `json:"mailbox,omitempty"`
	RTT               int      `json:"rttMillis"`
	Attempt           int      `json:"attempt"`
	Error             string   `json:"error,omitempty"`
	RebindRequired    bool     `json:"rebindRequired,omitempty"`
	LastMessageID     string   `json:"lastMessageId,omitempty"`
	LastReceipt       string   `json:"lastReceipt,omitempty"`
	LastReadMessageID string   `json:"lastReadMessageId,omitempty"`
	LastReadReceipt   string   `json:"lastReadReceipt,omitempty"`
}

func (s RouteState) live(c Config, now time.Time) (Mailbox, error) {
	if s.Host != c.Host || s.LocalName != c.LocalName || s.LocalSession != c.Thread || s.RemoteSession != c.RemoteSession || s.RemotePID != c.RemotePID || s.RemoteStart != c.RemoteStart {
		return Mailbox{}, errors.New("route identity changed; message not sent")
	}
	age := float64(now.UnixNano())/1e9 - s.Heartbeat
	if s.State != "online" || math.IsNaN(age) || math.IsInf(age, 0) || age < 0 || age > 25 {
		return Mailbox{}, errors.New("route offline or stale; message not sent")
	}
	if s.Mailbox == nil || s.Mailbox.PID <= 0 || len(s.Mailbox.Start) > 64 || !validStart(c.Host, s.Mailbox.Start) {
		return Mailbox{}, errors.New("invalid reply mailbox")
	}
	return *s.Mailbox, nil
}

type Envelope struct {
	ID              string `json:"id"`
	Sender          string `json:"sender,omitempty"`
	Content         string `json:"content"`
	PermissionClass string `json:"permissionClass,omitempty"`
	ReadReceipt     *bool  `json:"readReceipt,omitempty"`
}

func parseEnvelope(data []byte, requireSender bool) (Envelope, error) {
	var m Envelope
	if e := decodeJSON(data, messageLimit, &m); e != nil {
		return m, e
	}
	if !messageID.MatchString(m.ID) || strings.TrimSpace(m.Content) == "" || (requireSender && strings.TrimSpace(m.Sender) == "") {
		return m, errors.New("message ID, authenticated sender and content required")
	}
	encoded, e := json.Marshal(m)
	if e != nil || len(encoded) > messageLimit {
		return m, errors.New("canonical envelope exceeds limit")
	}
	return m, nil
}

type Delivery struct {
	MessageID string `json:"messageId,omitempty"`
	Receipt   string `json:"receipt"`
	TurnID    string `json:"turnId,omitempty"`
	Transport string `json:"transport,omitempty"`
	Error     string `json:"error,omitempty"`
	RetrySafe bool   `json:"retrySafe"`
}

func readAcknowledgment(content string) string {
	body := strings.TrimSpace(content)
	if strings.HasPrefix(body, "<cross-session-message ") {
		start := strings.IndexByte(body, '>')
		end := strings.LastIndex(body, "</cross-session-message>")
		if start < 0 || end < start || end+len("</cross-session-message>") != len(body) {
			return ""
		}
		body = strings.TrimSpace(body[start+1 : end])
	}
	const prefix = "Relay-Read-Receipt: "
	if strings.HasPrefix(body, prefix) && messageID.MatchString(body[len(prefix):]) {
		return body[len(prefix):]
	}
	return ""
}
