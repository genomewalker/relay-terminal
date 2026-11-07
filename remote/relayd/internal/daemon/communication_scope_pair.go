package daemon

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// Per-pair scopes. Each reviewed pair of panes has its own owner-signed record,
// keyed by the exact pair, so a new pair never replaces another pair's grant.
// The single scope-record.json written before this remains readable for the
// pair it names; nothing else is merged into it.

// communicationScopePairKey is the stable key of an exact unordered pair.
func communicationScopePairKey(a, b communicationScopeMember) string {
	keys := []string{communicationScopeKey(a), communicationScopeKey(b)}
	sort.Strings(keys)
	digest := sha256.Sum256([]byte("relay-scope-pair-v1\x00" + keys[0] + "\x00" + keys[1]))
	return hex.EncodeToString(digest[:16])
}

func communicationScopePairPath(root string, key string) string {
	return filepath.Join(root, "scope-pair-"+key+".json")
}

// communicationScopeExactPair returns the two members of a per-pair body.
func communicationScopeExactPair(body communicationScopeBody) (communicationScopeMember, communicationScopeMember, bool) {
	if len(body.Members) != 2 {
		return communicationScopeMember{}, communicationScopeMember{}, false
	}
	return body.Members[0], body.Members[1], true
}

// communicationScopeStorePair verifies a signed per-pair record addressed to this
// holder and stores it. A record never replaces one with an equal or higher
// revision for the same pair.
func communicationScopeStorePair(root, node string, rec communicationScopeRecord, trusted []communicationTrustedNode) (communicationScopeBody, error) {
	body, err := communicationVerifyScope(rec, trusted, node)
	if err != nil {
		return body, err
	}
	a, b, ok := communicationScopeExactPair(body)
	if !ok || a == b {
		return body, errors.New("a per-pair scope names exactly two distinct members")
	}
	path := communicationScopePairPath(root, communicationScopePairKey(a, b))
	var current communicationScopeRecord
	if err := communicationRead(path, &current); err == nil {
		prior, verr := communicationVerifyScope(current, trusted, node)
		if verr != nil || body.Revision <= prior.Revision {
			return body, errors.New("per-pair scope revision conflict")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return body, err
	}
	if err := communicationAtomic(path, rec); err != nil {
		return body, err
	}
	return body, nil
}

// communicationScopePairLoad returns the verified per-pair body for the exact
// pair, or found=false when none is stored on this host.
func communicationScopePairLoad(root, node string, a, b communicationScopeMember) (communicationScopeBody, bool, error) {
	var rec communicationScopeRecord
	path := communicationScopePairPath(root, communicationScopePairKey(a, b))
	if err := communicationRead(path, &rec); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return communicationScopeBody{}, false, nil
		}
		return communicationScopeBody{}, false, err
	}
	trusted, err := communicationTrustedNodes(root, defaultCommunicationSigningDeps(root, node), node)
	if err != nil {
		return communicationScopeBody{}, false, err
	}
	body, err := communicationVerifyScope(rec, trusted, node)
	if err != nil {
		return communicationScopeBody{}, false, err
	}
	if !body.holdsBoth(node, a, b) {
		return communicationScopeBody{}, false, errors.New("per-pair scope does not hold this exact pair")
	}
	return body, true, nil
}

// holdsBoth reports whether this per-pair body holds the exact pair on the holder.
func (body communicationScopeBody) holdsBoth(holder string, a, b communicationScopeMember) bool {
	if body.HolderNodeID != holder || len(body.Members) != 2 {
		return false
	}
	matched := 0
	for _, member := range body.Members {
		if member == a || member == b {
			matched++
		}
	}
	return matched == 2
}

// communicationSignScope signs one holder's record of a per-pair scope with this
// host's key. The record is the same bytes a verifier on any holder checks.
func communicationSignScope(root, node string, body communicationScopeBody) (communicationScopeRecord, error) {
	var empty communicationScopeRecord
	key, cert, err := communicationFileKeyStore{root: root, node: node}.HostKey()
	if err != nil {
		return empty, err
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return empty, err
	}
	signature := ed25519.Sign(key, append([]byte(communicationScopeDomain), raw...))
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Raw})
	return communicationScopeRecord{Version: 1, Body: base64.StdEncoding.EncodeToString(raw),
		OwnerCertificatePEM: string(certPEM), Signature: base64.StdEncoding.EncodeToString(signature)}, nil
}

// communicationPairScopeBody is the body of one holder's record of a pair.
func communicationPairScopeBody(scopeID, holder, owner string, revision uint64, now time.Time, a, b communicationScopeMember) communicationScopeBody {
	members := []communicationScopeMember{a, b}
	sort.Slice(members, func(i, j int) bool { return communicationScopeKey(members[i]) < communicationScopeKey(members[j]) })
	return communicationScopeBody{Version: 1, Purpose: communicationScopePurpose, ScopeID: scopeID, HolderNodeID: holder,
		OwnerNodeID: owner, Revision: revision, CreatedAt: now.UTC(), Members: members}
}
