# Tasks

## Active closure goal — 2026-10-08

Complete the ten agreed workstreams plus OSC 7501 structured program status. The [current closure register](work/relay-closure-goal-20261008.md) defines scope, completion checks and evidence. Preserve existing conversations, panes, drafts and processes; browser and tailnet migration remain deferred.

## Transcript reconciliation — 2026-10-07

The current execution register is [Relay progress](work/relay-progress-20261004.md). The [transcript reconciliation](work/relay-task-reconciliation-20261007.md) restores C21–C34 and expands the acceptance requirements of C01–C20, with original user-message references. Older implementation notes below remain historical evidence, not current completion claims.

Recovered workstreams: editor/project workflows; plugin lifecycle and first-party completion; HPC dashboard; mixed-host/window recovery; semantic shell/customization; operational diagnostics; release/site/documentation; update/fork/restart workflow; unified provider setup; cache-aware capsule rotation; local/remote supervision; VPN tooling; deferred tailnet migration; navigation/design review.

Current constraints: original provider conversations rather than a replacement harness; retain Claude suggestions; SSH retained, no QUIC migration; browser and tailnet changes deferred by the user; Chitta implementation coordinated with its separate owner. Existing installation-scoped MCP grants supersede the old per-request-approval descriptions where applicable.

## Current priority — 2026-09-22

- [x] **Finish Pro Revision 2/A1 migration first** — follow `docs/PRO-IMPLEMENTATION-PLAN.md`.
  - Current isolated candidate: production and candidate run concurrently on ports 47471/47472 with separate state; candidate and nested helpers are signed with the local signing identity.
  - Verification: 329 Swift tests and all `remote/relayd` Go tests pass. Manual installed-candidate acceptance confirmed Network persists through tab selection and exits only on an explicit pane reveal; R workspace → plugin context dock → restored R Results; production remained live on 47471 while the isolated candidate used 47472 and its own state/defaults profile.
  - Pro review corrections are implemented: legacy `/prompt` creates a guarded proposal/receipt instead of writing to a runtime; missing, empty or production-alias candidate profiles fail closed; plugin cache validation and resumption require the current presentation-generation lease and cannot reactivate while Network covers the workspace.

- [ ] **Add an on-device Relay supervisor control plane** — after the Pro safety corrections, design and implement a bounded local supervisor that observes session telemetry and can recommend or request safe lifecycle actions.
  - Implemented deterministic supervisor kernel in `RelaySessionSupervisor.swift`: exact pane/session/generation identity, evidence findings, one-rung cooldown escalation, consecutive-sample recovery, unreachable-host fail-closed behavior, and non-executing recommendations. Model suggestions are rejected if they retarget or exceed deterministic policy. Four focused safety tests pass.
  - Live integration implemented: agent panes provide bounded output, progress age, reconnect history, reachability, usage and exact connection-generation telemetry; Workspace evaluates it every five seconds and Performance shows aggregate findings/highest stage. Candidate UI manually verified `Supervisor · observing · no findings` without disturbing production.
  - Lifecycle proposal receipts now require an actionable recommendation, expire, resolve once, and reject a replaced session generation. Performance exposes a compact review action. The executor consumes each approved receipt at most once, revalidates exact identity/reachability, and requires a concrete live-pane capability; only native graceful interrupt is currently enabled. Offline, stale, expired, unsupported, and missing-capability actions fail closed, and no prompt or shell-command injection is permitted.
  - Supervisor proposals, human decisions, dispatches, results, and deterministic rejection reasons are recorded in a bounded private audit ledger. Corrupt/oversized evidence is preserved rather than overwritten, and failure to persist the pre-dispatch record prevents lifecycle execution.
  - Added an optional Apple Foundation Models advisory adapter behind the existing process-wide scheduler. It receives bounded telemetry only, returns a structured stage plus short explanation, and is rejected if it changes identity or exceeds the deterministic stage. Results are display-only and create no receipt or execution authority.
  - Isolated-candidate acceptance (2026-09-22): rebuilt and launched `dev.relay.terminal.candidate` with binary SHA256 `f993b0b24f745bf2e73de7b5d513b0aa7b466ee7adf980698fab63612dd19746`; strict deep signature verification passed, the candidate listened only on `127.0.0.1:47472`, and its Performance panel visibly reported `Supervisor observing · no findings`.
  - Actionable lifecycle acceptance (2026-09-22): added a release-inert `#if DEBUG` fixture that activates only for an explicitly flagged isolated profile, then used native computer control against a separately identified `Relay Supervisor Fixture.app`. The visible Performance panel escalated from `checkpoint` to `interrupt proposed`; the native review alert was approved; the harmless foreground loop visibly received `^C` and returned to its shell. The private 0600 ledger recorded one exact receipt and pane/session/generation through `proposed → approved → executionDispatched → executionSucceeded`. Production Relay and real agent panes were not targeted. Final verification: 343 Swift tests pass and a clean production configuration build succeeds with the fixture compiled out.
  - Default Mac provider: Apple Foundation Models `SystemLanguageModel` with guided structured decisions and tool calling; portable fallback: a small local model such as Qwen3-4B behind the same provider protocol.
  - Hard policy remains deterministic Relay code. The model never receives unrestricted shell/process authority and never decides authorization, fencing, retries or destructive termination.
  - Lifecycle ladder: observe → warn → stop new work → request durable checkpoint → graceful interrupt → policy-approved terminate/restart. Every transition has an exact target, reason, timeout and receipt; offline SSH queues intent without executing against a replacement identity.
  - Apple Neural Engine track: use an optional small Core ML anomaly classifier for continuous low-power detection of retry loops, runaway output, stalled agents, token pressure and restart storms. Foundation Models chooses its own optimized hardware; MLX fallback uses CPU/GPU rather than ANE.
  - Train/fine-tune only after collecting reviewed telemetry/decision/outcome examples. Initial release uses prompt-versioned structured classification and recorded human corrections.

