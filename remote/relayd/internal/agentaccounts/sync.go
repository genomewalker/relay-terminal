package agentaccounts

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// Shared configuration linked from the main directory into another account.
// Credentials, account state, history, sessions, logs and caches are never
// in these lists (see neverShared); a test keeps the two lists disjoint.
var (
	claudeLinks = []string{"CLAUDE.md", "settings.json", "settings.local.json", "skills", "agents", "commands", "plugins"}
	codexLinks  = []string{"AGENTS.md", "prompts", "skills"}
	neverShared = []string{".credentials.json", ".claude.json", "auth.json", ".device-keys.json", "history.jsonl",
		"history", "sessions", "projects", "archived_sessions", "log", "logs", "cache", "debug", "shell-snapshots",
		"session-env", "todos", "file-history", "statsig", "ide", "backups", ".config.json"}
)

// Link states reported per shared item.
const (
	LinkLinked      = "linked"
	LinkBackedUp    = "linked_after_backup"
	LinkMissingMain = "absent_in_main"
	LinkForeign     = "foreign_link"
	LinkUnsupported = "unsupported_type"
	MergeUnchanged  = "unchanged"
	MergeUpdated    = "updated"
	MergeNothing    = "nothing_to_merge"
	MergeRefused    = "refused"
	// MergeSkipped: the account's file exists on a file system without
	// atomic exchange, so Relay left it unchanged (noAtomicExchangeNote).
	MergeSkipped     = "skipped_no_atomic_exchange"
	CodexConfigLink  = "linked"
	CodexConfigMerge = "merged"
	// History links exist only while the user opts in to shared history.
	LinkKeptOwnHistory  = "kept_own_history"
	LinkHistoryUnlinked = "history_unlinked"
)

// historyLinks are conversation history directories, linked from the main
// directory only when the account's ShareHistory opt-in is set, so a
// conversation can resume in either account. Claude's sessions/ directory
// is its live process registry, not history, and is never linked.
var historyLinks = map[string][]string{
	"claude": {"projects"},
	"codex":  {"sessions", "archived_sessions"},
}

type LinkResult struct {
	Name   string `json:"name"`
	State  string `json:"state"`
	Backup string `json:"backup,omitempty"`
}

type SyncResult struct {
	Provider string       `json:"provider"`
	Label    string       `json:"label"`
	Links    []LinkResult `json:"links"`
	// MCP is the Claude mcpServers merge or the Codex config.toml mode.
	MCP       string `json:"mcp"`
	MCPBackup string `json:"mcp_backup,omitempty"`
	MCPCount  int    `json:"mcp_servers"`
	// FirstRun is the merge of the main account's first-run and trust
	// answers (see mergeLaunchState); FirstRunAdded counts the values added.
	FirstRun      string   `json:"first_run,omitempty"`
	FirstRunAdded int      `json:"first_run_added,omitempty"`
	Notes         []string `json:"notes,omitempty"`
	// Error explains a partial sync; Links still show what was done.
	Error string `json:"error,omitempty"`
}

// Prepare creates an account directory (owner-only) so the provider's own
// login can run in it. Codex refuses a CODEX_HOME that does not exist.
func Prepare(home string, account Account) error {
	if account.Dir == "" {
		return nil
	}
	root, main := account.Root(home), defaultRoot(home, account.Provider)
	if err := distinctRoots(main, root); err != nil {
		return err
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		return err
	}
	info, err := os.Lstat(root)
	if err != nil || !info.IsDir() || !ownedByUser(info) {
		return errors.New("account directory is not a private directory owned by this user")
	}
	// MkdirAll follows links in the parents; check again what it made.
	return distinctRoots(main, root)
}

// Sync links shared configuration from the main (default) directory into a
// non-default account and merges MCP servers. It is idempotent: a second run
// changes nothing. A real file is replaced only after it is renamed to a
// timestamped backup next to it; a foreign link is reported, never replaced.
//
// It runs in two phases. The preflight reads and validates every input (both
// MCP configurations, every shared and history destination) and changes
// nothing, so a refusal there leaves the account as it was. The write phase
// uses only those validated inputs, and checks each path again just before
// changing it: a path that changed in between is reported, never replaced.
func Sync(home string, account Account, now time.Time) (SyncResult, error) {
	return syncAccount(home, account, now, nil)
}

