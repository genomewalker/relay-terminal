# Shared R workspace implementation and acceptance

2026-09-21. Target, not a completed-feature claim. Uses the agentic workspace
design and existing Pro UI contract. No new standalone control window.

## Architecture

```
Human editor/console          Local/remote Codex and Claude MCP
          \                         /
           Captured workspace + session identity
                          |
          Authorization and single-writer execution broker
                          |
                  Existing R companion
                          |
        Receipts / plots / bounded object and table views
```

relayd is the authenticated host transport, not the authority to approve analysis.
A remote MCP adapter must receive only the selected workspace's capabilities,
not a copy of the unrestricted desktop control credential. Floating windows do
not determine authority or identity. Bind pane, R process incarnation, project,
actor and request UUID explicitly. R is never duplicated just for an agent.

## Delivery order

1. Align desktop and MCP companion setup, including bounded console lines and
   automatic plot-device selection. Preserve native review. Test exact source
   round-trip, Unicode, line bounds and plot startup/fallback.
2. Implement a companion request protocol with durable admission/result records,
   a bounded queue and exclusive execution ownership. Human console input needs
   explicit input-ownership/prompt integration; a queue for MCP alone cannot
   serialize arbitrary PTY typing. Unknown outcomes are never auto-retried.
3. Add scoped MCP file create/update/open and editor execution. Enforce project
   roots, symlink boundaries, size limits and expected file revision. Opening a
   file is separate from executing it. Preserve unsaved editor buffers.
4. Add named R-session bindings and revocable workspace grants with operation,
   path, actor, expiry and resource limits. Retain per-request approval until
   the grant enforcement is implemented. Plan-mode agents cannot execute by
   routing through another participant.
5. Add remote MCP through an authenticated, explicitly paired relayd channel.
   Exercise two independent remote clients and local desktop access. Reconnect
   revalidates identities; closed SSH does not imply R exited. No exposure of a
   desktop listener or generic control token to a shared remote host.
6. Integrate event-backed plots, safe object summaries, bounded table pages and
   run provenance. Implement the existing design's activity strip and distinct
   pause-admission/interrupt/take-over controls.
7. Add host/environment-bound language tooling: completion, signatures, hover,
   diagnostics, formatting and definitions; negotiate rename support. Keep the
   language server separate from the interactive R process. Installer checks
   dependencies and explains missing components before approved installation.
8. Build, reinstall, reopen and manually accept each integrated increment.

## Reliability contract

Receipts distinguish proposed, admitted, running, completed, failed, interrupted
and unknown. Durable uniqueness is workspace + R incarnation + request UUID;
payload mismatch is rejected. Disconnect after dispatch cannot be interpreted
as non-execution. A new R process invalidates old grants and pending requests.
Results retain producing identity; late responses cannot update another tab.

Avoid promises of exactly-once external effects. R can write files and call
arbitrary tools, so confinement cannot rely on a natural-language task alone.
Permission scopes must accurately describe what the actual execution mechanism
can enforce. Installation and external side effects require their own policies.

## Acceptance matrix

Use disposable local and dandy-07 projects, never research panes. Record build
hash, request IDs, resulting receipts and visual observations.

- Agent creates a script; Relay opens that exact file; editor selection and
  whole-file requests run in the already-bound R session, not a new R process.
- Console, editor and authorized MCP plot(1) appear automatically in Results.
- Two actors submit simultaneously: deterministic admission, no mixed input.
- Human draft survives incoming requests; explicit take-over stops new dispatch.
- Inspect dataframe/tibble/list columns without whole-object export; lazy and
  active bindings are not forced by background refresh.
- Wrong session, path escape, stale file revision, revoked grant, oversized
  request and plan-mode execution all fail without side effects.
- SSH drops before/after dispatch, reconnect and R replacement: no duplicate
  execution and truthful stale/unknown states.