- [ ] Then integrate Chitta-owned deterministic usage policy for Codex and Claude.
  Track responses, input/cached/uncached/output/reasoning tokens, tool calls,
  cumulative input and current-context input; preserve unknown values explicitly.
  Proposed configurable defaults: prepare at 40K context or 30 responses; rotate
  at 60K context, 50 responses or 1M cumulative input; pre-tool block at 20 calls
  per turn. Chitta/harness enforces; Relay consumes normalized versioned state
  and rotates only after a safe turn and durable handoff. No model-made policy.
- [ ] Coordinate that schema and fixtures with laptop-chitta-sync. Large-payload
  gateway: Chitta retains raw artifacts/provenance, deduplicates/chunks and returns
  bounded objective-relevant evidence with cited chunks fetched on demand.
  Measure raw/returned tokens and summarizer overhead against recorded traces
  and quality gates. A small model may summarize, never control session lifecycle.
  This is separate from Pro migration and is not implemented behavior.
  Follow-up: native Chitta implementation, no webctl dependency; chitta-bridge
  exposes adapters, Relay only safe close/start/resume. Target <=20K hot prompt;
  content-addressed artifacts with exact range fetch, no repeated 100K–200K
  replay. Never persist credentials in Relay state, logs or coordination messages.
  Astra–Opus review (pending user/contract confirmation): do not rotate solely
  on raw prompt size. Compare cache-aware projected continue(N) cost against
  capsule/cache-rebuild/evidence-refetch rotation cost, plus TTFT and quality.
  The earlier numeric thresholds are proposals, not settled rotation rules.
  Candidate protocol: native CAS artifacts, handle-only <=4K capsule, journal
  watermark, fenced CAS commit; Relay executes a persisted fresh-thread intent,
  never resumes/forks full history as a rotation shortcut. Prove Codex app-server
  RPC capabilities first; Claude CLI/Desktop remain advisory until enforceability
  is demonstrated. Preserve cache-stable prefixes and reduce the uncached tail.
  Jev/Luna may rank handles only, never decide lifecycle. No implementation or
  new authority is implied by collaborator design messages.

Relay implementation and verification backlog — updated 2026-09-20.

Priorities: P0 = correctness/data safety; P1 = core workflow; P2 = optional expansion. The user-directed implementation sequence below overrides scheduling, but does not waive correctness or release gates. This is a plan, not a claim that the features below are complete.

## Current execution order — user decision, 2026-09-20

Locked-laptop verification (2026-09-20): all Go package tests (including race detection) and `go vet`
passed. The Swift run excluding `TerminalPromptClickTests` passed 241 tests;
the full 258-test run failed with 29 issues in that foreground/clipboard suite.
Those failures remain an unlocked acceptance gate, not a claimed fix or pass.
The editor lifecycle harness was repaired for Monaco's action API and passes.
R companion checks passed for evaluation, plots, object inspection, table pages,
stale-session rejection and quotas. A disposable real httpgd process passed the
Swift descriptor/auth/history/resize/change-socket integration test using
`/private/tmp/relay-httpgd-lib`; no existing R console was touched. The live-test
cleanup now handles missing httpgd without an unbound PID error. No app restart,
installation or live-session mutation was performed in this verification batch.

