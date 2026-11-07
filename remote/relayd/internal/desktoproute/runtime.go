package desktoproute

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type runtime struct {
	home, exe string
	desktop   desktop
	host      func(string) hostAPI
	service   func(context.Context, ...string) error
	wait      func(context.Context, time.Duration) error
}

func newRuntime() (*runtime, error) {
	home, e := os.UserHomeDir()
	if e != nil {
		return nil, e
	}
	exe, e := os.Executable()
	if e != nil {
		return nil, e
	}
	r := &runtime{home: home, exe: exe, desktop: &nativeDesktop{home: home, inspect: inspectProcess}, service: launchctl}
	r.host = func(host string) hostAPI {
		return &hostTransport{host: host, exe: exe, client: &http.Client{Timeout: 25 * time.Second}}
	}
	return r, nil
}
func (r *runtime) root() string { return filepath.Join(r.home, ".local/share/relay/desktop-routing") }
func (r *runtime) status(c Config) string {
	return filepath.Join(r.home, ".local/state/relay/peer-network", c.LocalName+".json")
}
func (r *runtime) remoteArgs(c Config, mode string, box *Mailbox) []string {
	exe := ".local/bin/relayd"
	if c.Host == "laptop" {
		exe = r.exe
	}
	args := []string{exe, "desktop-remote", mode, strconv.Itoa(c.RemotePID), c.RemoteSession, c.RemoteStart, c.LocalName}
	if box != nil {
		args = append(args, strconv.Itoa(box.PID), box.Start)
	} else if mode == "listen" && c.RemoteAccount != "" {
		args = append(args, c.RemoteAccount)
	}
	return args
}
func listenerSpec(args []string) map[string]any {
	if (len(args) != 7 && len(args) != 8) || filepath.Base(args[0]) != "relayd" || args[1] != "desktop-remote" || args[2] != "listen" || !identifier.MatchString(args[4]) || !identifier.MatchString(args[6]) || !(numericStart.MatchString(args[5]) || validStart("laptop", args[5])) {
		return nil
	}
	pid, err := strconv.Atoi(args[3])
	if err != nil || pid <= 1 || pid > 1<<31-1 {
		return nil
	}
	spec := map[string]any{"executable": args[0], "owner_pid": pid, "owner_session": args[4], "owner_start": args[5], "route": args[6]}
	if len(args) == 8 {
		spec["owner_account"] = args[7]
	}
	return spec
}
func (r *runtime) send(ctx context.Context, c Config, path string, m Envelope) (Delivery, error) {
	result := Delivery{MessageID: m.ID, Receipt: "not_sent"}
	if e := c.Validate(); e != nil {
		return result, e
	}
	if e := r.desktop.Verify(ctx, c.Socket, c.Thread); e != nil {
		return result, e
	}
	var state RouteState
	if e := readJSONFile(r.status(c), 16384, &state); e != nil {
		return result, e
	}
	box, e := state.live(c, time.Now())
	if e != nil {
		return result, e
	}
	m.PermissionClass = ""
	m.PermissionClass, e = r.desktop.Permission(ctx, c.Socket, c.Thread)
	if e != nil {
		return result, e
	}
	if m.ReadReceipt == nil || *m.ReadReceipt {
		m.Content += "\n\n[Relay read receipt: after reading, send a separate message to " + c.LocalName + " containing exactly \"Relay-Read-Receipt: " + m.ID + "\". This confirms reading, not just delivery.]"
	}
	raw, e := json.Marshal(m)
	if e != nil || len(raw) > messageLimit {
		return result, errors.New("message with receipt request exceeds limit")
	}
	if _, e = updateReceipt(path, m.ID, "pending", true, time.Now()); e != nil {
		return result, e
	}
	result.Receipt = "unknown"
	sendCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	output, e := sendHost(sendCtx, r.host(c.Host), r.remoteArgs(c, "send", &box), raw)
	var response struct {
		Receipt string `json:"receipt"`
		ID      string `json:"id"`
	}
	if decodeJSON(output, 1<<20, &response) == nil && response.ID == m.ID && (response.Receipt == "written_to_socket" || response.Receipt == "not_sent") {
		result.Receipt = response.Receipt
	}
	_, persist := updateReceipt(path, m.ID, result.Receipt, false, time.Now())
	if persist != nil {
		return result, persist
	}
	return result, e
}