- Resize, zoom, restore and tab switch preserve selection, target and plots.
- Measure idle CPU, memory, queue sizes and latency; set release budgets from
  the existing workload baseline, not arbitrary performance claims.

## Current evidence and gates

Increment 1: MCP setup now chunks the companion into short physical lines while
retaining one outer R expression, and selects httpgd or console capture like
desktop setup. Go tests verify bounds and Unicode source round-trip. Added pure
RExecutionAdmission policy and two passing Swift tests for actor/identity scope,
expiry, human ownership, plan mode, duplicate/conflicting IDs, concurrent
admission, revocation before dispatch and unresolved execution. This policy is
NOT wired into a live broker or a grant UI, is in-memory only, and must not be
used to remove current approval checks. Durable receipts and authenticated
ownership integration are still required by steps 2–5.

Offline snippets passed installed manual checks. Full workflow has not passed.
The previous MCP setup request reached native approval after selecting its exact
terminal; this active-pane restriction is a current limitation, not remote MCP
support. Pending native approvals must be completed by the user, not by an agent
clicking its own approval. File/open tools, scoped remote grants and execution
arbitration are not yet implemented. Revisit durable remote delivery after the
single-session and two-client failure tests pass.
# Implementation checkpoint — 21 September 2026

- Native editor Run / Command-Enter now dispatches directly to the linked,
  connected same-tab console; agent/MCP evaluation retains separate approval.
  Single-line runs advance the cursor only after successful dispatch; selected
  text stays selected. Input currently has a 2 KB safety limit pending staged
  file execution for larger selections. This is not full RStudio expression
  expansion or source-document parity.
- New local profiles select the durable Relay backend. Local node, fallback
  attach, observation, and explicit termination use the bundled helper without
  SSH. Older saved direct local panes retain their mode: live process migration
  is not implemented. Native rendering/input now keys off backend rather than
  SSH host kind so local workers use the same framed transport.
- Swift targeted input/profile tests pass; macOS daemon test suite passes.
  Installed lifecycle and keyboard acceptance are pending the safe restart of
  the running app; existing direct local panes may lose processes on quit.
- Added explicit editor-context-menu Format R document and Check R code,
  using styler/lintr in a separate `--vanilla` Rscript from the console's
  reported R installation and library paths. Code is JSON on stdin, never
  sourced/evaluated; lintr project settings are disabled. Results are bounded,
  timed out, and discarded if the document revision or R session changes.
  Formatting is an undoable edit; diagnostics use Monaco markers.
- Help now uses that same isolated path, not console input. dandy-07 helper
  formatting and lint diagnostics were exercised successfully. Local help was
  tested; local lintr/styler/languageserver packages are absent. No installs of
  those packages have been performed.
- Completion snippets include signatures, descriptions and examples, explicitly
  labelled offline. Full language-server completion/signature help remains
  pending. These new native editor paths await installed manual acceptance.
  Real WebKit regression passed after adding format/undo and diagnostic-marker
  assertions; offline completion documentation tests also passed. Release
  compilation passed. The installer still refuses to replace the running app.

## Installed manual acceptance — 21 September, follow-up

Installed build `0e0df5c14d963be1a0f1906a6afea2d1f1ffde177394fc32648bc2ea3c67d829`
was exercised through the native app in the disposable dandy-07 R workspace:

- Clipboard paste stays in the editor. Fixed unfocused terminal key-equivalent
  interception and captured paste text synchronously before clipboard restoration.
  Real WebKit tests cover paste, undo and stale-document rejection.
- Selected two-line code ran via Command-Enter without an approval dialog;
  selection and editor focus remained, and `plot(1:3)` appeared automatically.
- Two successive current-line runs printed distinct LINE_ONE/LINE_TWO markers,
  proving the cursor advanced rather than re-running the first line.
- Format R document used remote styler, Undo restored the exact original text,
  and Check R code showed a lintr spacing warning via the native F8 inspector.
