# R workspace and agent plan mode

Implementation plan, 2026-09-19. This is not an installed-feature claim.

The [agentic R workspace design](R-AGENTIC-WORKSPACE-DESIGN.md) defines the
presentation and interaction target: observation-first results, direct console
and editor input, compact agent activity, and explicit execution ownership.
It supplements the shared Pro UI contract without claiming these capabilities
are already implemented.

## Verification checkpoint

- 2026-10-09: authenticated httpgd history now counts unseen arrivals while
  browsing older plots without changing selection. Repeated listings do not
  double count, removed plots leave the count, and following latest clears it.
  Terminal plot-transport failure retains the last bitmap with a disconnected
  label; session replacement and explicit reset clear it and cancel old renders.
  Four focused Swift checks pass (history, transport failure/reset, bounded
  reconnect and render coalescing). Evidence:
  `work/relay-r-history-stale-source-acceptance-20261009.json`.
  Signed candidate build and installed native acceptance remain pending.
  This does not accept the full R workspace or language-server integration.

- Installed acceptance, 2026-09-21: rebuilt release with build-app.sh, cleanly
  quit and reinstalled /Applications/Relay.app, then relaunched. In the native
  app, opened disposable remote editor-completion.R in dandy-07 11. Typed plo,
  invoked completion, observed plot suggestion, accepted plot(x, y), verified
  x selection and Tab to y, and undid insertion. No snippet appeared inside a
  comment or quoted string. Saved the disposable file back to its test comment;
  native UI reported Saved. No R code executed. This accepts offline snippets
  only, not language-server completion, linting or full R-workspace behaviour.

- 2026-09-21: offline R editor snippets implemented for common control structures
  and plotting/data entry, with comment/string and namespace/member guards and
  a document-size bound. Node regression tests and the actual WebKit Monaco
  suggestion-widget test pass. This is not runtime completion or linting and is
  not installed/manual acceptance. The default Swift build hit a resource-signing
  error; the native build-system test path passed. Sidebar local-file preview was
  denied by browser policy and was not bypassed.

## R language tooling implementation boundary

The next integration must run an R language server in the selected host and R
environment, over a framed, bounded transport independent of terminal input.
Bind requests to document URI, version, environment and connection generation;
cancel stale completion/hover requests and discard obsolete diagnostics.
Support completion, signature help, hover, document diagnostics, formatting and
definition first. Advertise rename only if the server supports it. Never use
an arbitrary default local R for a remote project. Dependency setup belongs to
the plugin installer and must report missing R/languageserver/lintr components.
Do not substitute regex-based syntax warnings for an R parser. Editor snippets
remain available offline, but package and runtime-object intelligence must not
be represented as available until its respective transport is verified.

- 2026-09-21: resumed R acceptance. Results now invalidate asynchronous reads
  on session changes and disappearance, clearing cached session-specific data on
  identity changes. Old metadata reads and error callbacks cannot update a new
  session's Results. Companion checks and real disposable httpgd integration
  pass. This is source verification, not installed/manual acceptance or a claim
  that automatic device setup is finished.

- Installed: native editor Run button, per-send exact-code approval, original
  console targeting. Manual Run → Cancel passed; keyboard delivery is not yet
  manually verified.
- Tested in WebKit: line and multiline selection emit exact code and document
  identity without modifying the file. Layout activation preserves sibling panes.
- Implemented: docked Results area with PNG thumbnails, zoom/export, bounded CSV
  previews and saved environment names; companion writes environment.json.
- Newly implemented, manual verification deferred: local R workspace and local
  file-helper transport, without creating or sending input to an R process.
- Implemented in source: explicit companion setup, saved identity handshake,
  identity-bound editor evaluations, on-demand completion receipts, table-page
  and plain-text help requests, capture quota admission, MCP snapshot reads.
- Still pending: installed setup/Results acceptance and multi-client tests.
  Handshakes are snapshots, not process-liveness detection. Direct peer messaging
  and automatic provider plan-mode adapters remain separate unfinished work.
- GitHub release is draft. Do not publish based on unit-test success alone.

## Intended workflow

