# Plugin acceptance — 2026-09-19

## Installed checkpoint after unlock

At the user's request, with Relay already quit, installed the staged app into
`/Applications/Relay.app` and relaunched it. Its executable matches the staged
SHA-256 `5b80cd01b18ee3c954638abdc765794dad03ef6d11c2deca0dfe0abe6987b670`;
strict deep signature verification passed. Rollback app retained at
`/tmp/relay-before-plugin-install.ujXjMw/Relay.app`.

Native UI verified: workspace/editor restored; R Results opens and switches to
Table and Help; requests/receipts are disabled without a connected companion;
plugin manager reviews the local Radian 0.2.0 manifest, installs it disabled,
enables it and exposes both tool contributions. Radian was enabled on entry and
is left enabled after update. No code was sent to a terminal, no job submitted,
and no remote workers were stopped or upgraded. This is a scoped smoke test,
not full seven-plugin or R execution acceptance.

This is the current checklist. Older nightly notes are historical evidence, not
acceptance of the current installed application. No release gate is waived by
passing component tests.

Manual installed-app verification is postponed at the user's request. Continue
implementation and automated checks; this does not waive release acceptance.
Development Radian 0.2.0 includes local console layout, local editor file helper,
plot zoom/export and stale-preview cleanup. R results identify process/host/CWD
and completion timestamps; environment-export failure preserves execution status.

Project actions 0.2.0 now includes a separately permission-gated reviewed command
operation: captured host/directory, literal argv, explicit environment, bounded
timeout/output, typed confirmation and durable no-replay receipts. No live user
terminal or scheduler input was used in its automated tests.

Latest full-suite rerun compiled but reported 29 issues in native terminal
focus/selection tests. The prior 226-test pass is historical, not acceptance of
this rerun. Native focus-dependent checks remain unresolved and deferred with
manual validation; plugin component checks are run separately.

## Baseline verified this pass

Latest implementation pass:
- 213 Swift tests passed with native focus/WebKit checks explicitly excluded.
- Full Go race suite passed, including transfer and task-delta coverage.
- Disposable R tests passed identity binding/stale-session rejection, help,
  capture quota admission, tables, plots, errors and environment safety.
- Transfers 0.2.0 adds 4 MiB disk-backed chunks, in-panel pause/resume, source
  identity validation and final SHA-256; files up to 64 GiB. Resume across app
  restart and recursive directory download are not implemented.
- R editor has approved companion setup, saved identity handshake, bound
  evaluation requests, on-demand receipts, table-page and plain-text help
  requests. MCP reads saved handshake/results without executing R. A saved
  handshake is not proof that the process is currently alive.
- Claude task-create/update hooks now support bounded identity-preserving deltas.
- No running app or remote session was restarted and no package was published.
- Packaged release build staged at `/tmp/relay-plugin-complete.lOtx4F/Relay.app`;
  strict deep code-sign verification passed. App executable SHA-256:
  `5b80cd01b18ee3c954638abdc765794dad03ef6d11c2deca0dfe0abe6987b670`.
- That exact packaged helper passed 10 local disposable-fixture checks,
  including chunk protocol/final verification and empty-file transfer.
  This is not a remote deployment or installed-app validation.

- Earlier full Swift suite: 226 tests passed (native SwiftPM build system, 2026-09-19).
- Full Go race suite: all packages passed.
- Seven actual manifests: isolated install, enable, disable, re-enable and safe
  mode passed. HPC uses its actual 0.2.0 version in the lifecycle test.
- Local development review validates the same schema, limits and content digest
  as release review; the UI explicitly labels local provenance.
- Fresh built helper: eight disposable-file checks passed on macOS and dandy-07
  (listing, CSV integrity, empty-file integrity, project detection, Git status,
  selected diff, traversal denial, absolute-path denial).
- Live read-only Slurm query: 2,887 jobs, 500 loaded, partial flag true.
- No active remote helper was replaced and no live job was submitted/cancelled.
- Installed R results controls open and switch to Environment without terminal
  input. This checks navigation, not artifact capture or live R completion.
- Plugin tools now provide a direct Manage plugins entry point. Git review has
  an explicit working-file editor handoff with rooted-path validation and
  originating-pane checks; installed acceptance is still pending.
- The default Swift Build test backend failed signing its generated resource
  bundle because of filesystem metadata. Native SwiftPM completed the full suite.
- Installed launch blocker isolated with a process sample: PID 1341 remained in
  `RelayTerminfo.bundledEntryURL` / `NSBundle` directory lookup before creating
  the workspace. The generated accessor searched the development build tree.
  Relay now resolves its packaged resource bundle explicitly for `.app` launches
  (terminfo, editor and browser assets); CLI/tests retain SwiftPM resolution.
  Evidence: `/tmp/relay-plugin-ui-sample-1341.txt`.
- After the resource fix, installed Relay launched and the editor loaded from
  `/Applications/Relay.app/Contents/Resources`. Manually opened Plugin tools →
  Manage plugins → Review local manifest, installed Radian disabled and enabled
  it. Both R tool contributions appeared. Activation from an editor correctly
  failed with a request to select a docked SSH R console. The Mac then locked;
  native testing stopped. The sole test installation was disabled on disk for
  cleanup, not counted as a UI revocation pass. No terminal input was sent.

## Required before release

| Package | Component coverage | Installed acceptance / missing functionality |
| --- | --- | --- |
| HPC | list/details/logs/actions, no-replay, ownership and legacy Slurm tests pass | Install/revoke; actual details/logs; simulated submit/cancel UI; optional explicitly approved disposable live job |
| Artifacts | bounded files/images/Markdown/tables and rooted paths tested | Install/revoke; current installed previews, keyboard and resizing |
| Agent activity | bounded snapshots, duplicate identities, filtering tested | Install/revoke; actual snapshot UI; verify missing provider events are not represented as complete history |
| Git review | scoped status/diff, rooted editor handoff and hostile Git environment tested | Install/revoke; installed changed-file navigation and editor handoff |
| Transfers | chunks, pause/resume, source identity, final hash and confined paths tested | Install/revoke; native Save/pause/overwrite; real SSH large-file acceptance |
| Project actions | project/lockfile detection; reviewed execution, literal arguments, environment isolation, timeout and replay rejection | Install/revoke; installed command review/confirmation/output and interruption UI |
| Radian | local/SSH layout, approved setup, bound request identities, saved completion, paging/help requests, capture quota admission and zoom/export | Installed setup→run→receipt workflow, live multi-client acceptance, keyboard/layout checks |

Radian v0.1.0 is draft. Do not publish another package to make it testable: use
local-manifest review and disposable projects first. Native confirmation is not
proof that remote execution completed. Test results must distinguish both.

Disposable fixtures: `/tmp/relay-plugin-final.VQt2uQ` (Mac) and
`/tmp/relay-plugin-final.FarsBN` (dandy-07). These contain no user analysis files.