Latest network evidence (2026-09-20): packaged Relay was installed and relaunched
from `/Applications/Relay.app`; MCP control/status/saved-link/local-discovery
reads succeeded against that running process. Codex and Claude Desktop config
entries were added without copying a token (explicit `--use-relay-token`);
client reload and actual desktop tool use remain unverified. The installed
server rejects unknown-link proposals with HTTP 409. Nine focused source tests
now pass, including cancellation/idempotency and stale approval targets.
The latest off-main-thread approval reads and presenter-test refactor are
source-only, newer than the installed build. Real connect/disconnect approval
acceptance is still pending; no user agent was terminated by these tests.

Network map correction (2026-09-22): live reproduction showed Connections
reporting the saved desktop-task ↔ remote-agent route while Map omitted both
endpoints and its edge because topology started only from pane identities. Exact
configured-link endpoints are now merged without guessing pane ownership or
expanding host discovery. A regression test passes, and an isolated candidate
with synthetic status metadata displayed both external endpoints, Messaging
connected labels, and the connected edge. Host-column changes now restore the
map to its top-leading origin instead of leaving a newly added left endpoint
clipped. The candidate runner also uses the same valid isolated defaults suite
as the candidate builder. Production was not replaced during this check.

Native session-group visibility (2026-09-23, source only): the remote host has
four saved same-host group receipts with introduction writes, while its current
`relayd network` snapshot reports 16 pane-bound peers and zero links. Native
group setup sends direct socket introductions but did not feed the Network map,
making the relationship appear to vanish. The daemon now exports bounded,
private group metadata with exact process-incarnation checks; the UI renders
current groups separately from connected transports. Focused Go and Swift tests
pass. A staged remote snapshot and installed-app visual acceptance remain open;
do not count an introduction write as agent acknowledgement or a live stream.

Installed Network follow-up (2026-09-22): the production app was subsequently
replaced with a signed build (executable SHA-256
`ba8ae55c087df390fcabb4abc8354b8f4bd379c3f4050724e6af7f0a9ff370f3`).
The live Map visibly placed the exact desktop-task and `cc-soul-9f` endpoints
and their Connected edge at the top of the two host columns. A focused native
SwiftPM regression test for the endpoint ordering passed. This verifies map
presentation of an existing link, not bidirectional delivery, recovery, or
the broader session-networking acceptance gate.

Follow [the workspace UI contract](docs/WORKSPACE-DESIGN.md). No additional
navigation hierarchies or per-plugin windows without a documented design decision.

1. **Finish session networking first.** Verify local/remote Codex–Codex and
   Claude–Codex bidirectional delivery, explicit connection ownership, disconnect/
   reconnect, stale identity handling and no duplicate execution. Complete the
   integrated network UI and installed/manual acceptance. Working transport is
   not proof that discovery, orchestration or durable offline delivery is done.
   Chitta durable handoff remains dependent on the remote maintainer's schema;
   proceed with independent network work without pretending federation exists.
2. **Finish the R workspace next.** Existing local/remote R identity, editor send,
   automatic plots after approved setup, objects/tables/help, layouts and restore;
   visually verify the full workflow without recreating the user's R process.
3. **Integrate and verify remaining plugins.** HPC jobs, Artifacts, Transfers,
   Git review, Project actions and Agent activity follow the capability mapping
   in the UI contract, retaining authorization and target-binding guarantees.
4. **Resolve deferred terminal regressions before release.** Redraw, exit traces,
   Codex selection and prompt deletion remain open below; no release-ready claim
   until installed local/SSH manual reproduction and regression checks pass.

### Latest terminal reports — unresolved

- [ ] **Codex redraw and selection/delete** — user still reports broken redraw,
  selection and deletion in the remote Codex pane. Reproduce selection alignment,
  wrapped/Unicode prompt editing, Backspace/Delete and shortcut routing. Distinguish
  terminal copy selection from provider-owned editable prompt selection; fix
  the Codex fork where provider cooperation is needed, never delete transcript
  output or synthesize unknown cursor movements as a workaround.
- [ ] **Claude/Codex exit traces** — classify retained primary-screen output versus
  stale pixels or damaged alternate-screen restoration, including resize and
  reconnect. A simple alternate-screen entry/exit test passed; that does not
  validate the real agent lifecycle or disprove the user's report.
