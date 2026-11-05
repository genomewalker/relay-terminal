package daemon

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"time"
)

// A source attestation carries kernel-derived sender proof across a broker
// (the desktop app, or the scoped remote bridge in front of it). relayd mints
// it only for its own verified caller and records only what it observed itself.
// The broker carries the ID; the recipient trusts what the source host returns.

const (
	communicationAttestTTL   = 2 * time.Minute
	communicationAttestKeep  = 24 * time.Hour
	communicationAttestLimit = 4096
)

var communicationAttestID = regexp.MustCompile(`^[0-9a-f]{32}$`)

type communicationAttestation struct {
	Version         int       `json:"version"`
	ID              string    `json:"id"`
	NodeID          string    `json:"node_id"`
	SourcePaneID    string    `json:"source_pane_id"`
	Provider        string    `json:"provider"`
	SessionID       string    `json:"session_id"`
	PID             int       `json:"pid"`
	Start           string    `json:"start"`
	PermissionClass string    `json:"permission_class,omitempty"`
	TargetPaneID    string    `json:"target_pane_id"`
	MessageID       string    `json:"message_id"`
	TextSHA256      string    `json:"text_sha256"`
	ClientID        string    `json:"client_id"`
	CreatedAt       time.Time `json:"created_at"`
	ExpiresAt       time.Time `json:"expires_at"`
}

type communicationAttestDeps struct {
	observe func(string) communicationMember
	now     func() time.Time
}

var defaultCommunicationAttestDeps = communicationAttestDeps{observe: communicationObserve, now: time.Now}

func communicationTextDigest(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

func communicationAttestPath(root, id string) string {
	return filepath.Join(root, "attest-"+id+".json")
}

func communicationAttestLiveMode(source communicationMember) string {
	return communicationSenderClass(source)
}

// communicationAttestPrune bounds the attestation store. Called under the
// communication lock; old records are history only and are never reused.
func communicationAttestPrune(root string, now time.Time) error {
	paths, err := filepath.Glob(filepath.Join(root, "attest-*"))
	if err != nil {
		return err
	}
	kept := 0
	for _, path := range paths {
		info, err := os.Lstat(path)
		if err == nil && info.Mode().IsRegular() && now.Sub(info.ModTime()) > communicationAttestKeep {
			_ = os.Remove(path)
			continue
		}
		kept++
	}
	if kept >= communicationAttestLimit {
		return errors.New("source attestation store exceeds limit")
	}
	return nil
}

// Called only while holding the communication lock, after
// ReconcileCommunicationActor and communicationAuthorize.
func communicationAttest(root, nodeID string, r CommunicationRequest, d communicationAttestDeps) (map[string]any, error) {
	if !communicationSourceVerified(r) {
		return nil, errors.New("source attestation requires the kernel-verified caller pane")
	}
	if !validSessionID.MatchString(r.PaneID) || r.PaneID == r.SourcePaneID || !validSessionID.MatchString(r.MessageID) {
		return nil, errors.New("exact target pane and message identity required")
	}
	if r.Text == "" || len(r.Text) > 16384 {
		return nil, errors.New("invalid collaborator message")
	}
	// Every sender field comes from this host's observation, never the request.
	source := d.observe(r.SourcePaneID)
	if source.Endpoint == nil || source.Unavailable != "" || source.PID <= 1 || source.Start == "" ||
		source.SessionID == "" || (source.Provider != "claude" && source.Provider != "codex") {
		return nil, errors.New("the sending pane has no verified native session")
	}
	now := d.now().UTC()
	if err := communicationAttestPrune(root, now); err != nil {
		return nil, err
	}
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return nil, err
	}
	record := communicationAttestation{Version: 1, ID: hex.EncodeToString(raw), NodeID: nodeID,
		SourcePaneID: r.SourcePaneID, Provider: source.Provider, SessionID: source.SessionID, PID: source.PID,
		Start: source.Start, PermissionClass: communicationAttestLiveMode(source), TargetPaneID: r.PaneID,
		MessageID: r.MessageID, TextSHA256: communicationTextDigest(r.Text), ClientID: r.ClientID,
		CreatedAt: now, ExpiresAt: now.Add(communicationAttestTTL)}
	if err := communicationAtomic(communicationAttestPath(root, record.ID), record); err != nil {
		return nil, err
	}
	return map[string]any{"attestation_id": record.ID, "expires_at": record.ExpiresAt, "authority": "relayd"}, nil
}

// communicationAttestConsume is owner administration over the host transport.
// It spends an attestation once, for exactly the message it was minted for,
// while the same source conversation is still live.
func communicationAttestConsume(root string, r CommunicationRequest, d communicationAttestDeps) (map[string]any, error) {
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return nil, errors.New("owner administration required")
	}
	if !communicationAttestID.MatchString(r.AttestationID) {
		return nil, errors.New("invalid source attestation identity")
	}
	var record communicationAttestation
	if err := communicationRead(communicationAttestPath(root, r.AttestationID), &record); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, errors.New("unknown source attestation")
		}
		return nil, err
	}
	if record.Version != 1 || record.ID != r.AttestationID {
		return nil, errors.New("invalid source attestation record")
	}
	if record.SourcePaneID != r.SourcePaneID || record.TargetPaneID != r.PaneID ||
		record.MessageID != r.MessageID || record.TextSHA256 != communicationTextDigest(r.Text) {
		return nil, errors.New("source attestation does not match this message")
	}
	if !d.now().UTC().Before(record.ExpiresAt) {
		return nil, errors.New("source attestation expired")
	}
	// Spend before re-observing: a failed recheck burns the proof rather than
	// leaving it reusable by a later broker.
	used, err := os.OpenFile(filepath.Join(root, "attest-"+record.ID+".used"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		if errors.Is(err, os.ErrExist) {
			return nil, errors.New("source attestation already used")
		}
		return nil, err
	}
	used.Close()
	live := d.observe(record.SourcePaneID)
	if live.Endpoint == nil || live.PID != record.PID || live.Start != record.Start ||
		live.SessionID != record.SessionID || live.Provider != record.Provider {
		return nil, errors.New("source conversation changed since attestation")
	}
	// A mode change since minting is not asserted either way.
	mode := record.PermissionClass
	if mode != "" && communicationAttestLiveMode(live) != mode {
		mode = ""
	}
	source := map[string]any{"authentication": "source_host_attested", "hostID": record.NodeID,
		"paneID": record.SourcePaneID, "sessionID": record.SessionID, "provider": record.Provider,
		"attestationID": record.ID, "submittingClientID": record.ClientID}
	if mode != "" {
		source["permissionClass"] = mode
	}
	return map[string]any{"source": source, "authority": "relayd"}, nil
}
