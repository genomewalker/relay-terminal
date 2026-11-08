package agentaccounts

import (
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"time"
)

// A Claude account move resumes the conversation with the target account's
// .claude.json. When that account never finished first-run onboarding, or
// never accepted the trust dialog for the pane's folder, the resumed agent
// stops at the theme picker, security notes, the external CLAUDE.md import
// prompt or the trust dialog and the move cannot be verified. Before the
// source agent exits, PrepareClaudeMove checks the target and, if needed,
// copies only the allowlisted first-run answers (claudeFirstRunKeys and, for
// the pane's folder and its parent folders, claudeProjectTrustKeys) from the
// source account, which is running there now, then checks the file again.
// Identity and credential keys (oauthAccount, userID, tokens, API keys and
// every key not in those lists) are never read into the merge.

// MoveOnboarding states.
const (
	MoveOnboardingReady   = "ready"
	MoveOnboardingUpdated = "updated"
)

// MoveOnboarding is what PrepareClaudeMove did to the target account.
type MoveOnboarding struct {
	Status string `json:"status"`
	Copied int    `json:"copied"`
	// Links is the shared configuration linked into the target first
	// (linkMoveTarget); empty for a move into the main account.
	Links []LinkResult `json:"links,omitempty"`
}

// claudeUnanswered are allowlisted answers whose false is Claude's own
// default (it writes hasTrustDialogAccepted: false for every folder it starts
// in before the dialog is answered), so a target false is replaced by the
// source's true. Every other allowlisted key is only added when missing.
var claudeUnanswered = map[string]bool{"hasCompletedOnboarding": true, "hasSeenTasksHint": true,
	"shiftEnterKeyBindingInstalled": true, "hasTrustDialogAccepted": true}

// afterMoveOnboardingWrite lets a test change the file between the write and
// its re-verification.
var afterMoveOnboardingWrite = func(path string) {}

// errNoCheckedExchange: the target file exists and its file system (NFS, for
// example) has no atomic exchange. A plain rename would discard a save the
// provider makes between Relay's check and the rename (Claude does not take
// Relay's lock), so nothing is written and the move is refused.
var errNoCheckedExchange = errors.New("no checked exchange")

// claudeAccountFile is the .claude.json an agent in account reads: the main
// ~/.claude.json for the default account, else <dir>/.claude.json.
func claudeAccountFile(home string, account Account) string {
	if account.Dir == "" {
		return filepath.Join(home, ".claude.json")
	}
	return filepath.Join(account.Root(home), ".claude.json")
}

// PrepareClaudeMove readies the target Claude account (its directory as the
// registry spells it, "" for the main account) for a conversation resumed in
// dir, copying answers from the source account. It returns an error, with
// nothing moved, unless the target passes the check afterwards.
func PrepareClaudeMove(home, source, target, dir string) (MoveOnboarding, error) {
	if !filepath.IsAbs(dir) || filepath.Clean(dir) != dir {
		return MoveOnboarding{}, errors.New("the pane's folder is not an absolute path")
	}
	registry, err := Load(home)
	if err != nil {
		return MoveOnboarding{}, errors.New("the account list could not be read")
	}
	from, ok := registeredClaude(registry, home, source)
	if !ok {
		return MoveOnboarding{}, errors.New("the source Claude account is not registered on this host")
	}
	to, ok := registeredClaude(registry, home, target)
	if !ok {
		return MoveOnboarding{}, errors.New("the target Claude account is not registered on this host")
	}
	if from.Label == to.Label {
		return MoveOnboarding{}, errors.New("the source and target are the same account")
	}
	unlock, err := lockAccounts(home, false)
	if err != nil {
		return MoveOnboarding{}, errors.New("an accounts change is in progress; try the move again when it finishes")
	}
	defer unlock()
	links := linkMoveTarget(home, to, time.Now())
	result, err := prepareClaudeMoveFile(claudeAccountFile(home, from), claudeAccountFile(home, to), dir, to.Label)
	result.Links = links
	return result, err
}

func registeredClaude(registry Registry, home, dir string) (Account, bool) {
	for _, account := range registry.Accounts {
		if account.Provider != "claude" {
			continue
		}
		if account.Dir == dir || (dir != "" && account.Dir != "" &&
			resolvedRoot(account.Root(home)) == resolvedRoot(Account{Provider: "claude", Dir: dir}.Root(home))) {
			return account, true
		}
	}
	return Account{}, false
}