- Computer-control recovery: raising Relay's AX window allowed wheel input in
  both directions on 2026-09-20. This removes the immediate test blocker, not
  the rendering defect; retry raising the window if `noWindowsAvailable` recurs.

Definition of done: implementation reviewed, automated tests passing, installed-build manual verification recorded, and relevant performance/regression checks passing. Record app commit/build/hash, remote supervisor version, worker version/capabilities, agent version, host, scenario, and result. A new binary on disk does not prove existing processes use it.

Current evidence (2026-09-18): 191 Swift tests pass, including real WebKit edit/diff/undo, editor presentation ownership/layout, focus-notification routing, observer handshake, and stale editor-request checks. Editor JavaScript lifecycle and Go daemon/CLI checks also passed. Tracked-first remote search returns 13 README matches on the actual project without the previous untracked-file timeout. Editor responder routing, stale-open edit guards, originating-pane ownership, and app-quit dirty guards are implemented. Floating/maximized presentations use separate native containers for the persistent editor view and event-driven Monaco layout notifications. Search state now survives presentation changes.

Installed and relaunched `/Applications/Relay.app`, binary SHA256 `81274f4799eca1d74f1bb2d418c547ca2fa02a16f6a115e94d75a7fca8d6c63d`, observed PID 20871. Final logs: `/tmp/relay-editor-verify.FoUzdj/focus-final-build.log` and `focus-final-tests.log`; previous-app backups are in the same directory. Remote dandy-07 supervisor was updated separately; durable workers and agents were not terminated. Do not assume old workers adopted the new binary.

Live verification: after the layout fix, README text remained visible through tested maximize/restore transitions. A live rcode request opened the disposable remote file `/tmp/relay-editor-test.JQQg6d/example.txt` in its originating dandy-07 8 tab, and its text visibly rendered. Fixed the observer handshake: combining observe_events with event_only selected the publisher path and prevented event delivery. rcode now emits unique request IDs; historical/snapshot open requests are ignored instead of reopening editors. Fractional remote timestamps now parse correctly. Freshness currently requires timestamps within 30 seconds (allowing 30 seconds of future skew); delayed requests and larger clock skew need explicit delivery feedback.

Manual verification remains incomplete: coordinate mouse input reports `noWindowsAvailable`, although accessibility buttons work. Automated typing/paste reports success but the test document remains unchanged; native input, undo/paste/save and drag acceptance are not verified. A directory-load completion can overwrite the document footer status. Remote-to-local file dragging is not implemented. Earlier terminal/agent regressions remain release blockers until reverified. One idle process snapshot showed 0% CPU and 165616 KiB RSS; this is not a battery or sustained-performance benchmark.

## Active

- [x] **Window closes during computer-controlled typing — 2026-09-21** — Captured the close stack through `RelayWindowControls.control`, followed by AppKit's last-window termination. Removed the custom full-workspace SwiftUI traffic-light overlay and restored native AppKit controls. Installed/manual remote shell checks produced `RELAY_INPUT_TEST` and `RELAY_PASTE_OK` without exiting. The paste tool returned a clipboard timeout despite successful delivery; inspected before sending Return, never replayed the paste. Native control bounds/visibility regression plus four related geometry/layout/resume tests pass. This does not close general terminal redraw or R visual acceptance work.

- [ ] **Rendering/R acceptance checkpoint — 2026-09-21**
  - Installed native hidden-output catch-up ordering/mirror-dedup fix and R layout snapshot persistence. The Results dock survives reopening in the installed app; visually checked editor/console/results arrangement.
  - 23 focused viewport, replay, geometry and pane-arrangement tests passed. This does not establish end-to-end remote reconnect or R plot acceptance.
  - Installed binary SHA256: `11bdf7d481f40edd32f38f5882a1042af9f6238099cf355d032dc21b70dc0036`.
  - Lifecycle logging identified observed exits as AppKit's terminate-after-last-window-closed path, not renderer crashes. Why the window closes remains unverified. No termination protection was bypassed or disabled.
  - Manual input remains blocked: computer control reports `noWindowsAvailable` while the installed process is alive (PID 26556 at the checkpoint), after successfully reading the window and screenshot. Paste also reported clipboard-read timeout. No successful terminal input or plot display is claimed.