var errPreviewChanged = errors.New("the main MCP configuration changed since it was reviewed; review it again before syncing")

// SyncReviewed is Sync for the host request. The preview fingerprint the user
// reviewed is required, and is compared with the main MCP servers that the
// preflight read, before any change.
func SyncReviewed(home string, account Account, now time.Time, fingerprint string) (SyncResult, error) {
	if fingerprint == "" {
		return SyncResult{Provider: account.Provider, Label: account.Label, Links: []LinkResult{}},
			errors.New("review the account's MCP servers before syncing; nothing was changed")
	}
	return syncAccount(home, account, now, &fingerprint)
}

func syncAccount(home string, account Account, now time.Time, reviewed *string) (SyncResult, error) {
	result := SyncResult{Provider: account.Provider, Label: account.Label, Links: []LinkResult{}}
	if account.Dir == "" {
		return result, errors.New("the main directory is the source of shared configuration; there is nothing to sync")
	}
	if err := refuseWhileRunning(account.Provider, account.Root(home)); err != nil {
		return result, firstRunWhileRunning(home, account, err, &result)
	}
	main, root := defaultRoot(home, account.Provider), account.Root(home)
	if err := distinctRoots(main, root); err != nil {
		return result, err
	}
	plan, err := preflight(home, main, root, account)
	if err != nil {
		result.MCP = MergeRefused
		return result, err
	}
	if reviewed != nil && plan.preview.Fingerprint != *reviewed {
		return result, errPreviewChanged
	}
	if err := Prepare(home, account); err != nil {
		return result, err
	}
	// Checked after Prepare, which may follow links in the parents: an
	// account that resolves to (or into) the main directory would replace
	// main files with links to themselves.
	if err := distinctRoots(main, root); err != nil {
		return result, err
	}
	stamp := now.UTC().Format("20060102T150405Z")
	for _, item := range plan.links {
		result.Links = append(result.Links, linkShared(item.source, item.destination, item.before, stamp))
	}
	syncHistory(plan.history, account, &result)
	if plan.claude != nil {
		err = plan.claude.write(stamp, &result)
	} else {
		err = plan.codex.write(stamp, &result)
	}
	if err != nil {
		return result, err
	}
	// After the MCP write, which rewrites the same file.
	var mergeErr error
	if result.FirstRun, result.FirstRunAdded, mergeErr = mergeLaunchState(home, account); mergeErr != nil {
		result.Notes = append(result.Notes, "First-run and trust settings were not copied: "+mergeErr.Error())
	}
	return result, nil
}

// firstRunWhileRunning copies the first-run and trust answers into an
// account whose running agents keep the rest of a sync from running. That
// merge only adds, and its write is checked byte for byte (mergeLaunchState).
func firstRunWhileRunning(home string, account Account, refusal error, result *SyncResult) error {
	state, added, err := mergeLaunchState(home, account)
	result.FirstRun, result.FirstRunAdded = state, added
	switch {
	case err != nil:
		return errors.New(refusal.Error() + " First-run and trust settings were not copied either: " + err.Error())
	case state == LaunchStateUpdated:
		return errors.New(strings.Replace(refusal.Error(), "; nothing was changed", "", 1) +
			" Only the first-run and trust settings were copied.")
	}
	return refusal
}

// syncPlan is everything the write phase uses, read and validated first.
type syncPlan struct {
	links, history []plannedLink
	claude         *claudeMCPPlan
	codex          *codexConfigPlan
	preview        MCPPreview
}

type plannedLink struct {
	source, destination string
	before              fileState
}

