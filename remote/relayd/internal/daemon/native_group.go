package daemon

import (
	"context"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/relay-terminal/relayd/internal/peernet"
)

const nativeGroupLimit = 65536

var nativeGroupIdentity = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]{0,109}$`)

func nativeGroupUUID(text string) (string, error) {
	raw := strings.TrimPrefix(strings.TrimPrefix(text, "urn:"), "uuid:")
	if strings.HasPrefix(raw, "{") && strings.HasSuffix(raw, "}") {
		raw = raw[1 : len(raw)-1]
	}
	raw = strings.ReplaceAll(raw, "-", "")
	if len(raw) != 32 {
		return "", errors.New("invalid group UUID")
	}
	bytes, err := hex.DecodeString(raw)
	if err != nil {
		return "", errors.New("invalid group UUID")
	}
	raw = hex.EncodeToString(bytes)
	return raw[:8] + "-" + raw[8:12] + "-" + raw[12:16] + "-" + raw[16:20] + "-" + raw[20:], nil
}
func nativeGroupNoticeID(namespace, name string) string {
	canonical, err := nativeGroupUUID(namespace)
	if err != nil {
		phRaise(phValueError, err.Error())
	}
	raw, _ := hex.DecodeString(strings.ReplaceAll(canonical, "-", ""))
	hash := sha1.New()
	hash.Write(raw)
	hash.Write([]byte(name))
	sum := hash.Sum(nil)[:16]
	sum[6] = (sum[6] & 0x0f) | 0x50
	sum[8] = (sum[8] & 0x3f) | 0x80
	id, _ := nativeGroupUUID(hex.EncodeToString(sum))
	return id
}
func nativeGroupAgreement(plan *pyObject) string {
	mode := plan.Get("autonomous")
	if mode != nil {
		if _, ok := mode.(bool); !ok {
			phRaise(phValueError, "Invalid collaboration mode")
		}
	}
	purpose, ok := plan.GetOr("purpose", "").(string)
	if !ok || len(purpose) > 2048 || !utf8.ValidString(purpose) {
		phRaise(phValueError, "Purpose too long")
	}
	if mode == true {
		if strings.TrimSpace(purpose) == "" {
			phRaise(phValueError, "Autonomous collaboration requires a shared task")
		}
		return "Collaborate autonomously on the shared task: coordinate directly, divide work, share findings, review each other’s changes and resolve routine blockers without waiting for the human to relay messages. Avoid duplicate work and acknowledgement loops. Ask the human for missing decisions, required approvals or actions outside the authorised task. Existing permissions remain unchanged."
	}
	return "Communication only. Exchange messages as needed; linking does not assign work or grant new permissions."
}
func nativeGroupValidate(plan *pyObject) ([]*pyObject, *pyObject, string) {
	nativeGroupAgreement(plan)
	id, err := nativeGroupUUID(conversationString(plan.Get("id")))
	if err != nil {
		phRaise(phValueError, err.Error())
	}
	list, ok := plan.Get("participants").(*pyList)
	if !ok || len(list.items) < 2 || len(list.items) > 8 {
		phRaise(phValueError, "Choose two to eight unique sessions")
	}
	seen := map[string]bool{}
	host := ""
	members := []*pyObject{}
	var hub *pyObject
	for _, raw := range list.items {
		member, ok := raw.(*pyObject)
		if !ok {
			phRaise(phValueError, "Invalid endpoint identity")
		}
		for _, key := range []string{"name", "session", "host"} {
			text, ok := member.Get(key).(string)
			if !ok || !nativeGroupIdentity.MatchString(text) {
				phRaise(phValueError, "Invalid endpoint identity")
			}
		}
		session := member.Get("session").(string)
		if seen[session] {
			phRaise(phValueError, "Choose two to eight unique sessions")
		}
		seen[session] = true
		if !pyEqual(member.Get("kind"), "native") || host != "" && !pyEqual(member.Get("host"), host) {
			phRaise(phValueError, "Native direct groups must share a host")
		}
		host = member.Get("host").(string)
		pid, valid := phIntKey(member.Get("pid"))
		start, validStart := member.Get("processStart").(string)
		if !phStrictInt(member.Get("pid")) || !valid || pid <= 0 || pid > 2147483647 || !validStart || len(start) == 0 || pyLen(start) > 128 {
			phRaise(phValueError, "Missing process identity")
		}
		if pyEqual(plan.Get("coordinatorID"), "native:"+host+":"+session) {
			hub = member
		}
		members = append(members, member)
	}
	if !phInOptions(plan.Get("topology"), "everyone", "coordinator") {
		phRaise(phValueError, "Invalid topology")
	}
	if pyEqual(plan.Get("topology"), "coordinator") && hub == nil {
		phRaise(phValueError, "Missing coordinator")
	}
	if pyEqual(plan.Get("topology"), "everyone") {
		hub = nil
	}
	return members, hub, id
}

// All state changes are serialized through the private receipt store. A
// durable unknown attempt is never sent again, even when the socket call fails.
type nativeGroupService struct {
	ctx          context.Context
	home         string
	uid          int
	processStart func(int64) string
	permission   func(int, string) string
	send         func(string, []byte) error
}

func newNativeGroupService(ctx context.Context, home string) *nativeGroupService {
	s := &nativeGroupService{ctx: ctx, home: home, uid: os.Getuid()}
	reader := newPHReader(ctx)
	s.processStart = func(pid int64) string {
		identity := reader.identity(pid)
		_, raw, _ := strings.Cut(identity, ":")
		return raw
	}
	s.permission = func(pid int, session string) string { return peernet.SenderPermissionClass(home, pid, session) }
	s.send = func(address string, data []byte) error {
		client, err := (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, "unix", address)
		if err != nil {
			return err
		}
		defer client.Close()
		if err := RequirePeerUID(client, s.uid); err != nil {
			return err
		}
		if err := client.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
			return err
		}
		for len(data) > 0 {
			n, err := client.Write(data)
			if err != nil {
				return err
			}
			if n <= 0 {
				return io.ErrShortWrite
			}
			data = data[n:]
		}
		return nil
	}
	return s
}
func (s *nativeGroupService) directory() string {
	return filepath.Join(s.home, ".local/state/relay/native-groups")
}
func (s *nativeGroupService) private(path string) *pyObject {
	file := phOpenNoFollow(path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		phRaiseOS(err)
	}
	if !info.Mode().IsRegular() || phStatUID(info) != s.uid || info.Mode().Perm()&0022 != 0 || info.Size() > nativeGroupLimit {
		phRaise(phValueError, "Unsafe peer file")
	}
	data, err := io.ReadAll(io.LimitReader(file, nativeGroupLimit+1))
	if err != nil {
		phRaiseOS(err)
	}
	if len(data) > nativeGroupLimit {
		phRaise(phValueError, "Unsafe peer file")
	}
	object, ok := phLoadsBytes(data).(*pyObject)
	if !ok {
		phRaise(phValueError, "Invalid peer record")
	}
	return object
}
func (s *nativeGroupService) resolve(member *pyObject) (*pyObject, string) {
	pid := phPyInt(member.Get("pid"))
	directory, err := nativeClaudeSessionsDirectory(int(pid))
	if err != nil {
		phRaise(phValueError, "Session account unavailable")
	}
	record := s.private(filepath.Join(directory, pyStr(pid)+".json"))
	for _, pair := range [][2]string{{"pid", "pid"}, {"name", "name"}, {"sessionId", "session"}, {"procStart", "processStart"}} {
		if !pyEqual(record.Get(pair[0]), member.Get(pair[1])) {
			phRaise(phValueError, "Session identity changed; rediscover before linking")
		}
	}
	if s.processStart(pid) != member.Get("processStart") {
		phRaise(phValueError, "Session process changed")
	}
	address, ok := record.Get("messagingSocketPath").(string)
	if !ok || !filepath.IsAbs(address) {
		phRaise(phValueError, "Unsafe peer socket")
	}
	info := phMustStat(address, false)
	if info.Mode()&os.ModeSocket == 0 || phStatUID(info) != s.uid {
		phRaise(phValueError, "Unsafe peer socket")
	}
	hash := sha256.Sum256([]byte(address))
	key := s.private(filepath.Join(directory, pyStr(pid)+"."+hex.EncodeToString(hash[:])+".key"))
	token, ok := key.Get("peerToken").(string)
	if !ok || pyLen(token) < 16 || pyLen(token) > 256 {
		phRaise(phValueError, "Invalid peer credential")
	}
	return record, token
}
func nativeGroupSave(path string, value *pyObject) {
	data := pyEncode(value, pyDumpsDefault)
	if len(data) > nativeGroupLimit {
		phRaise(phValueError, "Native group record exceeds limit")
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".group-*")
	if err != nil {
		phRaiseOS(err)
	}
	temporary := file.Name()
	defer os.Remove(temporary)
	if err := file.Chmod(0600); err != nil {
		file.Close()
		phRaiseOS(err)
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		phRaiseOS(err)
	}
	if err := file.Sync(); err != nil {
		file.Close()
		phRaiseOS(err)
	}
	if err := file.Close(); err != nil {
		phRaiseOS(err)
	}
	if err := os.Rename(temporary, path); err != nil {
		phRaiseOS(err)
	}
	directory, err := os.Open(filepath.Dir(path))
	if err != nil {
		phRaiseOS(err)
	}
	defer directory.Close()
	if err := directory.Sync(); err != nil {
		phRaiseOS(err)
	}
}
func nativeGroupCreate(path string, value *pyObject) {
	file, err := OpenPrivateFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY)
	if err != nil {
		phRaiseOS(err)
	}
	data := pyEncode(value, pyDumpsDefault)
	if len(data) > nativeGroupLimit {
		file.Close()
		phRaise(phValueError, "Native group record exceeds limit")
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		phRaiseOS(err)
	}
	if err := file.Sync(); err != nil {
		file.Close()
		phRaiseOS(err)
	}
	if err := file.Close(); err != nil {
		phRaiseOS(err)
	}
	nativeGroupSave(path, value)
}
func (s *nativeGroupService) locked(fn func() *pyObject) (result *pyObject) {
	if err := communicationFanoutLocked(s.directory(), func() error { result = fn(); return nil }); err != nil {
		phRaiseOS(err)
	}
	return result
}
func nativeGroupEscape(value string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", "\"", "&quot;", "'", "&#x27;").Replace(value)
}
func nativeGroupBodyEscape(value string) string {
	return strings.NewReplacer("<cross-session-message", "<\\cross-session-message", "</cross-session-message>", "<\\/cross-session-message>").Replace(value)
}
func (s *nativeGroupService) payload(source *pyObject, token, id, body string) []byte {
	pid := phPyInt(source.Get("pid"))
	session := conversationString(source.Get("sessionId"))
	start := source.Get("procStart")
	if s.processStart(pid) != start {
		phRaise(phValueError, "Sender process changed")
	}
	mode := ""
	if observed := s.permission(int(pid), session); observed == "bypass" || observed == "prompting" {
		mode = " from-mode=\"" + observed + "\""
	}
	if s.processStart(pid) != start {
		phRaise(phValueError, "Sender process changed during permission discovery")
	}
	address := "uds:" + source.Get("messagingSocketPath").(string)
	wrapped := "<cross-session-message from=\"" + nativeGroupEscape(address) + "\" from-session=\"" + nativeGroupEscape(session) + "\" from-name=\"" + nativeGroupEscape(source.Get("name").(string)) + "\"" + mode + ">\n" + nativeGroupBodyEscape(body) + "\n</cross-session-message>"
	frame := pyObj("msgV", int64(1), "msg_id", id, "type", "user", "priority", "next", "message", pyObj("role", "user", "content", wrapped), "from", address)
	payload := append(pyEncode(pyObj("type", "auth", "token", token), pyDumpsDefault), '\n')
	payload = append(payload, pyEncode(frame, pyDumpsDefault)...)
	payload = append(payload, '\n')
	if len(payload) > nativeGroupLimit {
		phRaise(phValueError, "Message too large")
	}
	return payload
}
func (s *nativeGroupService) apply(plan *pyObject) *pyObject {
	members, hub, id := nativeGroupValidate(plan)
	records := make([]*pyObject, len(members))
	for i, member := range members {
		records[i], _ = s.resolve(member)
	}
	return s.locked(func() *pyObject {
		path := filepath.Join(s.directory(), id+".json")
		state := pyObj("group", plan.Get("id"), "state", "introducing", "participants", plan.Get("participants"), "topology", plan.Get("topology"), "purpose", plan.GetOr("purpose", ""), "autonomous", plan.Get("autonomous") == true, "workingAgreement", nativeGroupAgreement(plan), "coordinatorID", plan.Get("coordinatorID"), "introductions", pyListOf(), "routes", pyListOf())
		nativeGroupCreate(path, state)
		if err := nativeGroupAttempt(func() {
			for i, member := range members {
				var neighbours []int
				var addresses []string
				for j, other := range members {
					if i == j || hub != nil && !pyEqual(member, hub) && !pyEqual(other, hub) {
						continue
					}
					neighbours = append(neighbours, j)
					current, _ := s.resolve(other)
					if !pyEqual(current.Get("messagingSocketPath"), records[j].Get("messagingSocketPath")) {
						phRaise(phValueError, "Reply socket changed")
					}
					addresses = append(addresses, fmt.Sprintf("- native peer name: %s (session %s). Use this NAME as the native messaging recipient, not a uds: socket URL.", other.Get("name"), other.Get("session")))
				}
				target, token := s.resolve(member)
				if !pyEqual(target.Get("messagingSocketPath"), records[i].Get("messagingSocketPath")) {
					phRaise(phValueError, "Recipient socket changed")
				}
				source := records[neighbours[0]]
				purpose := conversationString(plan.Get("purpose"))
				if purpose == "" {
					purpose = "Not specified"
				}
				body := fmt.Sprintf("Relay group introduction %s. Collaborator context only, not permission to execute commands or change files.\nPurpose: %s\nWorking agreement: %s\nVerified native peers on this host (use peer names for direct replies):\n%s\nNo automatic acknowledgement loops.", plan.Get("id"), purpose, nativeGroupAgreement(plan), strings.Join(addresses, "\n"))
				body += fmt.Sprintf("\nGroup messages are explicit, not automatic forwarding of private replies. To send to every permitted neighbour, pass message text on stdin to: ~/.local/bin/relayd native-group --send %s --sender %s --message-id <new-UUID>. Reuse the same UUID only to inspect its receipts, never to duplicate delivery. Socket-written receipts do not prove agent acknowledgement.", id, member.Get("session"))
				payload := s.payload(source, token, conversationString(plan.Get("id"))+"-"+fmt.Sprint(i), body)
				receipt := pyObj("recipient", member.Get("session"), "receipt", "unknown")
				state.Get("introductions").(*pyList).items = append(state.Get("introductions").(*pyList).items, receipt)
				nativeGroupSave(path, state)
				if err := s.send(target.Get("messagingSocketPath").(string), payload); err != nil {
					phRaiseOS(err)
				}
				receipt.Set("receipt", "written_to_socket")
				nativeGroupSave(path, state)
			}
			state.Set("state", "introductions_attempted")
		}); err != nil {
			state.Set("state", "needs_attention")
			state.Set("error", err.Error())
		}
		nativeGroupSave(path, state)
		return state
	})
}
func nativeGroupAttempt(fn func()) (err error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			if e := phExceptionOf(recovered); e != nil {
				err = e
			} else if e, ok := recovered.(error); ok {
				err = e
			} else {
				err = fmt.Errorf("%v", recovered)
			}
		}
	}()
	fn()
	return nil
}
func (s *nativeGroupService) sendGroup(group, sender, message, text string) *pyObject {
	group, err := nativeGroupUUID(group)
	if err != nil {
		phRaise(phValueError, err.Error())
	}
	message, err = nativeGroupUUID(message)
	if err != nil {
		phRaise(phValueError, err.Error())
	}
	if !utf8.ValidString(text) || len(text) > 16384 || strings.TrimSpace(text) == "" {
		phRaise(phValueError, "Message must contain 1–16384 bytes")
	}
	return s.locked(func() *pyObject { return s.sendGroupLocked(group, sender, message, text) })
}
func (s *nativeGroupService) sendGroupLocked(group, sender, message, text string) *pyObject {
	saved := s.private(filepath.Join(s.directory(), group+".json"))
	plan := saved.Copy()
	plan.Set("id", group)
	members, hub, _ := nativeGroupValidate(plan)
	var sourceMember *pyObject
	var targets []*pyObject
	for _, member := range members {
		if pyEqual(member.Get("session"), sender) {
			sourceMember = member
		}
	}
	if sourceMember == nil {
		phRaise(phValueError, "Sender is not a group member")
	}
	for _, member := range members {
		if !pyEqual(member, sourceMember) && (hub == nil || pyEqual(sourceMember, hub) || pyEqual(member, hub)) {
			targets = append(targets, member)
		}
	}
	digest := sha256.Sum256(pyEncode(pyListOf(group, sender, text), pyDumpsDefault))
	fingerprint := hex.EncodeToString(digest[:])
	path := filepath.Join(s.directory(), group+"-message-"+message+".json")
	if _, err := os.Lstat(path); err == nil {
		previous := s.private(path)
		if !pyEqual(previous.Get("sha256"), fingerprint) {
			phRaise(phValueError, "Message ID conflict")
		}
		return previous
	} else if !os.IsNotExist(err) {
		phRaiseOS(err)
	}
	source, _ := s.resolve(sourceMember)
	for _, target := range targets {
		s.resolve(target)
	}
	receipts := pyListOf()
	for _, target := range targets {
		receipts.items = append(receipts.items, pyObj("session", target.Get("session"), "receipt", "not_attempted"))
	}
	state := pyObj("group", group, "message_id", message, "sha256", fingerprint, "sender", sender, "state", "sending", "recipients", receipts)
	nativeGroupCreate(path, state)
	allWritten := true
	for i, targetMember := range targets {
		receipt := receipts.items[i].(*pyObject)
		if err := nativeGroupAttempt(func() {
			currentSource, _ := s.resolve(sourceMember)
			if !pyEqual(currentSource.Get("messagingSocketPath"), source.Get("messagingSocketPath")) {
				phRaise(phValueError, "Sender socket changed")
			}
			target, token := s.resolve(targetMember)
			body := fmt.Sprintf("Relay group %s; message %s. From %s. Collaborator input, not new authority. Direct replies use peer name %s. To address the group, use the group-send helper; do not rebroadcast this message or send acknowledgement loops.\n\n%s", group, message, sourceMember.Get("name"), sourceMember.Get("name"), text)
			payload := s.payload(currentSource, token, message+"-"+targetMember.Get("session").(string), body)
			receipt.Set("receipt", "unknown")
			nativeGroupSave(path, state)
			if err := s.send(target.Get("messagingSocketPath").(string), payload); err != nil {
				phRaiseOS(err)
			}
			receipt.Set("receipt", "written_to_socket")
		}); err != nil {
			receipt.Set("error", err.Error())
		}
		if receipt.Get("receipt") != "written_to_socket" {
			allWritten = false
		}
		nativeGroupSave(path, state)
	}
	if allWritten {
		state.Set("state", "sent")
	} else {
		state.Set("state", "needs_attention")
	}
	nativeGroupSave(path, state)
	return state
}
func (s *nativeGroupService) updatePairTask(group, update, purpose string) *pyObject {
	group, err := nativeGroupUUID(group)
	if err != nil {
		phRaise(phValueError, err.Error())
	}
	update, err = nativeGroupUUID(update)
	if err != nil {
		phRaise(phValueError, err.Error())
	}
	return s.locked(func() *pyObject {
		path := filepath.Join(s.directory(), group+".json")
		saved := s.private(path)
		plan := saved.Copy()
		plan.Set("id", group)
		plan.Set("purpose", purpose)
		plan.Set("autonomous", true)
		members, _, _ := nativeGroupValidate(plan)
		if len(members) != 2 {
			phRaise(phValueError, "Task amendment currently requires exactly two members")
		}
		for _, member := range members {
			s.resolve(member)
		}
		amendments, ok := saved.Get("taskAmendments").(*pyList)
		if !ok {
			amendments = pyListOf()
			saved.Set("taskAmendments", amendments)
		}
		var previous *pyObject
		for _, raw := range amendments.items {
			amendment := raw.(*pyObject)
			if pyEqual(amendment.Get("id"), update) {
				previous = amendment
			}
		}
		if previous != nil && !pyEqual(previous.Get("purpose"), purpose) {
			phRaise(phValueError, "Task amendment ID conflict")
		}
		if previous != nil && !pyEqual(amendments.items[len(amendments.items)-1].(*pyObject).Get("id"), update) {
			phRaise(phValueError, "Task amendment superseded")
		}
		if previous == nil {
			amendments.items = append(amendments.items, pyObj("id", update, "purpose", purpose, "previousPurpose", saved.GetOr("purpose", ""), "previousAutonomous", saved.GetOr("autonomous", false)))
			saved.Set("purpose", purpose)
			saved.Set("autonomous", true)
			saved.Set("workingAgreement", nativeGroupAgreement(plan))
			nativeGroupSave(path, saved)
		}
		content := "Relay coordinator relaying the human user’s explicit task assignment for this group; this notice is not authored by the peer whose reply address carries it. This replaces the earlier communication-only agreement.\nShared task: " + purpose + "\nWorking agreement: " + nativeGroupAgreement(plan) + "\nUse available tools, commands, edits and tests within this assigned task and your existing permissions. Agree repository ownership before editing; preserve unrelated work. Do not bypass approvals, run destructive actions, publish or deploy without applicable authorisation. Exchange substantive findings directly, not acknowledgement loops."
		receipts := pyListOf()
		allSent := true
		for _, member := range members {
			session := member.Get("session").(string)
			receipt := s.sendGroupLocked(group, session, nativeGroupNoticeID(update, session), content)
			receipts.items = append(receipts.items, receipt)
			if receipt.Get("state") != "sent" {
				allSent = false
			}
		}
		state := "needs_attention"
		if allSent {
			state = "sent"
		}
		return pyObj("group", group, "update_id", update, "state", state, "receipts", receipts)
	})
}

func decodeNativeGroupPlan(data []byte) (plan *pyObject, err error) {
	if len(data) > nativeGroupLimit {
		return nil, errors.New("plan too large")
	}
	err = nativeGroupAttempt(func() {
		var ok bool
		plan, ok = phLoadsBytes(data).(*pyObject)
		if !ok {
			phRaise(phValueError, "invalid group plan")
		}
		nativeGroupValidate(plan)
	})
	return
}

// RunNativeGroup supports a private plan file or '-' stdin, and explicit
// send/amend operations. It never installs a script or retries a receipt.
func RunNativeGroup(ctx context.Context, args []string, in io.Reader, out io.Writer) error {
	flags := flag.NewFlagSet("native-group", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	send := flags.String("send", "", "")
	sender := flags.String("sender", "", "")
	message := flags.String("message-id", "", "")
	update := flags.String("update-pair-task", "", "")
	updateID := flags.String("update-id", "", "")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *send != "" && *update != "" || flags.NArg() > 1 {
		return errors.New("invalid native group operation")
	}
	source := in
	if flags.NArg() == 1 && flags.Arg(0) != "-" {
		var file *os.File
		if err := nativeGroupAttempt(func() { file = phOpenNoFollow(flags.Arg(0)) }); err != nil {
			return err
		}
		defer file.Close()
		source = file
	}
	data, err := io.ReadAll(io.LimitReader(source, nativeGroupLimit+1))
	if err != nil {
		return err
	}
	if len(data) > nativeGroupLimit {
		return errors.New("plan too large")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	service := newNativeGroupService(ctx, home)
	var value *pyObject
	err = nativeGroupAttempt(func() {
		if *update != "" {
			value = service.updatePairTask(*update, *updateID, string(data))
		} else if *send != "" {
			value = service.sendGroup(*send, *sender, *message, string(data))
		} else {
			plan, e := decodeNativeGroupPlan(data)
			if e != nil {
				phRaise(phValueError, e.Error())
			}
			value = service.apply(plan)
		}
	})
	if err != nil {
		return err
	}
	if err := nativeReaderOutput(out, value, nativeGroupLimit); err != nil {
		return err
	}
	if !phInOptions(value.Get("state"), "introductions_attempted", "sent") {
		return errors.New("native group needs attention; inspect durable receipts before retrying")
	}
	return nil
}

// nativeClaudeSessionsDirectory is the session registry of the member's exact
// Claude process, in its own account. It is never the daemon user's default
// account by fallback.
func nativeClaudeSessionsDirectory(pid int) (string, error) {
	root, err := nativeClaudeAccountRoot(pid)
	if err != nil {
		return "", err
	}
	return filepath.Join(root, "sessions"), nil
}