- [ ] **MCP workspace controls — after R acceptance** - User confirmed ordering on 2026-09-21. Add exact-target remote tab creation, tab/pane naming, pane splits and receipts. Native approval, instance binding and ambiguous-result handling remain mandatory. Preserve active research panes; expose created IDs separately from shell readiness. Notify Retrieve white paper files when usable.

- [ ] **R workspace acceptance resumed — 2026-09-21** - Moving to the next agreed work area; networking is not declared complete.
  - Source fix: changing R session clears cached plot/table/environment state and invalidates pending artifact reads. Hidden Results also invalidate reads; old completions cannot clear a newer request's busy state.
  - Verification: companion evaluation, table/object, help, quota and console-capture checks pass. A disposable real httpgd device passed authenticated history/resize/change-socket integration. Installed/manual acceptance is still pending; existing user R sessions were untouched.

- [ ] **Persistent per-task peer routes — choose once, reconnect automatically** - Relay-owned; laptop-sync handoff, 2026-09-21.
  - Bind the exact desktop task to the exact remote peer with a verified bidirectional reply path independent of the originating coordinator task's lifetime. Remember authorized routes and supervise recovery across SSH loss and Relay restart.
  - Automatically establish/restore already-authorized bindings; no manual mailbox registration or tunnel recreation. Changed remote session identity requires explicit rebind, never silent substitution.
  - UI: Online / Reconnecting / Needs attention, actionable repair. Agent API: structured status and sent/admitted/acknowledged/unknown receipts. No automatic duplicate retries; preserve drafts and remote agents; never silently resume tasks or expand access.
  - Acceptance: task 01a0bf6c-38bd-7a72-b50d-22caf953028b exchanges a probe and direct reply with cc-soul-9f, survives interruption and app restart, and detects replacement identity. No coordinator relay, ad hoc SSH scripts, or shared guidance files.
  - Reproduced: handoff acknowledgement could not reach that exact task; bridge exposed only codex-mac/codex-mac-ro. Existing single-route machinery does not satisfy this acceptance case.
  - 2026-09-23 live failure: two saved desktop routes retried thousands of times against remote Codex PID 1424257 after that process and its registry entry disappeared. The remote worker now emits an identity-change event when the pinned process/record/socket vanishes; the installed local routing helper and both routes reached `Needs attention` instead of continuing the SSH retry loop. The separate `cc-soul-9f` route stayed online. Discovery found the same session ID under a new PID/start (662217/821467033); explicit rebind is required before either saved route may target it. Component route tests pass; no task or remote agent was restarted or retargeted.

- [ ] **R workspace + provider plan mode** — follow `docs/R-WORKSPACE-PLAN.md` in dependency order: identity/consent, structured provider modes, existing-session R connection, editor/console, environment/data, plots/help, MCP/peer setup, installed-build acceptance.
  - Current: development Radian artifact-viewer manifest and R companion; read-only MCP adapter; plan policy foundation. None implies that live provider plan detection or agent execution is connected.
  - Safety gate: plan/unknown mode does not authorize autonomous execution; permission must be explicit, request-scoped and invalidated on revision or reconnect. Preserve direct human console use.

- [ ] **P0-01 — Establish a reproducible installed-build baseline**
  - Implement: expose app, relayd supervisor, durable-worker, and agent versions/capabilities; show mismatches and unsupported features without killing sessions.
  - Test: mixed versions, old surviving workers, missing capabilities, failed upgrades, and rollback.
  - Verify: record the actual running versions locally and on dandy-07 before every manual test; use disposable sessions/files and preserve existing agents.

- [ ] **P0-02 — Fix terminal rendering and geometry lifecycle**
  - Implement: trace layout, backing scale, drawable size, terminal grid, and PTY resize ordering; remove conflicting resize/redraw ownership rather than masking it with forced resize pulses.
  - Test: rapid tab switches, split/dock/float, maximize/restore, hide/show, display-scale changes, reconnect, and alternate-screen entry/exit.
  - Verify: local shell, remote shell, Claude, and Codex retain correct text, cursor, selection alignment, and status lines after 50 layout cycles; no black flashes requiring a manual resize to recover.
  - 2026-09-25: fixed a concrete SSH geometry deadlock. The app predicted 165×48 from view bounds while Ghostty measured 162×47 with cell padding, so Relay withheld the PTY resize and Claude kept a narrow question border. Commits now use Ghostty's matching measured grid. Signed isolated candidate passed sidebar hide/show and window zoom/restore with a disposable dandy-07 Claude question; remote PTY changed 132→162→132 columns. Full Swift suite: 353 tests pass. The broader 50-cycle and provider matrix remains open.

