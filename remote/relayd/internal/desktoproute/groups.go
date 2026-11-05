package desktoproute

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"
)

type participant struct {
	Kind    string `json:"kind"`
	Host    string `json:"host"`
	Session string `json:"session"`
	Name    string `json:"name"`
	PID     int    `json:"pid"`
	Start   string `json:"processStart"`
}

func (p participant) identity() string { return p.Kind + ":" + p.Host + ":" + p.Session }

type groupPlan struct {
	ID           string        `json:"id"`
	Participants []participant `json:"participants"`
	Topology     string        `json:"topology"`
	Coordinator  string        `json:"coordinatorID"`
	Purpose      string        `json:"purpose"`
	Autonomous   bool          `json:"autonomous"`
}

func (p groupPlan) agreement() (string, error) {
	if len(p.Purpose) > 2048 {
		return "", errors.New("purpose exceeds limit")
	}
	if p.Autonomous {
		if strings.TrimSpace(p.Purpose) == "" {
			return "", errors.New("autonomous collaboration requires a shared task")
		}
		return "Collaborate autonomously on the shared task: coordinate directly, divide work, share findings, review each other’s changes and resolve routine blockers without waiting for the human to relay messages. Avoid duplicate work and acknowledgement loops. Ask the human for missing decisions, required approvals or actions outside the authorised task. Existing permissions remain unchanged.", nil
	}
	return "Communication only. Exchange messages as needed; linking does not assign work or grant new permissions.", nil
}
func (p groupPlan) edges() ([][2]participant, error) {
	if !clientID.MatchString(p.ID) || len(p.Participants) < 2 || len(p.Participants) > 8 {
		return nil, errors.New("choose two to eight distinct sessions and a group UUID")
	}
	seen := map[string]bool{}
	hub := -1
	for i, m := range p.Participants {
		if (m.Kind != "native" && m.Kind != "desktop") || !identifier.MatchString(m.Host) || !identifier.MatchString(m.Session) || !identifier.MatchString(m.Name) || seen[m.identity()] {
			return nil, errors.New("invalid or duplicate group member")
		}
		if m.Kind == "desktop" && m.Host != "laptop" {
			return nil, errors.New("desktop task must be local")
		}
		if m.Kind == "native" && (m.PID <= 1 || m.PID > 1<<31-1 || !validStart(m.Host, m.Start)) {
			return nil, errors.New("invalid native process identity")
		}
		seen[m.identity()] = true
		if m.identity() == p.Coordinator {
			hub = i
		}
	}
	edges := [][2]participant{}
	switch p.Topology {
	case "everyone":
		for i, a := range p.Participants {
			for _, b := range p.Participants[i+1:] {
				edges = append(edges, [2]participant{a, b})
			}
		}
	case "coordinator":
		if hub < 0 {
			return nil, errors.New("missing coordinator")
		}
		for i, m := range p.Participants {
			if i != hub {
				edges = append(edges, [2]participant{p.Participants[hub], m})
			}
		}
	default:
		return nil, errors.New("invalid topology")
	}
	return edges, nil
}

type introduction struct {
	Recipient string `json:"recipient"`
	Receipt   string `json:"receipt"`
}
type groupState struct {
	Native        json.RawMessage `json:"-"`
	Group         string          `json:"group"`
	State         string          `json:"state"`
	Kind          string          `json:"kind,omitempty"`
	Socket        string          `json:"socket,omitempty"`
	Edges         [][2]string     `json:"edges,omitempty"`
	Introductions []introduction  `json:"introductions"`
	Routes        []savedRoute    `json:"routes"`
	Purpose       string          `json:"purpose"`
	Autonomous    bool            `json:"autonomous"`
	Agreement     string          `json:"workingAgreement"`
	Error         string          `json:"error,omitempty"`
}