One Relay tab owns an R workspace with an explicit host, project and existing
R session. Dockable editor, radian console, environment, data, plots, files and
help share that identity. Codex and Claude desktop clients use Relay MCP, not
computer control. Agent-to-agent messages use the existing peer bridge.

Editor / desktop MCP → Relay consent and request broker → existing R companion
→ structured results → environment, data and plot panes.

No duplicate R process. No automatic install into the user's active session.
No polling whole environments or sending large datasets to language models.

## Plan mode

Agent activity (working/idle), provider mode (unknown/plan/execute), plan
revision, and Relay execution approval are separate fields. Relay currently
has activity tracking but no connected provider-mode adapter. The new
`AgentPlanPolicy` is a tested policy foundation, not an active enforcement path.

Adapters must obtain mode from structured provider events/capabilities. Do not
infer it from words printed in a terminal or assume model names imply modes.
Unsupported providers display **Mode unavailable**. Never silently switch a
provider out of plan mode or approve its internal permission prompt.

Plan mode permits reading already-published results and proposing code. It
does not permit evaluating R, installing packages, writing files, submitting
terminal input or relaying execution requests through another agent. Unknown
mode fails closed for autonomous execution. Peer-message content remains
untrusted and cannot grant permission.

An execution approval identifies pane, remote session, connection generation,
plan revision, request ID and expiry. Revisions/reconnects invalidate prior
approval. The broker must consume each grant once and persist request receipts;
the policy type alone does not implement consumption or persistence. A user can
still run code directly in their console independently of an agent's mode.

## Ordered implementation and acceptance

1. **Identity and consent.** Add R-session handshake and capability versions,
   pane binding, native approval UI, single-writer arbitration, disconnect
   invalidation and duplicate request receipts. Test wrong host, reused pane,
   simultaneous clients, human typing, denied/expired approval and ambiguous
   execution outcomes. Do not expose MCP writes before this passes.
2. **Provider plan adapters.** Inspect the actual patched Codex and Claude
   event contracts. Add mode/revision events, plan view and explicit execute
   action. Test plan→execute→plan, reconnect, missing capability, out-of-order
   events and revised plans. Verify that no plan-state action executes R.
3. **R connection.** Explicitly activate the companion in an existing radian
   process, with visible missing-dependency diagnostics. Submit source as a
   bounded request rather than keystroke timing. Correlate accepted/running/
   completed/error/interrupted/unknown receipts. Preserve objects, graphics
   devices and user console input; do not automatically repeat failed requests.
4. **Editor and console.** Bind editor to the workspace R session. Send line,
   selection or source file with source-path/range attribution. Require review
   for agent execution. Test multiline code, Unicode, unsaved selections,
   interrupted commands and tab switches without retargeting.
5. **Environment and data.** Request object summaries on demand/after completed
   evaluation, excluding active bindings and avoiding forced lazy promises.
   Page tables at the source with stable identity and explicit truncation.
   Test large/lazy objects, list columns, duplicate names, missing values and
   object replacement during paging. Never serialize a whole environment.
6. **Plots, files and help.** Add request-associated plot history, zoom/export,
   verified file transfer, bounded artifact quotas and sanitized help views.
   Reuse native viewers. Test multiple/empty plots, prior graphics devices,
   cancellation, lost connections and slow storage.
7. **MCP and peer integration.** Package/configure both desktop clients with
   secure credentials, explicit tool scopes, peer identities and delivery
   receipts. Test two clients alongside the human without computer control;
   distinguish message delivery from recipient completion.
8. **Release.** Validate dock/float/maximize/reconnect, keyboard navigation and
   accessibility in a disposable local and remote workspace. Benchmark idle,
   hidden, busy and large-table cases; bound memory, queues and artifact disk
   use. Publish the plugin only with truthful feature documentation and real
   screenshots after installed-build acceptance.

## Current pieces

- Checklist support now retains Codex `turn/plan/updated` events and successful
  Claude `TodoWrite` hooks as structured steps. Plans appear in the agent
  activity snapshot and matching subagent inspector, persist with pane state,
  and are returned by MCP's agent-context tool. This does not enable provider
  plan-mode switching. Successful Claude `TaskCreate`/`TaskUpdate` hooks now
  support identity-preserving bounded deltas when structured task data is present.