func prepareClaudeMoveFile(sourcePath, targetPath, dir, label string) (MoveOnboarding, error) {
	before, data, err := readAccountFile(targetPath, 16<<20)
	if err != nil {
		return MoveOnboarding{}, errors.New("the target account's " + err.Error())
	}
	document := map[string]json.RawMessage{}
	if before.exists && (json.Unmarshal(data, &document) != nil || document == nil) {
		return MoveOnboarding{}, errors.New("the target account's .claude.json is not valid JSON; it was not changed")
	}
	_, sourceData, err := readAccountFile(sourcePath, 16<<20)
	if err != nil || sourceData == nil {
		return MoveOnboarding{}, errors.New("the source account's .claude.json could not be read")
	}
	var sourceDocument map[string]json.RawMessage
	if json.Unmarshal(sourceData, &sourceDocument) != nil || sourceDocument == nil {
		return MoveOnboarding{}, errors.New("the source account's .claude.json is not valid JSON")
	}
	sourceProjects, err := projectEntries(sourceDocument)
	if err != nil {
		return MoveOnboarding{}, errors.New("the source account's " + err.Error())
	}
	gaps, err := claudeOnboardingGaps(document, sourceProjects, dir)
	if err != nil {
		return MoveOnboarding{}, err
	}
	if len(gaps) == 0 {
		return MoveOnboarding{Status: MoveOnboardingReady}, nil
	}
	copied, err := mergeClaudeMove(document, sourceDocument, sourceProjects, dir)
	if err != nil {
		return MoveOnboarding{}, err
	}
	// A copy that would still leave a first-run screen is not written.
	if remaining, err := claudeOnboardingGaps(document, sourceProjects, dir); err != nil || copied == 0 || len(remaining) > 0 {
		if err == nil && len(remaining) > 0 {
			gaps = remaining
		}
		return MoveOnboarding{}, errors.New("the target account has not finished Claude's first run (" +
			strings.Join(gaps, ", ") + ") and the source account has no answers to copy; start Claude once in that account")
	}
	next, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return MoveOnboarding{}, err
	}
	if err := writeMoveOnboarding(targetPath, before, data, next); err != nil {
		if errors.Is(err, errNoCheckedExchange) {
			return MoveOnboarding{}, errors.New(label + " has not finished Claude setup for this folder (" + strings.Join(gaps, ", ") +
				") and Relay cannot update its .claude.json safely on this file system; open Claude once with that account here, then move again")
		}
		return MoveOnboarding{}, err
	}
	afterMoveOnboardingWrite(targetPath)
	// Re-verify what is on disk now, not what was written.
	if gaps, err := claudeTargetGaps(targetPath, sourceProjects, dir); err != nil || len(gaps) > 0 {
		reason := strings.Join(gaps, ", ")
		if err != nil {
			reason = err.Error()
		}
		return MoveOnboarding{}, errors.New("the target account's first-run answers did not verify after the copy (" + reason + ")")
	}
	return MoveOnboarding{Status: MoveOnboardingUpdated, Copied: copied}, nil
}

func claudeTargetGaps(path string, sourceProjects map[string]map[string]json.RawMessage, dir string) ([]string, error) {
	state, data, err := readAccountFile(path, 16<<20)
	if err != nil {
		return nil, err
	}
	if !state.exists {
		return nil, errors.New(".claude.json is missing")
	}
	document := map[string]json.RawMessage{}
	if json.Unmarshal(data, &document) != nil || document == nil {
		return nil, errors.New(".claude.json is not valid JSON")
	}
	return claudeOnboardingGaps(document, sourceProjects, dir)
}

// writeMoveOnboarding replaces the target file with next, keeping its
// permissions: a temporary file beside it, fsynced, then an atomic exchange
// that verifies the displaced file (a provider save that lands meanwhile is
// swapped back and the merge refused). Without an atomic exchange an existing
// file is never replaced (errNoCheckedExchange). A missing file is created
// 0600 and only if still missing.
func writeMoveOnboarding(path string, before fileState, data, next []byte) error {
	if !sameContent(path, before, data) {
		return errors.New("the target account's .claude.json changed while Relay read it; it was not changed")
	}
	if !before.exists {
		return writeNew(path, next)
	}
	mode := before.info.Mode().Perm()
	supported, err := replaceCheckedMode(path, next, mode, func(displaced string) bool { return holds(displaced, data) })
	if !supported {
		return errNoCheckedExchange
	}
	return err
}

// projectEntries is a document's projects as objects; an entry that is not
// an object is left out.
func projectEntries(document map[string]json.RawMessage) (map[string]map[string]json.RawMessage, error) {
	result := map[string]map[string]json.RawMessage{}
	raw, ok := document["projects"]
	if !ok {
		return result, nil
	}
	var projects map[string]json.RawMessage
	if json.Unmarshal(raw, &projects) != nil || projects == nil {
		return nil, errors.New(".claude.json projects value is not an object")
	}
	for path, value := range projects {
		var entry map[string]json.RawMessage
		if json.Unmarshal(value, &entry) == nil && entry != nil {
			result[path] = entry
		}
	}
	return result, nil
}

// folderChain is dir and each parent folder up to the root, nearest first:
// Claude accepts a trust answer given for the folder or any parent of it.
func folderChain(dir string) []string {
	chain := []string{dir}
	for parent := filepath.Dir(dir); parent != chain[len(chain)-1]; parent = filepath.Dir(parent) {
		chain = append(chain, parent)
	}
	return chain
}

func isTrue(raw json.RawMessage) bool {
	var value bool
	return raw != nil && json.Unmarshal(raw, &value) == nil && value
}