- [ ] **P0-03 — Fix freezes and bound background work**
  - Implement: instrument main-thread stalls, render/transport queues, lock waits, polling, and worker CPU/thread growth; stop hidden-view painting without stopping PTY ingestion or breaking restoration.
  - Test: output floods, many idle panes, slow consumers, hidden/minimized windows, and slow remote storage; verify bounded queues and backpressure.
  - Verify: a 30-minute mixed Claude/Codex/shell workload with no observed input freezes; record latency percentiles, CPU, physical memory, threads, wakeups, and queue peaks against a repeatable baseline. Set numerical budgets from measurements, not a blanket sub-millisecond promise.

- [ ] **P0-04 — Restore predictable terminal input and clipboard behavior**
  - Implement: route shortcuts according to the actual focused surface; distinguish terminal selection, CLI-owned prompt editing, and editor text editing. Never delete output by guessing where editable input lies.
  - Test: copy/cut/paste, multiline and large bracketed pastes, Shift-Enter, keyboard/mouse selection, Unicode, wrapped lines, and mouse-reporting applications.
  - Verify: manually test local and SSH shells plus both agent CLIs; no unexpected submission, window dragging, selection offsets, or input delivered to the wrong pane. Document which prompt-editing actions require CLI cooperation.

- [ ] **P0-05 — Verify scrolling and alternate-screen cleanup**
  - Implement: establish whether the CLI or terminal owns scrolling in each mode; preserve terminal control sequences and synchronized-update boundaries.
  - Test: transcript scrolling during output, jump-to-latest, viewport resize, htop/watch exit, Ctrl-C, and reconnect in alternate-screen mode.
  - Verify: conversation text does not disappear; prompt anchoring behaves according to the CLI's supported mode; quitting full-screen programs restores the shell without leftover screen fragments. Check the custom Codex fork separately from Relay.

- [ ] **P0-06 — Make detach, terminate, and recovery unambiguous**
  - Implement: explicit close/detach versus terminate actions, recoverable closed panes, deterministic input-control ownership, and actionable unavailable-worker status.
  - Test: accidental Command-W, app restart, supervisor restart, missing worker socket, VPN interruption, simultaneous clients, and reconnect storms.
  - Verify: reattach a disposable running agent without starting a duplicate writer or losing input; terminate only on explicit action. Never terminate existing user sessions during testing.

- [ ] **P0-07 — Fix editor painting, focus, and native shortcuts**
  - Implement: reproduce the blank floating editor; inspect WKWebView layout/visibility and focus ownership; route undo/redo/save/clipboard to Monaco when it owns input, and native text fields when they do.
  - Test: floating/docked/zoomed layouts, tab switching, text-field focus, keyboard navigation, diff mode, and editor/terminal shortcut conflicts.
  - Verify: visible syntax-highlighted text, aligned cursor/selection, multiline paste, Command-Z/Shift-Command-Z, Command-S, find, and copy/paste in the installed app. Confirm saved bytes remotely, not only toolbar state.

- [ ] **P0-08 — Finish editor data-safety guarantees**
  - Implement: preserve undo across diff toggles; keep edits made during save; reject stale open/save responses and external-change conflicts; guard dirty navigation, pane/tab/window close and app quit; provide recoverable drafts.
  - Test: delayed saves, queued saves, failed writes, disk full, permissions, agent edits to the same file, reconnect, edits while opening another file, and quit/relaunch.
  - Verify: disposable files retain all expected edits and undo history; no silent overwrite or discarded draft. Separate a successful write from durability guarantees the backend cannot provide.

- [ ] **P1-01 — Define editor ownership per tab and terminal pane**
  - Implement: make host, project root, and originating pane visible; define explicit reuse versus open-another-editor behavior. Do not silently switch an editor to another host/project merely because both use the same SSH alias.
  - Test: two tabs on one host, two projects on one host, different hosts with identical paths, origin pane closure, and restored layouts.
  - Verify: opening through rcode or the toolbar always targets the intended tab/project; closing an editor leaves the terminal process intact.

- [ ] **P1-02 — Reliable rcode entry points and lazy file browsing**
  - Implement: reliable file/folder open-event delivery with observable failure; lazy directory expansion, breadcrumbs, refresh, open-at-line, and safe handling of symlinks, permissions, binary/large files.
  - Test: rcode file, rcode directory, diff requests, Unicode/spaces/quotes in paths, stale paths, and failed event delivery. Verify remote paths are never resolved against the Mac filesystem.
  - Verify: command-driven opens work in the originating tab and folder browsing remains usable without Git or recursive indexing; distinguish saved-file content from unsaved editor content.