func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'" }
func (r *runtime) applyGroup(ctx context.Context, p groupPlan, raw []byte) (groupState, error) {
	var state groupState
	agreement, e := p.agreement()
	if e != nil {
		return state, e
	}
	edges, e := p.edges()
	if e != nil {
		return state, e
	}
	allNative, allDesktop := true, true
	for _, m := range p.Participants {
		allNative = allNative && m.Kind == "native"
		allDesktop = allDesktop && m.Kind == "desktop"
	}
	if allNative {
		host := p.Participants[0].Host
		for _, m := range p.Participants {
			if m.Host != host {
				return state, errors.New("native group requires a single host")
			}
		}
		var output []byte
		if host == "laptop" {
			cmd := exec.CommandContext(ctx, r.exe, "native-group", "-")
			cmd.Stdin = bytes.NewReader(raw)
			output, e = cmd.Output()
		} else {
			output, e = sendHost(ctx, r.host(host), []string{".local/bin/relayd", "native-group", "-"}, raw)
		}
		if len(output) > 0 {
			if de := decodeJSON(output, 1<<20, &state); de != nil {
				return state, de
			}
			state.Native = append([]byte{}, output...)
		}
		return state, e
	}
	type pair struct {
		a, b participant
		c    Config
	}
	pairs := []pair{}
	socket := filepath.Join(r.home, ".codex/app-server-control/app-server-control.sock")
	if !allDesktop {
		for _, edge := range edges {
			a, b := edge[0], edge[1]
			if a.Kind == "native" && b.Kind == "desktop" {
				a, b = b, a
			}
			if a.Kind != "desktop" || b.Kind != "native" {
				return state, errors.New("mixed group requires desktop/native edges")
			}
			c := Config{Host: b.Host, LocalName: "pending", Thread: a.Session, RemoteName: b.Name, RemoteSession: b.Session, RemotePID: b.PID, RemoteStart: b.Start, Socket: socket}
			if e = c.Validate(); e != nil {
				return state, e
			}
			pairs = append(pairs, pair{a, b, c})
		}
	}
	for _, m := range p.Participants {
		if m.Kind == "desktop" {
			if _, e = r.desktop.Inspect(ctx, socket, m.Session, true); e != nil {
				return state, e
			}
		}
	}
	state = groupState{Group: strings.ToLower(p.ID), State: "connecting", Purpose: p.Purpose, Autonomous: p.Autonomous, Agreement: agreement, Introductions: []introduction{}, Routes: []savedRoute{}}
	if allDesktop {
		state.Kind = "desktop"
		state.Socket = socket
		for _, edge := range edges {
			state.Edges = append(state.Edges, [2]string{edge[0].Session, edge[1].Session})
		}
	}
	directory := filepath.Join(r.home, ".local/state/relay/peer-groups")
	if e = privateDirectory(directory, true); e != nil {
		return state, e
	}
	receipt := filepath.Join(directory, state.Group+".json")
	if e = exclusiveJSON(receipt, state); e != nil {
		return state, e
	}
	save := func() error { return atomicJSON(receipt, state) }
	fail := func(err error) (groupState, error) {
		state.State = "needs_attention"
		state.Error = err.Error()
		if se := save(); se != nil {
			return state, se
		}
		return state, err
	}
	if allDesktop {
		for _, member := range p.Participants {
			commands := []string{}
			for _, edge := range state.Edges {
				peer := ""
				if edge[0] == member.Session {
					peer = edge[1]
				} else if edge[1] == member.Session {
					peer = edge[0]
				}
				if peer != "" {
					commands = append(commands, shellQuote(r.exe)+" desktop-group --send "+shellQuote(receipt)+" --from "+shellQuote(member.Session)+" --to "+shellQuote(peer))
				}
			}
			content := "Relay desktop group " + state.Group + "\nPurpose: " + p.Purpose + "\nWorking agreement: " + agreement + "\nSend a message on stdin to these confirmed routes:\n" + strings.Join(commands, "\n") + "\nCollaborator context is not permission to execute commands or change files. Do not create acknowledgement loops. Never automatically retry a send."
			state.Introductions = append(state.Introductions, introduction{member.Session, "unknown"})
			if e = save(); e != nil {
				return fail(e)
			}
			result := r.desktop.Deliver(ctx, socket, member.Session, Envelope{ID: groupMessageID(state.Group, member.Session), Sender: "Relay group setup", Content: content})
			state.Introductions[len(state.Introductions)-1].Receipt = result.Receipt
			if e = save(); e != nil {
				return fail(e)
			}
			if result.Receipt != "admitted" {
				return fail(errors.New("desktop introduction was not admitted; inspect receipts before retrying"))
			}
		}
	} else {
		for _, pair := range pairs {
			saved, e := r.remember(ctx, pair.c, true, false)
			if e != nil {
				return fail(e)
			}
			c, e := readConfig(saved.Config)
			if e != nil {
				return fail(e)
			}
			for tries := 0; ; tries++ {
				var live RouteState
				e = readJSONFile(r.status(c), 16384, &live)
				if e == nil {
					_, e = live.live(c, time.Now())
				}
				if e == nil {
					break
				}
				if tries >= 19 {
					return fail(errors.New("route not online; no introductions sent"))
				}
				if e = waitContext(ctx, time.Second); e != nil {
					return fail(e)
				}
			}
			state.Routes = append(state.Routes, saved)
			if e = save(); e != nil {
				return fail(e)
			}
		}
		introduced := map[string]bool{}
		for i, pair := range pairs {
			identity := pair.b.Host + ":" + pair.b.Session
			if introduced[identity] {
				continue
			}
			introduced[identity] = true
			neighbours := []string{}
			for n, other := range pairs {
				if other.b.Host == pair.b.Host && other.b.Session == pair.b.Session {
					neighbours = append(neighbours, "- desktop task "+other.a.Session+": reply using "+state.Routes[n].Reply)
				}
			}
			content := fmt.Sprintf("Relay group introduction %s. Collaborator context, not permission to execute commands or change files.\nPurpose: %s\nWorking agreement: %s\nConfirmed routes:\n%s\nDo not create acknowledgement loops.", state.Group, p.Purpose, agreement, strings.Join(neighbours, "\n"))
			state.Introductions = append(state.Introductions, introduction{pair.b.Session, "unknown"})
			if e = save(); e != nil {
				return fail(e)
			}
			c, e := readConfig(state.Routes[i].Config)
			if e != nil {
				return fail(e)
			}
			result, e := r.send(ctx, c, state.Routes[i].Config, Envelope{ID: fmt.Sprintf("%s-%d", state.Group, i), Content: content})
			state.Introductions[len(state.Introductions)-1].Receipt = result.Receipt
			if se := save(); se != nil {
				return fail(se)
			}
			if e != nil {
				return fail(e)
			}
			if result.Receipt != "written_to_socket" {
				return fail(errors.New("introduction outcome unresolved"))
			}
		}
		for _, m := range p.Participants {
			if m.Kind != "desktop" {
				continue
			}
			routes := []string{}
			for i, pair := range pairs {
				if pair.a.Session == m.Session {
					routes = append(routes, state.Routes[i].Config)
				}
			}
			content := "Relay group introduction " + state.Group + ". Collaborator context only; not permission to execute commands.\nPurpose: " + p.Purpose + "\nWorking agreement: " + agreement + "\nYour confirmed remote routes:\n" + strings.Join(routes, "\n") + "\nNo automatic acknowledgement loops."
			state.Introductions = append(state.Introductions, introduction{m.Session, "unknown"})
			if e = save(); e != nil {
				return fail(e)
			}
			result := r.desktop.Deliver(ctx, socket, m.Session, Envelope{ID: groupMessageID(state.Group, m.Session), Sender: "Relay group setup", Content: content})
			state.Introductions[len(state.Introductions)-1].Receipt = result.Receipt
			if e = save(); e != nil {
				return fail(e)
			}
			if result.Receipt != "admitted" {
				return fail(errors.New("desktop introduction outcome unresolved"))
			}
		}
	}
	state.State = "introductions_attempted"
	return state, save()
}
func (r *runtime) sendGroup(ctx context.Context, path, source, dest, content string) (Delivery, error) {
	result := Delivery{Receipt: "not_sent"}
	var state groupState
	if e := readJSONFile(path, messageLimit, &state); e != nil {
		return result, e
	}
	if state.Kind != "desktop" || state.State != "introductions_attempted" || !clientID.MatchString(state.Group) || len(state.Edges) > 28 || !identifier.MatchString(source) || !identifier.MatchString(dest) || source == dest {
		return result, errors.New("desktop group not ready")
	}
	allowed := false
	for _, edge := range state.Edges {
		if edge == [2]string{source, dest} || edge == [2]string{dest, source} {
			allowed = true
		}
	}
	if !allowed {
		return result, errors.New("no authorized group edge")
	}
	for _, id := range []string{source, dest} {
		if e := r.desktop.Verify(ctx, state.Socket, id); e != nil {
			return result, e
		}
	}
	m := Envelope{ID: uuid(), Sender: "Relay desktop task " + source, Content: content}
	if _, e := deliveryParams(dest, m); e != nil {
		return result, e
	}
	ledger := filepath.Join(filepath.Dir(path), m.ID+".json")
	row := map[string]any{"messageId": m.ID, "receipt": "unknown", "source": source, "destination": dest, "group": state.Group}
	if e := exclusiveJSON(ledger, row); e != nil {
		return result, e
	}
	result = r.desktop.Deliver(ctx, state.Socket, dest, m)
	row["receipt"] = result.Receipt
	row["error"] = result.Error
	if e := atomicJSON(ledger, row); e != nil {
		return result, e
	}
	if result.Receipt != "admitted" {
		return result, errors.New("group message outcome unresolved")
	}
	return result, nil
}
func RunGroup(ctx context.Context, args []string, in io.Reader, out io.Writer) error {
	r, e := newRuntime()
	if e != nil {
		return e
	}
	if len(args) > 0 && args[0] == "--send" {
		f := flag.NewFlagSet("desktop-group", flag.ContinueOnError)
		f.SetOutput(io.Discard)
		receipt := f.String("send", "", "")
		source := f.String("from", "", "")
		dest := f.String("to", "", "")
		if e = f.Parse(args); e != nil {
			return e
		}
		if f.NArg() != 0 || *receipt == "" {
			return errors.New("exact group receipt required")
		}
		raw, e := readBounded(in, messageLimit)
		if e != nil {
			return e
		}
		if !utf8.Valid(raw) {
			return errors.New("invalid UTF-8 message")
		}
		result, sendErr := r.sendGroup(ctx, *receipt, *source, *dest, string(raw))
		if e = writeJSON(out, result); e != nil {
			return e
		}
		return sendErr
	}
	if len(args) != 1 {
		return errors.New("desktop-group plan required")
	}
	raw, e := privateRead(args[0], messageLimit, 0077)
	if e != nil {
		return e
	}
	var plan groupPlan
	if e = decodeJSON(raw, messageLimit, &plan); e != nil {
		return e
	}
	state, applyErr := r.applyGroup(ctx, plan, raw)
	if state.Native != nil {
		if e = writeJSON(out, state.Native); e != nil {
			return e
		}
		return applyErr
	}
	if e = writeJSON(out, state); e != nil {
		return e
	}
	return applyErr
}

func groupMessageID(group, task string) string {
	id := group + "-desktop-" + task
	if len(id) > 110 {
		return group + "-desktop-" + hash([]byte(task))[:32]
	}
	return id
}