func preflight(home, main, root string, account Account) (syncPlan, error) {
	var plan syncPlan
	names := claudeLinks
	if account.Provider == "codex" {
		names = codexLinks
	}
	for _, name := range names {
		destination := filepath.Join(root, name)
		plan.links = append(plan.links, plannedLink{filepath.Join(main, name), destination, observe(destination)})
	}
	for _, name := range historyLinks[account.Provider] {
		destination := filepath.Join(root, name)
		plan.history = append(plan.history, plannedLink{filepath.Join(main, name), destination, observe(destination)})
	}
	var servers []MCPServerPreview
	if account.Provider == "claude" {
		claude, err := planClaudeMCP(filepath.Join(home, ".claude.json"), filepath.Join(root, ".claude.json"), account)
		if err != nil {
			return plan, err
		}
		if servers, err = claudeServerKeys(claude.mainServers); err != nil {
			return plan, err
		}
		plan.claude = &claude
	} else {
		codex, err := planCodexConfig(filepath.Join(main, "config.toml"), filepath.Join(root, "config.toml"), account)
		if err != nil {
			return plan, err
		}
		if servers, err = codexServerKeys(codex.main); err != nil {
			return plan, err
		}
		plan.codex = &codex
	}
	var err error
	plan.preview, err = previewOf(account, servers)
	return plan, err
}

// fileState is what the preflight saw at a path (without following a link).
type fileState struct {
	exists, failed bool
	info           os.FileInfo
	link           string
}

func observe(path string) fileState {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return fileState{}
	}
	if err != nil {
		return fileState{failed: true}
	}
	state := fileState{exists: true, info: info}
	if info.Mode()&os.ModeSymlink != 0 {
		if state.link, err = os.Readlink(path); err != nil {
			return fileState{failed: true}
		}
	}
	return state
}

// current reports whether path is still exactly what the preflight saw.
func (before fileState) current(path string) bool {
	now := observe(path)
	if before.failed || now.failed || now.exists != before.exists {
		return false
	}
	return !now.exists || os.SameFile(before.info, now.info) && before.info.Mode() == now.info.Mode() &&
		before.info.Size() == now.info.Size() && before.info.ModTime().Equal(now.info.ModTime()) && before.link == now.link
}

// sameContent reports whether a regular file still holds data, byte for byte.
func sameContent(path string, before fileState, data []byte) bool {
	if !before.current(path) {
		return false
	}
	if !before.exists {
		return true
	}
	now, err := readBounded(path, 16<<20)
	return err == nil && bytes.Equal(now, data)
}

const LinkChanged = "changed_during_sync"

// syncHistory links (opt-in) or unlinks the main history directories. An
// account's own non-empty history is never renamed or merged; the user is
// told to move it first. Only a link Relay would create is ever removed.
func syncHistory(items []plannedLink, account Account, result *SyncResult) {
	for _, item := range items {
		source, destination, name := item.source, item.destination, filepath.Base(item.destination)
		info, err := os.Lstat(destination)
		if !account.ShareHistory {
			if err == nil && info.Mode()&os.ModeSymlink != 0 {
				if target, err := os.Readlink(destination); err == nil && target == source &&
					item.before.current(destination) && os.Remove(destination) == nil {
					result.Links = append(result.Links, LinkResult{Name: name, State: LinkHistoryUnlinked})
				}
			}
			continue
		}
		link, checked := LinkResult{Name: name}, false
		if sourceInfo, sourceErr := os.Lstat(source); sourceErr == nil && err == nil && os.SameFile(sourceInfo, info) {
			link.State = LinkUnsupported
			result.Links = append(result.Links, link)
			continue
		}
		switch {
		case errors.Is(err, os.ErrNotExist):
		case err != nil:
			link.State = LinkUnsupported
		case info.Mode()&os.ModeSymlink != 0:
			if target, err := os.Readlink(destination); err == nil && target == source {
				link.State = LinkLinked
			} else {
				link.State = LinkForeign
			}
		case info.IsDir():
			if entries, err := os.ReadDir(destination); err != nil || len(entries) > 0 {
				link.State = LinkKeptOwnHistory
				result.Notes = append(result.Notes, name+"/ already holds this account's own conversations; "+
					"move or merge them into the main "+name+"/ before sharing history.")
			} else if !item.before.current(destination) {
				link.State = LinkChanged
			} else if os.Remove(destination) != nil {
				link.State = LinkKeptOwnHistory
			} else {
				checked = true
			}
		default:
			link.State = LinkUnsupported
		}
		if link.State == "" {
			if _, err := os.Lstat(source); err != nil {
				link.State = LinkMissingMain
			} else if !checked && !item.before.current(destination) {
				link.State = LinkChanged
			} else if os.Symlink(source, destination) != nil {
				link.State = LinkUnsupported
			} else {
				link.State = LinkLinked
			}
		}
		result.Links = append(result.Links, link)
	}
}