- [ ] **P1-03 — Fast fuzzy file finder**
  - Implement: Command-P with ranked path matching, recent files, preview, and line jumps; a bounded per-host/project filename cache; tracked files first and explicitly bounded untracked discovery. Separate timeout, non-Git, and permission errors; preserve useful partial results.
  - Test: large repositories, ignored/hidden files, cache invalidation, renames, worktrees, slow HPC storage, and cancellation as the query changes.
  - Verify: measure cold/warm first-result latency on a real large project; no full filesystem scan per keystroke and no continuing search after the picker closes.

- [ ] **P1-04 — Remote content search / grep**
  - Implement: structured ripgrep results over authenticated SSH, literal/regex and case controls, include/exclude globs, folder scope, context previews, click-to-line, cancellation, and explicit truncated-result status. Provide a clear missing-ripgrep setup path.
  - Test: invalid regex, binary/huge files, ignored files, unusual filenames, Unicode byte-to-editor-column conversion, changing files, and dropped connections. Pass arguments without shell interpolation.
  - Verify: matches and opened selections agree with remote results; searches do not freeze terminal input or ship entire repositories to the Mac. Preview any future bulk replacement before applying it.

- [ ] **P1-05 — Remote-to-local downloads and Finder drag-out**
  - Implement: native macOS file promises from file rows and artifacts; Download… fallback; SSH-backed streaming, bounded memory, progress/cancel, partial-file cleanup, and collision handling. Start with files; make directory behavior explicit.
  - Test: Finder/Desktop destinations, multiple files, empty/large files, unusual names, unreadable sources, symlinks, full local disk, interrupted transfer, cancelled drag, and a source modified during download.
  - Verify: compare checksums for stable source files; remote originals remain untouched; failures leave no misleading completed file. Download only after an intentional drop/action.

- [ ] **P1-06 — Reliable path actions and bidirectional file transfer UX**
  - Implement: resolve paths using the originating host/CWD; route code/text to rcode, images to the viewer, URLs to the local browser; add explicit Download and Copy path actions. Avoid confusing text-selection drags with file drags.
  - Test: relative/absolute paths, wrapped CLI output, punctuation, identical paths on different hosts, incoming files, name collisions, and large uploads.
  - Verify: incoming transfers show their remote destination and insert a correctly quoted path without executing it; outgoing transfers reach the selected local destination; no silent overwrite.

- [ ] **P1-07 — Project changes and agent handoff**
  - Implement: changed-file list and diffs, open-at-line review, and send a selected file/range to a explicitly chosen existing agent with host/project context. Keep editing and transfer progress separate from agent activity.
  - Test: dirty worktrees, renamed/untracked/deleted files, concurrent agent edits, stale diffs, offline agents, and wrong-host prevention.
  - Verify: user can inspect a change and hand off the intended selection without spawning an unwanted session or sending unrelated/private file contents.

- [ ] **P1-08 — Structured agent integration feasibility and boundaries**
  - Implement: assess T3 Code's provider adapters/event model for reuse; define optional structured agent views alongside real terminals. Prototype Codex/Claude lifecycle, approvals, artifacts, subagents, and peer-message events without assuming an existing CLI session can be adopted.
  - Test: capability/version negotiation, interrupted streams, duplicate/replayed/out-of-order events, session exit, and 100-subagent trees.
  - Verify: no ghost running agents; stable expandable activity; correctly addressed peer messages; no duplicate provider writers. Document unsupported integrations and any license obligations before copying code.

- [ ] **P1-09 — Accessibility and interaction consistency**
  - Implement: meaningful names, keyboard access, visible but unobtrusive focus, consistent close/save/recovery wording, readable contrast, and usable layouts at larger fonts.
  - Test: VoiceOver, keyboard-only navigation, reduced motion, long paths, narrow panes, and floating editor/file-picker controls.
  - Verify: complete open/search/edit/save/download flows without a mouse; keyboard focus never disappears into a hidden terminal. Editor close must not misleadingly claim that an editor has a surviving remote shell.

- [ ] **P1-10 — Release verification and documentation**
  - Implement: runbook and regression matrix; document editor limitations, session ownership, transfers, installation/upgrade behavior, and recovery. Keep privacy-safe evidence and diagnostics.
  - Test: clean install, upgrade with old workers, DMG install, reconnect after restart, and package integrity on supported platforms; run CI plus live UI tests.
  - Verify: installed /Applications build and remote components match recorded artifacts; no outstanding P0 failures; review changes before commit/tag/release. Publishing and replacing live agent processes remain separate explicit actions.