var errRecovered = errors.New("same session recovered")

func adoptConfig(c Config, path string, event routeEvent) (Config, error) {
	if event.Session != c.RemoteSession || event.PID <= 1 || !identifier.MatchString(event.Name) || len(event.Start) > 64 || !validStart(c.Host, event.Start) {
		return c, errIdentity
	}
	current, e := readConfig(path)
	if e != nil {
		return c, e
	}
	if current != c {
		return c, errIdentity
	}
	updated := c
	updated.RemoteName = event.Name
	updated.RemotePID = event.PID
	updated.RemoteStart = event.Start
	if e = updated.Validate(); e != nil {
		return c, e
	}
	if e = atomicJSON(path, updated); e != nil {
		return c, e
	}
	return updated, nil
}

type routeEvent struct {
	Type    string `json:"type"`
	State   string `json:"state"`
	Message string `json:"message"`
	ID      string `json:"id"`
	Sender  string `json:"sender"`
	Content string `json:"content"`
	Session string `json:"session"`
	PID     int    `json:"pid"`
	Start   string `json:"start"`
	Account string `json:"account,omitempty"`
	Name    string `json:"name"`
	Drain   int    `json:"drain"`
}

func parseEvent(raw []byte) (routeEvent, error) {
	var e routeEvent
	err := decodeJSON(raw, 131072, &e)
	if err != nil {
		return e, err
	}
	switch e.Type {
	case "ready":
		if e.PID <= 1 || e.Start == "" || !identifier.MatchString(e.Name) {
			return e, errors.New("invalid ready event")
		}
	case "message":
		if !messageID.MatchString(e.ID) || !identifier.MatchString(e.Sender) {
			return e, errors.New("invalid message event")
		}
	case "heartbeat", "identity_missing", "identity_changed", "identity_replacement", "transport_status", "rejected":
	default:
		return e, errors.New("unknown route event")
	}
	return e, nil
}

// readyAccount takes the owner account a remote reports on its ready frame. The
// frame comes from the listener of the exact owner incarnation the route names,
// so it is matched to that identity. known reports that this remote sends the
// account at all, which makes it safe to send the recorded account back; that
// acceptance is recorded durably on the route.
func readyAccount(c Config, path string, event routeEvent) (Config, bool, error) {
	if event.Account == "" {
		return c, false, nil
	}
	updated, e := backfillOwnerAccount(c, path, routeEvent{Type: "ready", PID: c.RemotePID, Start: c.RemoteStart, Account: event.Account})
	if e != nil {
		return updated, true, e
	}
	updated, e = recordAccountAcceptance(updated, path, true)
	return updated, true, e
}

// recordAccountAcceptance durably sets whether the remote takes the recorded
// account as a listen argument. Like backfillOwnerAccount it writes only over
// the exact configuration this listener holds.
func recordAccountAcceptance(c Config, path string, accepted bool) (Config, error) {
	if c.RemoteAccountAccepted == accepted {
		return c, nil
	}
	current, e := readConfig(path)
	if e != nil {
		return c, e
	}
	if current != c {
		return c, nil
	}
	updated := c
	updated.RemoteAccountAccepted = accepted
	if e = updated.Validate(); e != nil {
		return c, e
	}
	if e = atomicJSON(path, updated); e != nil {
		return c, e
	}
	return updated, nil
}

// listenConfig is the route as a listen argument. The recorded account is sent
// only to a remote known to accept it: an older remote refuses the extra argument.
func listenConfig(c Config, known bool) Config {
	if !known {
		c.RemoteAccount = ""
	}
	return c
}