// distinctRoots refuses an account directory that resolves to the main
// directory, or into it, or that contains it.
func distinctRoots(main, root string) error {
	resolvedMain, resolvedAccount := resolvedRoot(main), resolvedRoot(root)
	if resolvedMain == resolvedAccount || within(resolvedMain, resolvedAccount) || within(resolvedAccount, resolvedMain) {
		return errors.New("the account directory resolves to the main directory or overlaps it; nothing was changed")
	}
	return nil
}

// linkShared changes destination only while it is still what the preflight
// saw (before).
func linkShared(source, destination string, before fileState, stamp string) LinkResult {
	result := LinkResult{Name: filepath.Base(destination)}
	sourceInfo, err := os.Lstat(source)
	if err != nil {
		result.State = LinkMissingMain
		return result
	}
	info, err := os.Lstat(destination)
	if err == nil && os.SameFile(sourceInfo, info) {
		// The same file through an alias: never replace it with itself.
		result.State = LinkUnsupported
		return result
	}
	switch {
	case errors.Is(err, os.ErrNotExist):
		if !before.current(destination) {
			result.State = LinkChanged
			return result
		}
	case err != nil:
		result.State = LinkUnsupported
		return result
	case info.Mode()&os.ModeSymlink != 0:
		if target, err := os.Readlink(destination); err == nil && target == source {
			result.State = LinkLinked
		} else {
			result.State = LinkForeign
		}
		return result
	case info.Mode().IsRegular() || info.IsDir():
		backup := destination + ".relay-backup-" + stamp
		if !before.current(destination) {
			result.State = LinkChanged
			return result
		}
		if _, err := os.Lstat(backup); err == nil || os.Rename(destination, backup) != nil {
			result.State = LinkUnsupported
			return result
		}
		result.Backup = filepath.Base(backup)
	default:
		result.State = LinkUnsupported
		return result
	}
	if err := os.Symlink(source, destination); err != nil {
		result.State = LinkUnsupported
		return result
	}
	result.State = LinkLinked
	if result.Backup != "" {
		result.State = LinkBackedUp
	}
	return result
}

// claudeMCPPlan copies only the top-level mcpServers value of the main
// global config into the account's .claude.json. That file also holds the
// account's own state, so it is never linked, and no other key is read into
// the account file. The previous mcpServers value (only that value) is kept in
// a timestamped backup before it changes.
type claudeMCPPlan struct {
	mainPath, accountPath string
	// mainServers is the main value as read (nil: none); servers is what
	// the account receives, without excluded servers.
	mainServers, servers json.RawMessage
	count                int
	document             map[string]json.RawMessage
	before               fileState
	data                 []byte
}

func planClaudeMCP(mainPath, accountPath string, account Account) (claudeMCPPlan, error) {
	plan := claudeMCPPlan{mainPath: mainPath, accountPath: accountPath, document: map[string]json.RawMessage{}}
	mainServers, err := readJSONKey(mainPath, "mcpServers")
	if err != nil {
		return plan, fmt.Errorf("main Claude configuration unavailable: %w", err)
	}
	if mainServers == nil {
		return plan, nil
	}
	var servers map[string]json.RawMessage
	if json.Unmarshal(mainServers, &servers) != nil || servers == nil {
		return plan, errors.New("main Claude mcpServers is not an object")
	}
	// Excluded servers, and their env values, are never copied.
	for name := range servers {
		if account.excludes(name) {
			delete(servers, name)
		}
	}
	if plan.servers, err = json.Marshal(servers); err != nil {
		return plan, err
	}
	plan.mainServers, plan.count = mainServers, len(servers)
	plan.before = observe(accountPath)
	switch {
	case plan.before.failed:
		return plan, errors.New("the account's .claude.json could not be read; it was not changed")
	case plan.before.exists:
		if !plan.before.info.Mode().IsRegular() || !ownedByUser(plan.before.info) {
			return plan, errors.New("the account's .claude.json is a link or not owned by this user; it was not changed")
		}
		plan.data, err = readBounded(accountPath, 16<<20)
		if err != nil || json.Unmarshal(plan.data, &plan.document) != nil || plan.document == nil {
			return plan, errors.New("the account's .claude.json is not a JSON object; it was not changed")
		}
	}
	return plan, nil
}

