# Supported Codex messaging adapter

Status: experimental helpers; persistent direct desktop route installed for one
explicit session pair. Not a generally released workspace feature.

## Persistent desktop route (20 September 2026)

The signed shared backend and sidebar browser passed simultaneous live use.
The pan-barley Codex also returned `RELAY_REMOTE_REPLY_OK` through a temporary
native mailbox -> SSH -> App Server tool-output path, without Chitta Bridge.

`relay-desktop-route.py` replaces the temporary mailbox with a stable route name.
`relay-desktop-remote.py` runs locally for a native peer on This Mac and over SSH
for a peer on another host. It registers a private authenticated mailbox,
refreshes it, checks the exact recipient PID/session/process start on each loop,
and removes its registration on orderly disconnect. The route carries messages
in both directions between the desktop task and native peer. The local supervisor
validates the private socket, admits messages only to an already-loaded desktop
task, and publishes the existing `PeerNetworkStatus` schema under
`~/.local/state/relay/peer-network`. No payload or credentials enter status files.

Relay keeps a private metadata-only connection registry in
`~/.local/share/relay/desktop-routing/connections.json`. Each entry names a
stable reply mailbox, its remote host/session, the current desktop task, and an
ordered history of desktop task IDs. Compaction within one task leaves the
route unchanged. An explicit **Continue in another task** action requires the
new task to be open, stops the old route, changes its delivery target, and
restarts it with the same remote reply address. It does not copy transcripts,
replay messages, resume closed tasks, or infer that a new task is a successor.
Connections view imports existing verified saved routes into the registry.

The local user LaunchAgent `dev.vaklab.relay-desktop-panbarley` starts the route
at login, with five bounded reconnect attempts and no launchd restart loop.
The reply name is `relay-desktop-01a08116-panbarley`. The deployed config binds
only desktop task `01a08116-471e-7930-975e-537c12159703` to the exact observed
pan-barley Codex session. The route can recover a changed process incarnation
only when the private remote registry has exactly one live, verified process for
that same session ID. An absent session is retried; ambiguous matches and a
different session still require review. Messages are never replayed.

Live acceptance passed: `RELAY_PERSISTENT_ROUTE_OK` arrived in the desktop
conversation. After terminating only the owned SSH child, the supervisor
reconnected on attempt 1, retained its reply name, and delivered
`RELAY_RECONNECTED_OK`. Remote registry inspection found exactly one live
mailbox after reconnect. No terminal or provider process was restarted.
Five Python tests, three Go package test suites, and three Swift status tests
passed. Swift tests used `--build-system native` because the default build
system reintroduced FinderInfo on the generated resource bundle and failed
its signing step. Updated status/receipt UI compiled, but is not installed or
visually accepted yet. Unmeasured route latency is represented as -1, never a
fabricated zero-millisecond measurement.

For outbound messages, invoke the installed route helper with `send --config`
and supply one JSON object on stdin containing `id` and `content`. The helper
requires a fresh online status and revalidates both recipient and return mailbox
before writing. A write receipt is not processing confirmation. No sends or
failed inbound admissions are replayed. Dedup is bounded to 4,096 IDs during
one supervisor lifetime; it is not durable exactly-once delivery.

Stop this installed route with `launchctl bootout gui/501/dev.vaklab.relay-desktop-panbarley`.
This removes only the route service from launchd; it does not stop Codex, Claude,
terminal panes, or the signed shared backend. The plist remains available for
explicit reactivation. No automatic remote software installation is performed.

Remaining gates: installed Network presentation/controls, reusable installer,
MCP grants and route configuration, backend reboot/update lifecycle, broader
fault-injection and latency/energy tests. This route's login startup does not
imply the separately started shared backend is reboot-managed. Desktop-unloaded
messages fail visibly in status rather than silently resuming the task.

`remote/relayd/cmd/relay-codex-session` starts an explicitly selected official
Codex executable as an owned app-server child. It creates a disposable,
read-only session with approvals disabled. It does not attach to existing
desktop chats and does not replace the desktop backend.

The trusted parent supplies newline-delimited JSON on stdin:

```json
{"id":"unique-message-id","sender":"authenticated-peer","content":"Message text"}
```

The parent must authenticate the sender before supplying this envelope. This
helper is not a network listener and does not establish sender identity itself.
Output is newline-delimited JSON: ready with the owned thread ID, admission
receipts correlated to message IDs, and App Server notifications. Admission
does not prove processing or durable storage. Messages enter through
`turn/start.toolOutput`, never user input. No automatic retry or replay occurs.
Keep stdin open while replies are running; EOF terminates the owned child.

Verified separately against the signed desktop-bundled 0.155.0-alpha.9.2:
an idle external message produced its requested test token; a second external
message joined the same active turn and produced its token. Both appeared as
functionCallOutput. That API test is not an end-to-end helper or UI test.

