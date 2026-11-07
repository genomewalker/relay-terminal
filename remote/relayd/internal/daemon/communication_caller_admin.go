package daemon

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Caller-policy mutations (caller_register, caller_set_paused,
// caller_policy_import) are administration of who may message through this
// host. The host transport and `relayd communication` accept any request from
// the same Unix user, so the transport alone cannot tell the Relay app from
// another process. Each mutation therefore carries an Ed25519 proof from an
// app-held key whose private half never leaves the Mac.
//
// The public key is pinned on this host by the first valid proof (trust on
// first use). After that only that key is accepted. A proof binds this node,
// the operation, the exact arguments, a fresh nonce and a short expiry; nonces
// are recorded until expiry so a captured request cannot be replayed.
// caller_list stays readable; caller_admin_info reports the node ID and the
// pinned key's fingerprint so the app can sign and detect a swapped pin.
const (
	communicationCallerAdminDomain  = "relay-caller-admin-v1\x00"
	communicationCallerAdminMaxLife = 10 * time.Minute
	communicationCallerAdminNonces  = 1024
)

type communicationAdminProof struct {
	PublicKey string `json:"public_key"` // base64 Ed25519 public key
	Nonce     string `json:"nonce"`      // base64, 16 random bytes
	Expires   int64  `json:"expires"`    // unix seconds
	Signature string `json:"signature"`  // base64 over domain+message
}

type communicationAdminNonce struct {
	Nonce   string `json:"n"`
	Expires int64  `json:"e"`
}

type communicationAdminState struct {
	Version   int                       `json:"version"`
	PublicKey string                    `json:"public_key"`
	Nonces    []communicationAdminNonce `json:"nonces"`
}

func communicationCallerAdminPath(root string) string {
	return filepath.Join(root, "caller-admin.json")
}

func communicationAdminLP(b *strings.Builder, s string) { fmt.Fprintf(b, "%d:%s", len(s), s) }

// communicationCallerAdminArguments is the canonical, length-prefixed form of
// the arguments a proof covers. The Swift app builds the same bytes.
func communicationCallerAdminArguments(r CommunicationRequest) string {
	var b strings.Builder
	flag := func(v bool) string {
		if v {
			return "1"
		}
		return "0"
	}
	communicationAdminLP(&b, strings.ToLower(r.CallerID))
	if r.Paused == nil {
		communicationAdminLP(&b, "-")
	} else {
		communicationAdminLP(&b, flag(*r.Paused))
	}
	if r.Policy == nil {
		communicationAdminLP(&b, "-")
		return b.String()
	}
	communicationAdminLP(&b, flag(r.Policy.LegacyPaused))
	communicationAdminLP(&b, strconv.Itoa(len(r.Policy.Callers)))
	for _, c := range r.Policy.Callers {
		communicationAdminLP(&b, strings.ToLower(c.ID))
		communicationAdminLP(&b, c.Label)
		if c.Thread == nil {
			communicationAdminLP(&b, "-")
		} else {
			communicationAdminLP(&b, "+"+*c.Thread)
		}
		communicationAdminLP(&b, c.TokenHash)
		communicationAdminLP(&b, flag(c.Paused))
	}
	return b.String()
}

func communicationCallerAdminMessage(node string, r CommunicationRequest, p communicationAdminProof) []byte {
	var b strings.Builder
	b.WriteString(communicationCallerAdminDomain)
	communicationAdminLP(&b, node)
	communicationAdminLP(&b, r.Operation)
	communicationAdminLP(&b, p.Nonce)
	communicationAdminLP(&b, strconv.FormatInt(p.Expires, 10))
	communicationAdminLP(&b, communicationCallerAdminArguments(r))
	return []byte(b.String())
}

func communicationCallerAdminFingerprint(public string) string {
	raw, err := base64.StdEncoding.DecodeString(public)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

// communicationCallerAdminVerify authorizes one mutating caller_ request. It
// runs under the communication lock. A valid proof from the first key ever
// presented pins that key; the nonce is consumed before the operation runs.
func communicationCallerAdminVerify(root, node string, r CommunicationRequest, now time.Time) error {
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return errors.New("owner administration required")
	}
	refuse := errors.New("caller administration requires a valid Relay app proof")
	if strings.TrimSpace(node) == "" {
		// A proof must name this node; never accept one bound to no node.
		return errors.New("caller administration unavailable: node identity unknown")
	}
	p := r.AdminProof
	if p == nil {
		return refuse
	}
	public, err1 := base64.StdEncoding.DecodeString(p.PublicKey)
	sig, err2 := base64.StdEncoding.DecodeString(p.Signature)
	nonce, err3 := base64.StdEncoding.DecodeString(p.Nonce)
	if err1 != nil || err2 != nil || err3 != nil || len(public) != ed25519.PublicKeySize ||
		len(sig) != ed25519.SignatureSize || len(nonce) != 16 {
		return refuse
	}
	if !ed25519.Verify(ed25519.PublicKey(public), communicationCallerAdminMessage(node, r, *p), sig) {
		return refuse
	}
	if p.Expires <= now.Unix() {
		return errors.New("caller administration proof expired")
	}
	if p.Expires > now.Add(communicationCallerAdminMaxLife).Unix() {
		return errors.New("caller administration proof lifetime too long")
	}
	var st communicationAdminState
	path := communicationCallerAdminPath(root)
	if err := communicationRead(path, &st); err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			return errors.New("caller administration key state unavailable")
		}
		st = communicationAdminState{Version: 1, PublicKey: p.PublicKey} // first use pins
	}
	if st.Version != 1 || st.PublicKey != p.PublicKey {
		return errors.New("caller administration key does not match the key pinned on this host")
	}
	live := st.Nonces[:0:0]
	for _, n := range st.Nonces {
		if n.Expires > now.Unix() {
			if n.Nonce == p.Nonce {
				return errors.New("caller administration proof already used")
			}
			live = append(live, n)
		}
	}
	if len(live) >= communicationCallerAdminNonces {
		return errors.New("too many recent caller administration requests")
	}
	st.Nonces = append(live, communicationAdminNonce{Nonce: p.Nonce, Expires: p.Expires})
	if err := communicationAtomic(path, st); err != nil {
		return err
	}
	return nil
}

// communicationCallerAdminPinned returns the pinned key's fingerprint, or "".
func communicationCallerAdminPinned(root string) string {
	var st communicationAdminState
	if communicationRead(communicationCallerAdminPath(root), &st) != nil || st.Version != 1 {
		return ""
	}
	return communicationCallerAdminFingerprint(st.PublicKey)
}

func communicationCallerRequest(root, node string, r CommunicationRequest) (map[string]any, error) {
	switch r.Operation {
	case "caller_list":
		return communicationPolicyAdmin(root, r)
	case "caller_admin_info":
		// Readable without proof: the node the proof must name and the pinned key.
		return map[string]any{"node_id": node, "admin_key_sha256": communicationCallerAdminPinned(root), "authority": "relayd"}, nil
	}
	if err := communicationCallerAdminVerify(root, node, r, time.Now()); err != nil {
		return nil, err
	}
	return communicationPolicyAdmin(root, r)
}