func (plan *claudeMCPPlan) write(stamp string, result *SyncResult) error {
	result.MCPCount = plan.count
	if plan.mainServers == nil {
		result.MCP = MergeNothing
		return nil
	}
	previous, ok := plan.document["mcpServers"]
	if ok && equalJSON(previous, plan.servers) {
		result.MCP = MergeUnchanged
		return nil
	}
	// The main file holds running state and changes often; only its
	// mcpServers value must still be the one planned.
	now, err := readJSONKey(plan.mainPath, "mcpServers")
	if err != nil || now == nil || !equalJSON(now, plan.mainServers) || !sameContent(plan.accountPath, plan.before, plan.data) {
		result.MCP = MergeRefused
		return errors.New("an MCP configuration changed during the sync; the account's .claude.json was not changed")
	}
	if ok {
		backup := plan.accountPath + ".mcpServers.relay-backup-" + stamp + ".json"
		if err := writeExclusive(backup, previous); err != nil {
			result.MCP = MergeRefused
			return errors.New("could not keep a backup of the account's mcpServers; nothing was changed")
		}
		result.MCPBackup = filepath.Base(backup)
	}
	document := map[string]json.RawMessage{}
	for key, value := range plan.document {
		document[key] = value
	}
	document["mcpServers"] = plan.servers
	data, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		result.MCP = MergeRefused
		return err
	}
	if !plan.before.exists {
		err = writeNew(plan.accountPath, data)
	} else if supported, swapErr := replaceVerified(plan.accountPath, plan.data, data); !supported {
		skipMCP(result, plan.accountPath)
		return nil
	} else {
		err = swapErr
	}
	if err != nil {
		result.MCP = MergeRefused
		return err
	}
	result.MCP = MergeUpdated
	return nil
}

// skipMCP reports an MCP merge left undone because the account's file
// system cannot replace a file atomically; the backup made for it is removed.
func skipMCP(result *SyncResult, path string) {
	if result.MCPBackup != "" {
		os.Remove(filepath.Join(filepath.Dir(path), result.MCPBackup))
	}
	result.MCP, result.MCPBackup = MergeSkipped, ""
	result.Notes = append(result.Notes, noAtomicExchangeNote(filepath.Base(path)))
}

// noAtomicExchangeNote says what a skipped merge leaves undone, and how the
// user does it by hand.
func noAtomicExchangeNote(name string) string {
	return name + " was not changed: " + errNoAtomicExchange.Error() + ". Its file system (NFS, for example) cannot " +
		"swap files in one step, and replacing it could overwrite a save by an agent using this account. The main " +
		"account's MCP servers were not copied into it, and neither are later changes to them. To use them in this " +
		"account, add them by hand while no agent uses it, with the provider's own command (claude mcp add, or codex mcp " +
		"add) run with this account's config directory, or by editing " + name + " in that directory."
}

// readJSONKey decodes one top-level key of a JSON object, discarding every
// other value as it streams; nil means the key is absent. The whole bounded
// document must be valid JSON (closing brace, then nothing but whitespace):
// a truncated or malformed file is refused, never read for its first keys.
func readJSONKey(path, key string) (json.RawMessage, error) {
	found, err := readJSONKeys(path, map[string]bool{key: true})
	return found[key], err
}

