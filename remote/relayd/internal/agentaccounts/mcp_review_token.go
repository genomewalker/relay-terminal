package agentaccounts

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// A restart drops the key and all issued reviews. Tokens never expose an
// unkeyed digest of secret-bearing configuration.
var mcpReviewKey struct {
	once   sync.Once
	key    [32]byte
	err    error
	mu     sync.Mutex
	issued map[string]time.Time
}

func exactMCPMac(account Account, raw json.RawMessage, nonce string) (string, error) {
	mcpReviewKey.once.Do(func() { _, mcpReviewKey.err = rand.Read(mcpReviewKey.key[:]) })
	if mcpReviewKey.err != nil {
		return "", errors.New("account review key unavailable")
	}
	payload, err := json.Marshal(struct {
		Account Account         `json:"account"`
		Servers json.RawMessage `json:"servers"`
		Nonce   string          `json:"nonce"`
	}{account, raw, nonce})
	if err != nil {
		return "", err
	}
	mac := hmac.New(sha256.New, mcpReviewKey.key[:])
	_, _ = mac.Write(payload)
	return hex.EncodeToString(mac.Sum(nil)), nil
}
func issueMCPReview(account Account, raw json.RawMessage) (string, error) {
	var random [32]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", errors.New("account review unavailable")
	}
	nonce := hex.EncodeToString(random[:])
	mac, err := exactMCPMac(account, raw, nonce)
	if err != nil {
		return "", err
	}
	mcpReviewKey.mu.Lock()
	defer mcpReviewKey.mu.Unlock()
	now := time.Now()
	if mcpReviewKey.issued == nil {
		mcpReviewKey.issued = make(map[string]time.Time)
	}
	for id, expiry := range mcpReviewKey.issued {
		if !now.Before(expiry) {
			delete(mcpReviewKey.issued, id)
		}
	}
	if len(mcpReviewKey.issued) >= 1024 {
		return "", errors.New("account review queue is full")
	}
	mcpReviewKey.issued[nonce] = now.Add(2 * time.Minute)
	return nonce + "." + mac, nil
}
func consumeMCPReview(account Account, raw json.RawMessage, token string) error {
	parts := strings.Split(token, ".")
	if len(parts) != 2 || len(parts[0]) != 64 || len(parts[1]) != 64 {
		return errPreviewChanged
	}
	if _, err := hex.DecodeString(parts[0]); err != nil {
		return errPreviewChanged
	}
	got, err := hex.DecodeString(parts[1])
	if err != nil {
		return errPreviewChanged
	}
	expected, err := exactMCPMac(account, raw, parts[0])
	if err != nil {
		return err
	}
	want, _ := hex.DecodeString(expected)
	if !hmac.Equal(got, want) {
		return errPreviewChanged
	}
	mcpReviewKey.mu.Lock()
	defer mcpReviewKey.mu.Unlock()
	expiry, ok := mcpReviewKey.issued[parts[0]]
	if !ok || !time.Now().Before(expiry) {
		delete(mcpReviewKey.issued, parts[0])
		return errPreviewChanged
	}
	// Never retry a consumed review after an ambiguous write.
	delete(mcpReviewKey.issued, parts[0])
	return nil
}

// PreviewMCPExact returns a metadata-only view and a short-lived, single-use
// opaque token bound to the exact source and target account configuration.
func PreviewMCPExact(home string, account Account) (MCPPreview, error) {
	if account.Provider != "claude" || account.Dir == "" {
		return MCPPreview{}, errors.New("exact preview supports non-default Claude accounts only")
	}
	raw, err := readJSONKey(filepath.Join(home, ".claude.json"), "mcpServers")
	if err != nil {
		return MCPPreview{}, err
	}
	servers, err := claudeServerKeys(raw)
	if err != nil {
		return MCPPreview{}, err
	}
	preview, err := previewOf(account, servers)
	if err != nil {
		return MCPPreview{}, err
	}
	preview.Fingerprint, err = issueMCPReview(account, raw)
	return preview, err
}