- Help for `plot` rendered in Results, with no tooling commands added to the
  interactive R console. Temporary editor changes were undone; the saved source
  file was not overwritten.
- New durable local test shell PID 44488 retained its environment marker after
  application quit, reinstall, and supervisor replacement. This verifies process
  and environment persistence, not restoration of all historical scrollback.

Manual checks exposed another existing shell-launch bug: a login Bash bootstrap
followed by exec dropped non-exported profile functions used by PROMPT_COMMAND.
The follow-up loads profile and interactive integration in one process; a real
Bash regression and the complete daemon suite pass. Local helpers start at home
with the account's shell and without inherited PROMPT_COMMAND. Fresh installed
shell acceptance follows the next reinstall. Existing workers keep their shell
state and are not silently replaced. Full LSP and scoped remote agent execution
remain separate unfinished work; this acceptance does not claim those features.

Final installed follow-up: app SHA256
`eeb826c161514350773b74ce552f2cdd9897fd7ed1c38f30bc289e0ba43c0037`,
bundled helper SHA256
`13d5b1036685d94cef8b46be903161ac9cabbea7e60b710c1bdf1c1054323865`.
Fresh local Session 6 opened at `/Users/kbd606` with the normal configured
prompt and bioinfo environment, without the missing-function warnings.
Editor zoom/restore preserved Results; window zoom/restore kept the editor
usable. A post-resize three-line selection created a dataframe, added a second
plot and printed RELAY_RESIZE_OK in the same remote R console. Objects updated
without manual refresh, and clicking relay_resize_df displayed the expected
3-by-2 table without a console command or approval. The original editor buffer
was restored by Undo. These are bounded manual checks, not proof that every
reconnect/redraw path or historical scrollback restoration is correct.
# Editor icon and help checkpoint — 2026-09-21

## Draft recovery installed acceptance

Build `ae139cb60992f4807b0bf092d9e9380845ad62e58e1418b6e563841a14745f6d`
installed and reopened. An unsaved comment survived app quit/relaunch. Undo
restored the user's original buffer and disabled Save; no source-file save was
issued during the test. Recent Documents restored the latest clean content
instead of the older draft captured by its menu row. Disk recovery directory
and record permissions checked (0700/0600); independent pane/host round-trip and
WebKit dirty-draft restoration tests passed. Pane-only close acceptance is not
claimed: the coordinate-free close test reported app exit instead, and relaunch
again recovered the draft. Original user buffer was restored after testing.


Installed acceptance later this day: saved the user's editor buffer through Save,
quit cleanly, installed the release build and reopened it. The buffer restored
unchanged and Save was disabled (clean). The Help icon on `library` selected the
right-hand Help tab and displayed its complete documentation while editor focus
remained. Secondary click opened the editor menu, including Open R Help and the
R actions. The plot pop-out displayed existing plot 2 of 2, enlarged through the
native zoom control with a rendered plot, and docked back with both plots retained
and live updates on. No analysis commands or companion reinstallation were used
for these checks. Loaded-package completion has automated coverage but was not
manually validated in this installation pass.

Implemented compact editor actions for results, Run, Format, Check, Help,
Undo/Redo, Changes and Save using shared icon controls with tooltips and
accessibility names. R formatting/checking require a linked session and are
disabled while a tool is running. Save is disabled for an unchanged buffer.
Editor help sends only the selected topic/current word and document identity
to the runtime; the existing isolated help reader renders it in the right-hand
Help tab, without sending input to the analysis console.

Verification: real-WebKit editor lifecycle passes, including the document-bound
help message and secondary-click selection preservation. Offline and live
completion JavaScript suites pass. These changes are source-tested, not yet
installed/manual acceptance: the running editor contains unsaved user changes
which must be preserved before restart. Physical right-click testing was also
blocked by computer control's `noWindowsAvailable`; Shift-F10 was verified in
the currently installed app and is not proof of the new mouse handler.