func reconnectDelay(attempt int) time.Duration {
	return time.Duration(min(1<<min(max(attempt, 0), 5), 30)) * time.Second
}

func (r *runtime) listen(ctx context.Context, c Config, path string) error {
	if e := r.desktop.Verify(ctx, c.Socket, c.Thread); e != nil {
		return e
	}
	if e := privateDirectory(filepath.Dir(r.status(c)), true); e != nil {
		return e
	}
	lock, e := fileLock(path+".lock", true)
	if e != nil {
		return e
	}
	defer lock.Close()
	state := RouteState{Schema: 1, PID: os.Getpid(), Host: c.Host, LocalName: c.LocalName, LocalSession: c.Thread, RemoteName: c.RemoteName, RemoteSession: c.RemoteSession, RemotePID: c.RemotePID, RemoteStart: c.RemoteStart, RTT: -1, State: "connecting"}
	publish := func() error {
		state.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
		return atomicJSON(r.status(c), state)
	}
	defer func() {
		if state.State != "needs_attention" {
			state.State = "stopped"
		}
		publish()
	}()
	seen := map[string]bool{}
	attempt := 0
	for ctx.Err() == nil {
		state.State = "connecting"
		state.Attempt = attempt
		if e = publish(); e != nil {
			return e
		}
		// The route records whether the remote's ready frame has carried its owner
		// account, so a remote new enough to take the recorded account keeps
		// receiving it across reconnects, owner exits and restarts.
		args := r.remoteArgs(listenConfig(c, c.RemoteAccountAccepted), "listen", nil)
		sentAccount := len(args) == 8
		checkpoint, e := openCheckpoint(filepath.Join(r.home, ".local/state/relay/host-adapters"), c.Host, args)
		if e != nil {
			return e
		}
		transport := r.host(c.Host)
		handle := func(raw []byte) error {
			event, e := parseEvent(raw)
			if e != nil {
				return e
			}
			switch event.Type {
			case "transport_status":
				if event.State != "transport_unavailable" && event.State != "permission_required" {
					return errors.New("invalid transport status")
				}
				state.State = event.State
				state.Error = event.Message
				state.Mailbox = nil
			case "identity_changed":
				return errIdentity
			case "identity_missing":
				return errOwnerAbsent
			case "identity_replacement":
				updated, e := adoptConfig(c, path, event)
				if e != nil {
					return e
				}
				c = updated
				state.RemoteName = c.RemoteName
				state.RemotePID = c.RemotePID
				state.RemoteStart = c.RemoteStart
				state.Mailbox = nil
				state.Heartbeat = 0
				return errRecovered
			case "ready", "heartbeat":
				if e = r.desktop.Verify(ctx, c.Socket, c.Thread); e != nil {
					return e
				}
				if event.Type == "ready" {
					if event.Name != c.LocalName || !validStart(c.Host, event.Start) {
						return errors.New("reply mailbox identity changed")
					}
					updated, _, e := readyAccount(c, path, event)
					if e != nil {
						return e
					}
					c = updated
					state.Mailbox = &Mailbox{PID: event.PID, Start: event.Start, Name: event.Name, Drain: event.Drain}
					state.State = "online"
					state.Error = ""
					attempt = 0
				}
				state.Heartbeat = float64(time.Now().UnixNano()) / 1e9
			case "message":
				if seen[event.ID] {
					return nil
				}
				if len(seen) >= 4096 {
					return errors.New("message budget reached; explicit restart required")
				}
				incoming := strings.TrimSuffix(path, filepath.Ext(path)) + "-incoming" + filepath.Ext(path)
				if _, e = updateReceipt(incoming, event.ID, "pending", true, time.Now()); e != nil {
					if errors.Is(e, errReplay) {
						return nil
					}
					return e
				}
				seen[event.ID] = true
				if acknowledged := readAcknowledgment(event.Content); acknowledged != "" {
					ok, e := updateReceipt(path, acknowledged, "read_acknowledged", false, time.Now())
					if e != nil {
						return e
					}
					if ok {
						state.LastReadMessageID = acknowledged
						state.LastReadReceipt = "read_acknowledged"
					}
				}
				result := r.desktop.Deliver(ctx, c.Socket, c.Thread, Envelope{ID: event.ID, Sender: c.Host + "--" + event.Sender, Content: event.Content})
				receipt := "unknown"
				if result.Receipt == "admitted" {
					receipt = "admitted"
				}
				if _, e = updateReceipt(incoming, event.ID, receipt, false, time.Now()); e != nil {
					return e
				}
				state.LastMessageID = event.ID
				state.LastReceipt = result.Receipt
				if receipt != "admitted" {
					state.Error = "Desktop admission failed; no replay. " + result.Error
				}
			}
			return publish()
		}
		e = listenHost(ctx, transport, checkpoint, listenerSpec(args), handle)
		// Only an explicit refusal of the extra argument, from a remote relayd
		// older than it, withdraws acceptance; an attempt without a ready frame
		// (the owner exited) does not. A later ready frame with an account
		// records acceptance again.
		if sentAccount && errors.Is(e, errAccountArgumentRefused) {
			updated, persist := recordAccountAcceptance(c, path, false)
			if persist != nil {
				return persist
			}
			c = updated
		}
		// Cancellation is explicit route shutdown; communication errors detach and
		// preserve the durable host listener for an exact-ID status reconnection.
		if ctx.Err() != nil || errors.Is(e, errIdentity) || errors.Is(e, errRecovered) {
			cancelCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			_, _ = transport.request(cancelCtx, checkpoint.state.Job, "cancel", nil)
			cancel()
		}
		checkpoint.lock.Close()
		if errors.Is(e, errIdentity) {
			state.State = "needs_attention"
			state.Error = errIdentity.Error()
			state.RebindRequired = true
			state.Mailbox = nil
			return publish()
		}
		if errors.Is(e, errRecovered) {
			attempt = 0
			continue
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		state.State = "offline"
		state.Mailbox = nil
		if e != nil {
			state.Error = e.Error()
		}
		if e = publish(); e != nil {
			return e
		}
		if len(seen) >= 4096 {
			return errors.New("message budget reached")
		}
		wait := r.wait
		if wait == nil {
			wait = waitContext
		}
		if e = wait(ctx, reconnectDelay(attempt)); e != nil {
			return e
		}
		attempt++
	}
	return ctx.Err()
}
func Run(ctx context.Context, args []string, in io.Reader, out io.Writer) error {
	r, e := newRuntime()
	if e != nil {
		return e
	}
	return r.run(ctx, args, in, out)
}
func (r *runtime) run(ctx context.Context, args []string, in io.Reader, out io.Writer) error {
	if len(args) == 0 {
		return errors.New("desktop-route mode required")
	}
	mode := args[0]
	f := flag.NewFlagSet("desktop-route", flag.ContinueOnError)
	f.SetOutput(io.Discard)
	config := f.String("config", "", "")
	socket := f.String("socket", "", "")
	thread := f.String("thread", "", "")
	connect := f.Bool("connect", false, "")
	rebind := f.Bool("rebind", false, "")
	details := f.Bool("details", false, "")
	sync := f.Bool("sync", false, "")
	appPID := f.Int("work-app-pid", 0, "")
	appStart := f.String("work-app-start", "", "")
	if e := f.Parse(args[1:]); e != nil {
		return e
	}
	if f.NArg() != 0 {
		return errors.New("unexpected desktop-route arguments")
	}
	switch mode {
	case "tasks":
		if !*details {
			ids, e := r.desktop.Loaded(ctx, *socket)
			if e != nil {
				return e
			}
			return writeJSON(out, ids)
		}
		rows, e := r.desktop.Tasks(ctx, *socket)
		if e != nil {
			return e
		}
		if *details {
			return writeJSON(out, rows)
		}
		ids := []string{}
		for _, row := range rows {
			ids = append(ids, row.ID)
		}
		return writeJSON(out, ids)
	case "task-check", "task-prepare":
		row, e := r.desktop.Inspect(ctx, *socket, *thread, mode == "task-prepare")
		if e != nil {
			return e
		}
		return writeJSON(out, row)
	case "work-register":
		d, ok := r.desktop.(*nativeDesktop)
		if !ok {
			return errors.New("native desktop required")
		}
		expected, e := d.workRef(d.legacySocket(), *thread)
		if e != nil {
			return e
		}
		ref := workReference{1, *thread, "local", d.workSocket(), workApp, *appPID, *appStart, "00000000-0000-0000-0000-000000000000"}
		client, e := d.openWork(ctx, ref)
		if e != nil {
			return e
		}
		ref.Owner, e = client.owner(false)
		client.close()
		if e != nil {
			return e
		}
		if expected != nil && *expected != ref {
			return errors.New("existing binding changed; explicit refresh required")
		}
		if e = d.commitWork(ref, expected); e != nil {
			return e
		}
		return writeJSON(out, ref)
	case "connections":
		if *sync {
			if e := r.syncConnections(); e != nil {
				return e
			}
		}
		rows, e := connections(r.root())
		if e != nil {
			return e
		}
		return writeJSON(out, rows)
	}
	if mode == "send" {
		return r.runSend(ctx, *config, in, out)
	}
	if *config == "" {
		return errors.New("exact configuration required")
	}
	c, e := readConfig(*config)
	if e != nil {
		return e
	}
	switch mode {
	case "listen":
		return r.listen(ctx, c, *config)
	case "remember":
		if *rebind && !*connect {
			return errors.New("rebind requires explicit connect")
		}
		if _, e = r.desktop.Inspect(ctx, c.Socket, c.Thread, true); e != nil {
			return e
		}
		saved, e := r.remember(ctx, c, *connect, *rebind)
		if e != nil {
			return e
		}
		return writeJSON(out, saved)
	case "handoff":
		updated, e := r.handoff(ctx, *config, c, *thread)
		if e != nil {
			return e
		}
		return writeJSON(out, map[string]string{"replyName": updated.LocalName, "task": updated.Thread})
	}
	return fmt.Errorf("unknown desktop route mode %q", mode)
}

// runSend always emits one receipt after argument parsing, even when preflight
// fails before reading the message. Private diagnostics remain the error return.
func (r *runtime) runSend(ctx context.Context, config string, in io.Reader, out io.Writer) error {
	result := Delivery{Receipt: "not_sent"}
	sendErr := func() error {
		if config == "" {
			return errors.New("exact configuration required")
		}
		c, e := readConfig(config)
		if e != nil {
			return e
		}
		raw, e := readBounded(in, messageLimit)
		if e != nil {
			return e
		}
		m, e := parseEnvelope(raw, false)
		if e != nil {
			return e
		}
		result, e = r.send(ctx, c, config, m)
		return e
	}()
	if e := writeJSON(out, result); e != nil {
		return e
	}
	return sendErr
}

// backfillOwnerAccount records the live owner's account on a route that has
// none. Only the owner incarnation the route names is accepted, and the config
// must still be the one this listener loaded.
func backfillOwnerAccount(c Config, path string, event routeEvent) (Config, error) {
	if c.RemoteAccount != "" || event.PID != c.RemotePID || event.Start != c.RemoteStart {
		return c, nil
	}
	current, e := readConfig(path)
	if e != nil {
		return c, e
	}
	if current != c {
		return c, nil
	}
	updated := c
	updated.RemoteAccount = event.Account
	if e = updated.Validate(); e != nil {
		return c, e
	}
	if e = atomicJSON(path, updated); e != nil {
		return c, e
	}
	return updated, nil
}
