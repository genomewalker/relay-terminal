package daemon

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

type workPaneCredential struct {
	Version  int    `json:"version"`
	Node     string `json:"node"`
	Pane     string `json:"pane"`
	Provider string `json:"provider"`
	Session  string `json:"session"`
	Caller   string `json:"caller"`
	Token    string `json:"token"`
}

func workCredentialPath(root, pane string) string {
	return filepath.Join(root, "work-client-"+pane+".json")
}
func workCredentialCaller(node, pane, session string) string {
	h := sha256.Sum256([]byte("relay-work-native-client-v1\x00" + node + "\n" + pane + "\n" + session))
	h[6] = (h[6] & 15) | 64
	h[8] = (h[8] & 63) | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", h[:4], h[4:6], h[6:8], h[8:10], h[10:16])
}

// Provisioning is an owner operation. It never emits a token. Native callers
// can load only the record selected by their kernel-derived pane and current
// provider session; the normal caller pause policy remains authoritative.
func ProvisionWorkPaneCredential(pane string, out io.Writer) error {
	if !validSessionID.MatchString(pane) {
		return errors.New("exact pane required")
	}
	observed := communicationObserve(pane)
	if observed.Endpoint == nil || observed.Unavailable != "" || !validSessionID.MatchString(observed.SessionID) || (observed.Provider != "codex" && observed.Provider != "claude") {
		return errors.New("exact live pane conversation required")
	}
	result, err := provisionWorkCredential(communicationRoot(), currentCommunicationNodeID(), pane, observed.Provider, observed.SessionID)
	if err != nil {
		return err
	}
	return EncodeJSON(out, result)
}
func provisionWorkCredential(root, node, pane, provider, session string) (map[string]any, error) {
	if !canonicalRouteToken(node) || !validSessionID.MatchString(pane) || !validSessionID.MatchString(session) || (provider != "codex" && provider != "claude") {
		return nil, errors.New("exact native conversation required")
	}
	var credential workPaneCredential
	err := communicationFanoutLocked(root, func() error {
		if _, e := communicationAuthorize(root, CommunicationRequest{Operation: "route_link_set"}); e != nil {
			return e
		}
		path := workCredentialPath(root, pane)
		e := communicationRead(path, &credential)
		if errors.Is(e, os.ErrNotExist) {
			var secret [32]byte
			if _, e = io.ReadFull(rand.Reader, secret[:]); e != nil {
				return e
			}
			credential = workPaneCredential{Version: 1, Node: node, Pane: pane, Provider: provider, Session: session, Caller: workCredentialCaller(node, pane, session), Token: base64.RawURLEncoding.EncodeToString(secret[:])}
			if e = communicationAtomic(path, credential); e != nil {
				return e
			}
		} else if e != nil {
			return e
		}
		if credential.Version != 1 || credential.Node != node || credential.Pane != pane || credential.Provider != provider || credential.Session != session || credential.Caller != workCredentialCaller(node, pane, session) || len(credential.Token) != 43 {
			return errors.New("saved native credential belongs to a different conversation")
		}
		hash := sha256.Sum256([]byte(credential.Token))
		_, e = communicationPolicyAdmin(root, CommunicationRequest{Operation: "caller_register", Policy: &communicationPolicy{Callers: []communicationCaller{{ID: credential.Caller, Label: "Native Work link pane " + pane[:8], TokenHash: hex.EncodeToString(hash[:])}}}})
		return e
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{"status": "registered", "pane_id": pane, "session_id": session, "caller_id": credential.Caller, "credential_exposed": false}, nil
}
func readWorkCredential(root, node string, origin workRequestOrigin) (string, error) {
	if !validSessionID.MatchString(origin.pane) || origin.thread != "" || origin.revalidate == nil {
		return "", errors.New("kernel-verified native pane required")
	}
	if e := origin.revalidate(); e != nil {
		return "", e
	}
	var c workPaneCredential
	if e := communicationRead(workCredentialPath(root, origin.pane), &c); e != nil {
		return "", errors.New("native Work-link credential not provisioned")
	}
	if c.Version != 1 || c.Node != node || c.Pane != origin.pane || !validSessionID.MatchString(c.Session) || c.Caller != workCredentialCaller(node, origin.pane, c.Session) || len(c.Token) != 43 {
		return "", errors.New("invalid native Work-link credential")
	}
	current := communicationObserve(origin.pane)
	if current.Endpoint == nil || current.Unavailable != "" || current.Provider != c.Provider || current.SessionID != c.Session {
		return "", errors.New("credential conversation changed")
	}
	if e := origin.revalidate(); e != nil {
		return "", e
	}
	return c.Token, nil
}