## Waiting On

- [ ] **Release milestone — Relay website at relay.vaklab.dev** - Requested 2026-09-19; publish on GitHub Pages only after production-readiness acceptance, not merely passing component tests.
  - Gate: no unresolved P0 terminal/input/rendering/reconnect failures; installed-app and matching remote-helper validation; clean-install/upgrade checks; supported plugin features verified; versioned downloadable release with clear signing/notarization status.
  - Design: polished, restrained visual design aligned with native Relay; original layout, strong typography, real privacy-safe screenshots and short workflow demonstrations. No exaggerated claims, stock AI imagery, or unfinished features presented as available.
  - Content: direct macOS download with compatibility/version details, remote-session and agent workflows, plugin catalog with honest feature status, installation and recovery guides, development documentation, changelog and GitHub links.
  - Engineering: fast static site on GitHub Pages, responsive layouts, accessible contrast and keyboard navigation, reduced-motion support, optimized assets, working links and downloads; no tracking by default.
  - Domain: user explicitly authorized a public development preview on 2026-09-19. Pages is built from gh-pages (77c91b7); Cloudflare relay CNAME points to genomewalker.github.io. Verify HTTPS issuance/enforcement. Production-download promotion remains gated on acceptance; publishing the preview is not production readiness.

- [ ] **Decision — live Codex replacement/resume** - Some prior checks found a live process using an older binary than the installed one. Recheck before acting; cleanly restarting a user's working agent requires explicit coordination, not an automatic fix.
- [ ] **Decision — advanced service footprint** - Choose supported languages, memory/CPU limits, and HPC policy constraints before enabling remote language servers or a third-party remote-access service.

## Someday

- [ ] **P2 — Optional language navigation** - On-demand language servers for symbols, definitions, references, and diagnostics; test version compatibility, resource limits, and idle shutdown before rollout.
- [ ] **P2 — Structural search** - Evaluate ast-grep/Tree-sitter after text search is dependable; test language coverage and preview-only operation before any rewrite support.
- [ ] **P2 — Semantic search** - Consider opt-in retrieval only if measured task benefits justify indexing cost and privacy/storage implications. Do not reintroduce always-on prompt prediction as a prerequisite.
- [ ] **P2 — Advanced transfer recovery** - Directory transfers and resumable large downloads, with explicit symlink/collision policy, integrity checks, and interrupted-transfer testing.

## Done

## Desktop MCP and radian integration — in progress

- [x] Implement per-request native approval for terminal/R setup/R evaluation proposals, selected-pane/revision checks and server-instance-scoped receipts. Compiles; 222 Swift tests and MCP component tests pass. Native approval-dialog acceptance is still pending.
- [x] Produce signature-verified staged app at `/tmp/relay-integration.hCravG/Relay.app`; bundled MCP initialization and tool discovery smoke-tested. Running installation unchanged, awaiting relaunch choice.

- [x] Preserve structured Codex plan updates / Claude TodoWrite checklists, render activity/inspector checklists, persist bounded plans and expose them in MCP context. Component tests pass; live provider verification pending.
- [x] Add isolated R environment-name listing and bounded plain-data-frame pages with active-binding protection. R tests pass; UI/transport not connected.

- [x] Add read-only stdio MCP adapter for authenticated pane discovery and bounded agent context, without computer control. Unit/race tests pass; not installed in desktop clients.
- [x] Add isolated opt-in R companion: retained environment, structured errors/results, bounded table previews and PNG plots. Disposable R tests pass; not connected to live radian.
- [ ] Add pane-scoped consent and input ownership before exposing write tools; stable target/generation validation and duplicate execution protection.
- [ ] Add bounded terminal snapshots and request completion events.
- [ ] Connect existing remote peer messaging with unambiguous discovery and delivery receipts.
- [ ] Wire R companion activation/execution, artifact quotas/downloads/native previews, and publish the radian plugin.
- [ ] Package MCP executable, secure token provisioning and desktop-client setup; verify two-client and human-input/reconnect workflows before rollout.
- Design and current limitations: `docs/RELAY-MCP-RADIAN.md`.

No product task is marked complete by this planning pass. Previously passing automated tests are evidence, not substitutes for installed-build acceptance checks.