Remaining before deployment: helper integration tests with fault injection,
authenticated peer-network routing, bounded RPC deadlines, user-visible session
lifecycle, outgoing peer tool integration, and explicit approval UX for writable
sessions. Desktop-owned chat ingress remains unverified. Retain the existing
native transport until those gates pass; do not remove authentication.

## Shared-server acceptance (20 September 2026)

### Desktop connection experiment

The installed desktop always supplies a local app-tools plugin configuration
override. Its automatic local-daemon selector requires an empty override list,
so `CODEX_APP_SERVER_USE_LOCAL_DAEMON=1` alone cannot select the daemon in this
build. This was established by inspecting the installed transport selector and
the configuration callback; it is not a signature or authentication failure.

An explicit `CODEX_APP_SERVER_WS_URL` uses a separate built-in selector. The
bundled WebSocket client supports `ws+unix:` with compression disabled. On this
laptop the next-launch experimental value is:

```
ws+unix://localhost/Users/kbd606/.codex/app-server-control/app-server-control.sock:/rpc
```

The socket was verified as owned by the current user with mode 0600, and
initialize plus thread/loaded/list succeeded (zero loaded threads). The server
uses the unchanged official signed executable. No TCP port is exposed. This
setting is experimental, not a supported production desktop integration.

Acceptance remains pending after desktop relaunch: verify shared transport,
sidebar access, app tools, and an external message plus reply in a disposable
desktop task. Never load this active task in two independent servers to test it.
Rollback: `launchctl unsetenv CODEX_APP_SERVER_WS_URL`, then relaunch desktop.
The manually started server is not yet a managed service; do not claim reboot
persistence or automatic upgrade support.

`scripts/test-codex-shared.py` passed against the official signed bundled binary:
two independent Unix-WebSocket clients received both exact reply tokens and the
completed notification for the same turn. The second client must subscribe with
`thread/resume`; `turn/start` alone does not subscribe it. Establish a persisted
initial turn before resume: a brand-new thread without a rollout cannot resume.
Disable WebSocket compression negotiation for this server version.

The official `app-server proxy` is raw byte forwarding, not a JSONL-to-WebSocket
adapter; it cannot directly replace desktop stdio against this listener.
The actual desktop still uses its stock stdio server. This acceptance proves
shared-server messaging, not a supported way to redirect that desktop or retain
its browser/approval integrations through a custom proxy. No live desktop
configuration was changed by the test.

## Owned session production acceptance — 2 October 2026

Relay now ships the detached owned App Server worker and native owned-session
settings, timeline, composer and response controls. A disposable session using
the actual Codex 0.160.0 executable verified creation of a new thread, a successful
model reply from source events, transport reconnect retaining the same worker,
provider and thread, repeated composer-intent rejection, and return to idle.
Existing PTY frontends and threads were not adopted or resumed.

That proof exposed a publication race: a status read could include a durable
turn-completed event before its active-turn ledger update. Provider publication
and status reads now share a lock across durable append and ledger observation.
A deterministic blocked-publication regression, focused race checks, full daemon
suite and a repeated real-provider check pass. The fix is deployed.

Native GUI acceptance, original shared-server frontend binding, provider question
and broader approval/interrupt coverage remain separate gates. Owned new threads
do not establish identity for existing frontends.

Fresh installed-provider proofs also verified a command-execution approval for
one exact disposable file write, changed-owner and repeated approval rejection,
wrong-turn interrupt rejection, and cancellation of a command while it was
waiting for approval. The cancelled command did not create the fixture file,
the turn reported interrupted, and the session returned to idle. All proof
workers were stopped afterward; original workers, providers and drafts were
retained. These are worker/RPC proofs, not native GUI acceptance.

New owned Codex sessions now expose explicit Default and Plan modes. Saved
sessions without a mode retain their prior behavior. Mode requests opt in to
the App Server experimental API for that owned child, preserve the provider's
effective model and reasoning effort, and use its built-in mode instructions.
No global provider feature settings were changed. Default-mode question support
still depends on the provider's disabled `default_mode_request_user_input`
feature. The [official App Server documentation](https://learn.chatgpt.com/docs/app-server)
defines the turn-level collaboration mode and built-in instruction behavior.

A fresh installed Codex 0.160.0 Plan session passed two actual provider questions:
an option selection and a free-text answer. Both answers appeared in the source
assistant reply. Changed-owner, wrong-turn and repeated responses were rejected;
reconnect retained the worker/provider/thread, and completion returned to idle.
The proof worker was stopped. The native client obtains question bodies from
the bounded content journal and correlates them with pending-request metadata;
status metadata alone does not carry question bodies. Native GUI acceptance
remains pending.