- R environment name listing does not force lazy/active bindings. Explicit
  plain-data-frame inspection supports bounded pages; no native environment or
  continuously live environment UI is connected. Explicit approved table-page
  requests are available in Results; refresh saved artifacts after completion.

- Opt-in httpgd plotting: explicit reviewed start/stop in the connected
  console, loopback-only device with a per-start random token, private SSH
  forwarding, authenticated bounded HTTP reads, hint-only WebSocket, history
  navigation and redraw-on-resize (`RHttpgd*.swift`, `relay_r_httpgd_*`).
  Unit-tested with a loopback mock and against a real device in a disposable
  library; not yet exercised in an installed build or over a real SSH forward.
- Read-only MCP pane discovery/context adapter and Go tests.
- Explicit R evaluation companion with table/plot outputs and disposable tests.
- Development Radian manifest using the existing artifact browser. Not a
  published GitHub release or a fully integrated R IDE.
- App build packaging for MCP executable and R companion.
- Provider-independent plan policy and tests; no live provider wiring yet.

Use event-driven updates, bounded snapshots and user-triggered reads first.
Revisit streaming/persistent subscriptions only when benchmarks justify them.

## Installed acceptance — 2026-09-21

### Direct object previews

The companion now publishes bounded previews for materialized plain data.frames
and tibbles after top-level commands. Object clicks read that snapshot; they do
not submit terminal input or evaluation requests. Limits are 100 candidate
names, 50 columns, 100 rows per preview, 256 characters per cell, and a 512 KB
preview budget. `rlang` is required to identify unforced promises safely; without
it previews are unavailable. Active bindings, promises, custom classes, and
classed columns are excluded rather than evaluated. This is a bounded preview,
not arbitrary object inspection or full-table paging.

The table presentation uses column headers, row numbers, fixed aligned columns,
alternating shading, scrolling and a row/column count.

Installed manual check: upgraded the companion in disposable dandy-07 tab 11,
opened Objects, clicked `relay_test_df`, and observed its 3-by-2 preview with
no approval sheet and no additional console input. The first visual check
caught the two-axis scroll view centering its content; its content now takes
the viewport's minimum size with explicit top-leading alignment.
Final reinstall/relaunch visually confirmed the grid directly below its toolbar,
with headers and row numbers, and repeated object opening without terminal input.
Installed executable SHA-256:
`0e9d360aa56729a0c4a60a6a195858d63fd78a14963d30b41cb501eb77570d03`.
Preview tests passed for data.frames, tibbles, empty data, NA, 100-row bounds,
and exclusion of lazy/active/custom objects. The broader local companion suite
stops in its httpgd tests because local unigd 0.1.2 is below the required 0.2.0;
that suite is not reported as fully passing.

This checkpoint supersedes the older live-plot and environment validation
limitations above, but does not certify the entire shared-execution roadmap.

- Native Connect R stages the bundled companion as a content-addressed file
  on the console host, verifies its bytes, and sends one short, checksum-checked
  source command. It does not paste the companion source into radian, modify
  profiles, or install packages. The explicit Connect R action needs an idle,
  empty R prompt but no second generic input approval.
- Rebuilt, installed, and reopened `/Applications/Relay.app`; executable SHA-256:
  `eff0d45e49420af575379a70368dbb8f48702336f78991c67377d9aa359b7052`.
- Manually validated in disposable dandy-07 tab 11, project
  `/tmp/relay-radian-test.ulQLxtMH`, existing R process 398136:
  handshake restored after relaunch, httpgd connected through SSH, and the
  existing `plot(1)` displayed automatically in Results.
- Typed `plot(1:3)` into that console: Results advanced to Plot 2 of 2 and
  displayed the three points without a refresh or approval dialog.
- Created `relay_test_df <- data.frame(x=1:3, y=c(2,4,6))` in that test console:
  Objects automatically listed `relay_test_df`. User-authored editor contents
  were preserved. This checks names, not table paging or rich inspection.
- Targeted Swift setup/admission regression tests: 3 passed.
- MCP's older source-paste setup path and reusable agent execution grants are
  not covered by this native setup acceptance; do not describe them as complete.