// readJSONKeys is readJSONKey for several keys; an absent key is not in the
// result.
func readJSONKeys(path string, keys map[string]bool) (map[string]json.RawMessage, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil || !info.Mode().IsRegular() || !ownedByUser(info) {
		return nil, errors.New("not a regular file owned by this user")
	}
	data, err := readBounded(path, 16<<20)
	if err != nil {
		return nil, err
	}
	if !json.Valid(data) {
		return nil, errors.New("invalid JSON")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	if token, err := decoder.Token(); err != nil || token != json.Delim('{') {
		return nil, errors.New("not a JSON object")
	}
	found := map[string]json.RawMessage{}
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return nil, errors.New("invalid JSON")
		}
		name, _ := token.(string)
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return nil, errors.New("invalid JSON")
		}
		if keys[name] {
			found[name] = append(json.RawMessage(nil), value...)
		}
	}
	if token, err := decoder.Token(); err != nil || token != json.Delim('}') {
		return nil, errors.New("invalid JSON")
	}
	if _, err := decoder.Token(); err != io.EOF {
		return nil, errors.New("invalid JSON")
	}
	return found, nil
}

// Codex keeps MCP servers and settings in config.toml. It is linked only when
// neither the main file nor the account's own file sets an account-specific
// key anywhere (inline tables and dotted keys included) and no server is
// excluded. Otherwise the account keeps its own file, with every setting
// outside mcp_servers (its account keys included) unchanged, and only the
// main mcp_servers tables are copied into it, rewritten from the parsed file
// without any CODEX_HOME key, since that names the main account's directory.
// A file Relay cannot parse is refused before anything changes.
var codexAccountSettings = []string{"forced_login_method", "forced_chatgpt_workspace_id", "preferred_auth_method",
	"cli_auth_credentials_store", "chatgpt_base_url", "CODEX_HOME"}

const codexMergeMarker = "# [mcp_servers.*] below are synced by Relay from the main Codex config.toml."

type codexConfigPlan struct {
	mainPath, accountPath string
	// main is the parsed main file (nil: there is none) and mainText its bytes.
	main     *tomlDocument
	mainText []byte
	mainSeen fileState
	// The account's file as read: current is its text; linked means it is
	// an earlier sync's link to the main file.
	current string
	linked  bool
	seen    fileState
	// link: the whole file is linked; otherwise next is the merged text.
	link  bool
	next  string
	count int
	notes []string
}

func planCodexConfig(mainPath, accountPath string, account Account) (codexConfigPlan, error) {
	plan := codexConfigPlan{mainPath: mainPath, accountPath: accountPath}
	main, text, seen, err := readCodexMain(mainPath)
	if err != nil || main == nil {
		return plan, err
	}
	servers, err := codexServers(main)
	if err != nil {
		return plan, err
	}
	plan.main, plan.mainText, plan.mainSeen = main, text, seen
	plan.seen = observe(accountPath)
	switch {
	case plan.seen.failed:
		return plan, errors.New("the account's config.toml could not be read; it was not changed")
	case !plan.seen.exists:
	case plan.seen.info.Mode()&os.ModeSymlink != 0:
		// An earlier sync linked it.
		if plan.seen.link != mainPath {
			return plan, errors.New("the account's config.toml links elsewhere; it was not changed")
		}
		plan.linked = true
	case !plan.seen.info.Mode().IsRegular() || !ownedByUser(plan.seen.info):
		return plan, errors.New("the account's config.toml is not a regular file owned by this user")
	default:
		data, err := readBounded(accountPath, 4<<20)
		if err != nil {
			return plan, err
		}
		plan.current = string(data)
	}
	own, err := parseTOML(plan.current)
	if err != nil {
		return plan, errors.New("the account's own " + err.Error() + "; it was not changed")
	}
	reasons, ownReasons := codexAccountKeys(main), codexAccountKeys(own)
	// A linked file would share every server; excluding one needs a copy.
	if len(reasons) == 0 && len(ownReasons) == 0 && len(account.MCPExclude) == 0 {
		plan.link = true
		return plan, nil
	}
	if len(reasons) > 0 {
		plan.notes = append(plan.notes, "config.toml sets "+strings.Join(reasons, ", ")+
			"; only [mcp_servers.*] tables were copied, without CODEX_HOME values.")
	}
	if len(ownReasons) > 0 {
		plan.notes = append(plan.notes, "This account's config.toml sets "+strings.Join(ownReasons, ", ")+
			"; it keeps its own settings and only [mcp_servers.*] tables were copied.")
	}
	if len(account.MCPExclude) > 0 {
		plan.notes = append(plan.notes, "Some MCP servers are excluded, so only the other [mcp_servers.*] tables were copied.")
	}
	var merged strings.Builder
	for _, line := range strings.SplitAfter(tomlOutside(plan.current, own, "mcp_servers"), "\n") {
		if strings.TrimSpace(line) != codexMergeMarker {
			merged.WriteString(line)
		}
	}
	var copied strings.Builder
	if servers != nil {
		for _, name := range servers.keys {
			if account.excludes(name) {
				continue
			}
			tomlEmitTable(&copied, []string{"mcp_servers", name}, tomlWithout(servers.values[name], "CODEX_HOME").(*tomlTable))
			plan.count++
		}
	}
	if copied.Len() > 0 {
		body := strings.TrimRight(merged.String(), "\n")
		if body != "" {
			body += "\n\n"
		}
		merged.Reset()
		merged.WriteString(body + codexMergeMarker + "\n" + copied.String())
	}
	plan.next = merged.String()
	// The result must parse, no copied server may name a CODEX_HOME, and
	// every account-specific key the account set must still be there.
	written, err := parseTOML(plan.next)
	if err != nil || codexHomeIn(written.root.values["mcp_servers"]) {
		return plan, errors.New("the merged config.toml could not be verified; nothing was changed")
	}
	kept := map[string]bool{}
	for _, path := range codexAccountKeyPaths(written) {
		kept[path] = true
	}
	for _, path := range codexAccountKeyPaths(own) {
		if !kept[path] {
			return plan, errors.New("the account's config.toml sets an account-specific key inside its MCP servers; " +
				"Relay will not replace them automatically, and nothing was changed")
		}
	}
	return plan, nil
}