// claudeOnboardingGaps names what keeps a Claude started in dir at a
// first-run screen: onboarding not completed or not versioned, the folder
// (or a parent) not trusted, or the external CLAUDE.md prompt not answered
// for a folder where the source account answered it.
func claudeOnboardingGaps(document map[string]json.RawMessage, sourceProjects map[string]map[string]json.RawMessage, dir string) ([]string, error) {
	var gaps []string
	if !isTrue(document["hasCompletedOnboarding"]) {
		gaps = append(gaps, "hasCompletedOnboarding")
	}
	var version string
	if json.Unmarshal(document["lastOnboardingVersion"], &version) != nil || version == "" {
		gaps = append(gaps, "lastOnboardingVersion")
	}
	projects, err := projectEntries(document)
	if err != nil {
		return nil, errors.New("the target account's " + err.Error() + "; it was not changed")
	}
	trusted := false
	for _, folder := range folderChain(dir) {
		if isTrue(projects[folder]["hasTrustDialogAccepted"]) {
			trusted = true
			break
		}
	}
	if !trusted {
		gaps = append(gaps, "projects["+dir+"].hasTrustDialogAccepted")
	}
	for _, folder := range folderChain(dir) {
		if isTrue(sourceProjects[folder]["hasClaudeMdExternalIncludesWarningShown"]) &&
			!isTrue(projects[folder]["hasClaudeMdExternalIncludesWarningShown"]) {
			gaps = append(gaps, "projects["+folder+"].hasClaudeMdExternalIncludesWarningShown")
		}
	}
	return gaps, nil
}

// mergeClaudeMove copies the allowlisted answers from source into document
// and returns how many it changed. Top-level keys come from claudeFirstRunKeys
// only; project keys from claudeProjectTrustKeys only, for dir and its parent
// folders that the source has an entry for. Nothing else is read from source.
func mergeClaudeMove(document, source map[string]json.RawMessage, sourceProjects map[string]map[string]json.RawMessage, dir string) (int, error) {
	copied := 0
	for _, key := range claudeFirstRunKeys {
		if adoptAnswer(document, source, key) {
			copied++
		}
	}
	projects := map[string]json.RawMessage{}
	if raw, ok := document["projects"]; ok && (json.Unmarshal(raw, &projects) != nil || projects == nil) {
		return 0, errors.New("the target account's .claude.json projects value is not an object; it was not changed")
	}
	changedProjects := false
	for _, folder := range folderChain(dir) {
		from, ok := sourceProjects[folder]
		if !ok {
			continue
		}
		entry := map[string]json.RawMessage{}
		if existing, ok := projects[folder]; ok && (json.Unmarshal(existing, &entry) != nil || entry == nil) {
			// Not an object: the account's own value is left as it is.
			continue
		}
		if isTrue(from["hasClaudeMdExternalIncludesWarningShown"]) && !isTrue(entry["hasClaudeMdExternalIncludesWarningShown"]) {
			// Until the target has shown the external CLAUDE.md warning, its
			// approval is Claude's default; the source's answers to both apply.
			delete(entry, "hasClaudeMdExternalIncludesWarningShown")
			delete(entry, "hasClaudeMdExternalIncludesApproved")
		}
		changed := 0
		for _, key := range claudeProjectTrustKeys {
			if adoptAnswer(entry, from, key) {
				changed++
			}
		}
		if changed == 0 {
			continue
		}
		data, err := json.Marshal(entry)
		if err != nil {
			return 0, err
		}
		projects[folder] = data
		copied += changed
		changedProjects = true
	}
	if changedProjects {
		data, err := json.Marshal(projects)
		if err != nil {
			return 0, err
		}
		document["projects"] = data
	}
	return copied, nil
}

// adoptAnswer sets document[key] from source when the target has no value,
// or for an unanswered key, when the target has Claude's default false and
// the source true. An answer the target already has is kept.
func adoptAnswer(document, source map[string]json.RawMessage, key string) bool {
	value, ok := source[key]
	if !ok {
		return false
	}
	current, has := document[key]
	if !has || (claudeUnanswered[key] && !isTrue(current) && isTrue(value)) {
		document[key] = value
		return true
	}
	return false
}

// linkMoveTarget links the main account's shared configuration (claudeLinks:
// settings, local settings, CLAUDE.md, skills, agents, commands, plugins) into a move's target
// account, so the moved agent starts with the user's status line, hooks,
// plugins and permissions. It is the link step of Sync without the reviewed
// MCP merge: an own file is kept as a timestamped backup, a link the user
// pointed elsewhere is left alone, and nothing here refuses the move.
func linkMoveTarget(home string, target Account, now time.Time) []LinkResult {
	if target.Dir == "" {
		return nil
	}
	main, root := defaultRoot(home, "claude"), target.Root(home)
	if distinctRoots(main, root) != nil {
		return nil
	}
	stamp := now.UTC().Format("20060102T150405Z")
	links := make([]LinkResult, 0, len(claudeLinks))
	for _, name := range claudeLinks {
		destination := filepath.Join(root, name)
		links = append(links, linkShared(filepath.Join(main, name), destination, observe(destination), stamp))
	}
	return links
}