func (plan *codexConfigPlan) write(stamp string, result *SyncResult) error {
	if plan.main == nil {
		result.MCP = MergeNothing
		return nil
	}
	if !sameContent(plan.mainPath, plan.mainSeen, plan.mainText) {
		result.MCP = MergeRefused
		return errors.New("the main Codex config.toml changed during the sync; the account's config.toml was not changed")
	}
	if plan.link {
		link := linkShared(plan.mainPath, plan.accountPath, plan.seen, stamp)
		result.Links = append(result.Links, link)
		result.MCP = CodexConfigLink
		if link.State != LinkLinked && link.State != LinkBackedUp {
			result.MCP = MergeRefused
			return errors.New("config.toml could not be linked: " + link.State)
		}
		return nil
	}
	result.Notes = append(result.Notes, plan.notes...)
	result.MCPCount = plan.count
	if plan.next == plan.current && !plan.linked {
		result.MCP = MergeUnchanged
		return nil
	}
	if !plan.seen.current(plan.accountPath) || (!plan.linked && !sameContent(plan.accountPath, plan.seen, []byte(plan.current))) {
		result.MCP = MergeRefused
		return errors.New("the account's config.toml changed during the sync; it was not changed")
	}
	if plan.current != "" {
		backup := plan.accountPath + ".relay-backup-" + stamp
		if err := writeExclusive(backup, []byte(plan.current)); err != nil {
			result.MCP = MergeRefused
			return errors.New("could not keep a backup of the account's config.toml; nothing was changed")
		}
		result.MCPBackup = filepath.Base(backup)
	}
	var err error
	switch {
	case plan.linked:
		// The link is exchanged with the account's own file in one step and
		// the displaced entry must be that same link; a provider save that
		// took its place is swapped back and kept. Never a remove: a save
		// renamed over the link after the check above would be deleted.
		var supported bool
		if supported, err = replaceChecked(plan.accountPath, []byte(plan.next),
			func(displaced string) bool { return isLinkTo(displaced, plan.mainPath) }); !supported {
			skipMCP(result, plan.accountPath)
			return nil
		}
	case plan.seen.exists:
		var supported bool
		if supported, err = replaceVerified(plan.accountPath, []byte(plan.current), []byte(plan.next)); !supported {
			skipMCP(result, plan.accountPath)
			return nil
		}
	default:
		err = writeNew(plan.accountPath, []byte(plan.next))
	}
	if err != nil {
		result.MCP = MergeRefused
		return err
	}
	result.MCP = CodexConfigMerge
	return nil
}

// readCodexMain parses the main config.toml; nil when there is none.
func readCodexMain(path string) (*tomlDocument, []byte, fileState, error) {
	seen := observe(path)
	switch {
	case !seen.exists && !seen.failed:
		return nil, nil, seen, nil
	case seen.failed || !seen.info.Mode().IsRegular() || !ownedByUser(seen.info):
		return nil, nil, seen, errors.New("the main Codex config.toml is not a regular file owned by this user")
	}
	text, err := readBounded(path, 4<<20)
	if err != nil {
		return nil, nil, seen, err
	}
	document, err := parseTOML(string(text))
	if err != nil {
		return nil, nil, seen, err
	}
	return document, text, seen, nil
}

// syncCodexConfig plans and writes one config.toml (both phases).
func syncCodexConfig(mainPath, accountPath, stamp string, account Account, result *SyncResult) error {
	plan, err := planCodexConfig(mainPath, accountPath, account)
	if err != nil {
		result.MCP = MergeRefused
		return err
	}
	return plan.write(stamp, result)
}

// codexServers is the parsed mcp_servers table, each server a table.
func codexServers(document *tomlDocument) (*tomlTable, error) {
	value, ok := document.root.values["mcp_servers"]
	if !ok {
		return nil, nil
	}
	servers, isTable := value.(*tomlTable)
	if !isTable {
		return nil, errors.New("config.toml mcp_servers is not a table; Relay will not merge it automatically")
	}
	for _, name := range servers.keys {
		if _, isTable := servers.values[name].(*tomlTable); !isTable {
			return nil, errors.New("config.toml has an MCP server that is not a table; Relay will not merge it automatically")
		}
	}
	return servers, nil
}

// codexAccountKeys lists account-specific settings set anywhere in the file.
func codexAccountKeys(document *tomlDocument) []string {
	found := map[string]bool{}
	tomlWalk(document.root, nil, func(path []string) { found[path[len(path)-1]] = true })
	reasons := []string{}
	for _, name := range codexAccountSettings {
		if found[name] {
			reasons = append(reasons, name)
		}
	}
	return reasons
}

// codexAccountKeyPaths are the full key paths of the account-specific
// settings set anywhere in the file.
func codexAccountKeyPaths(document *tomlDocument) []string {
	names := map[string]bool{}
	for _, name := range codexAccountSettings {
		names[name] = true
	}
	var paths []string
	tomlWalk(document.root, nil, func(path []string) {
		if names[path[len(path)-1]] {
			paths = append(paths, strings.Join(path, "\x00"))
		}
	})
	return paths
}

func codexHomeIn(value any) bool {
	table, ok := value.(*tomlTable)
	if !ok {
		return false
	}
	found := false
	tomlWalk(table, nil, func(path []string) { found = found || path[len(path)-1] == "CODEX_HOME" })
	return found
}

// tomlOutside is text without the statements (and the comments after them)
// whose key path starts with prefix.
func tomlOutside(text string, document *tomlDocument, prefix string) string {
	statements := document.statements
	if len(statements) == 0 {
		return text
	}
	var out strings.Builder
	out.WriteString(text[:statements[0].lineStart])
	for index, statement := range statements {
		end := len(text)
		if index+1 < len(statements) {
			end = statements[index+1].lineStart
		}
		if statement.path[0] != prefix {
			out.WriteString(text[statement.lineStart:end])
		}
	}
	return out.String()
}

func equalJSON(a, b json.RawMessage) bool {
	var x, y any
	if json.Unmarshal(a, &x) != nil || json.Unmarshal(b, &y) != nil {
		return false
	}
	left, _ := json.Marshal(x)
	right, _ := json.Marshal(y)
	return bytes.Equal(left, right)
}

func writeExclusive(path string, data []byte) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		os.Remove(path)
		return err
	}
	return file.Close()
}

func readBounded(path string, limit int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil || int64(len(data)) > limit {
		return nil, errors.New("file exceeds its limit")
	}
	return data, nil
}

func ownedByUser(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(stat.Uid) == os.Getuid()
}
