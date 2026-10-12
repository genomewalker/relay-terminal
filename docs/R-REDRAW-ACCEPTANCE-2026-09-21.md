# R companion and reconnect acceptance — 2026-09-21

Implemented in the installed release:

- R pager output is published as session-bound help and displayed in Results → Help.
- Companion v3 advertises cooperative updates applied between top-level R commands.
  Legacy companions still require a one-time explicit connection; no blind injection
  into a running calculation or pager.
- Reconnecting the companion preserves an existing plot device/history.
- Local plugin-budget pressure no longer invalidates a previously validated R handshake.
- Terminal replay buffering begins synchronously in the ordered reconnect status
  callback, before subsequent bytes, rather than waiting for the main actor.

Automated checks passed: R help/update tests; R completion tests; WebKit/editor and
R session tests; replay-order tests; immediate reconnect-gate regression; typed
plugin-budget rejection test; Go daemon tests. The default Swift test backend hit
a generated resource-bundle signing error; the native backend passed.

Installed manual evidence (dandy-07, tab dandy-07 11):

- Existing R PID 398136 remained running. Companion handshake reports version 3.
- Existing two-plot history survived companion connection.
- Entering `?mean` in radian selected the Help sidebar and displayed Arithmetic Mean;
  the console returned to its prompt, without opening its old inline pager.
- Loading `splines` updated the environment snapshot to include its 13 exported
  symbols. Requesting completion after `splines::` displayed package-labelled
  suggestions in the installed editor, including splineDesign.
- Temporary completion probe text was removed; no test edits saved to the source.
- Rice tab: Codex and Claude each zoomed and restored to the split layout with
  readable text and intact prompts. No research commands were entered.

Limits: forced network-loss recovery and process-exit rendering were not manually
stress-tested in this pass; this is not a claim that every reported redraw defect
is resolved. Help polling currently requires the Results dock to be visible.
Completion is snapshot-based, not a complete language-server implementation.

## Follow-up: PanBarley corruption reproduced

The user reported corruption repaired by resizing. Before resizing, both the
screenshot and native viewport readback showed missing characters in pane
ce01da4d-b6b7-4d39-9030-48db07f667b8 and missing/misplaced Claude status content.
A 50% → 55% divider change restored complete Codex text and its composer;
the divider was returned to 50%. No terminal commands were entered.

Source defects found: replay compaction accepted cursor-home as proof of a
self-contained synchronized frame, and ED 3 (scrollback erasure) as a full
screen clear. Neither justifies discarding prior visible cells. The native
compactor now retains these bases; relayd's fresh replay boundary also excludes
ED 3. Regression tests cover both. Existing damaged checkpoints may require
one real application repaint; the patch cannot recreate already-discarded bytes.
Remote source correction is not a claim that existing durable workers were upgraded.

Installed follow-up hash: c19dd533eeeba225613df06d2841dfba7ae63142629292a59d60c1b2ccf266f8.
Ten focused native tests and the Go daemon suite passed. After installation,
PanBarley restored complete Codex recap/composer and Claude transcript/status
without resizing. Switching to Rice and back also preserved the repaired view.
This is a relaunch/tab-resume pass, not a forced network-loss stress test.

## Follow-up: intermittent remote-agent stalls

The user reports freezes while working in dandy-07 Claude/Codex panes. Live
sampling of Relay PID 94400 did not capture a main-thread hang. The performance
panel showed approximately 7 ms transport RTT, no loss, no queue pressure and
one recorded UI stall (not attributed by that panel). This does not rule out
intermittent hangs.

A source-level regression was found: the viewport presentation barrier reused
the replay-compaction predicate. That predicate now correctly requires a
self-contained clear before discarding history, but differential synchronized
repaints are safe to present over the retained grid. Requiring the clear there
can hold an otherwise completed update until the five-second fallback. The
presentation predicate now recognizes a completed synchronized update separately;
the stricter replay predicate remains unchanged. Three targeted regression tests
pass. This patch is not yet installed or accepted against the user's symptom.

Current affected pane: bridge / Codex / 6af7524c-3463-456d-a304-3177bd6f8c8a.
Two native viewport reads showed new output and a timer advancing from 57m36s
to 58m02s, while retaining stray bottom content. Thus stream delivery and parser
updates were continuing during this observation. Computer control became stuck
on stale Diagnostics-menu accessibility state and could not provide a fresh
screenshot; the user was asked to dismiss it. No input, resize or restart was
sent to this affected agent during that capture.

Installed follow-up, 2026-09-22: computer control recovered. Before restarting,
the bridge Codex screenshot showed no composer and a lone `54` at the bottom.
Installed the presentation-barrier correction, strict signature check passed,
and all three targeted regression tests passed again. Relaunch alone preserved
the already-damaged frame. Zoom then restore repainted the composer/status line;
switching to Rice and back retained it and the transcript wrapping settled.
No commands or keystrokes were sent to either remote agent, and their processes
were not restarted. This proves installed zoom/restore/tab-switch behaviour,
not that every intermittent freeze or reconnect defect is solved.
Binary SHA-256: `4870d8fb6d08ca61cf7727ad2add9a705b395d1b463f7ef08c366c126d48c7ad`.

### Reconnect retained-grid fix, 2026-09-22

Further source inspection qualifies the presentation-barrier diagnosis above:
the current normal viewport commit finishes presentation directly; the fallback
barrier helpers have no production callers. The predicate correction therefore
does not establish the cause of the reported five-second stalls.

The active reconnect path did reset an already-live parser and rebuild it from
a bounded, compacted ANSI cache. Cursor-addressed deltas and alternate-screen
exit sequences cannot safely recover missing primary-screen state that way.
After the first committed replay, modern event-cursor reconnects now retain the
live grid and append only missed output. Initial attach, worker downgrade, and
explicit history resets still use reconstruction. Replay generation checks and
ordered live-tail commits are retained.

Eleven targeted tests pass, including a TerminalIOBridge regression asserting
exact delta delivery across alternate-screen exit and cursor-addressed updates,
and reconstruction after an explicit history reset. Installed visual acceptance
is separate from these automated results.

Installed and relaunched this build; strict app signature verification passed.
Binary SHA-256: `c30fb71f860e7bc4deb496c6bc5aa29cd7d832b83d81f2f2545e1e9ec0d397d1`.
Computer-control inspection of bridge showed both Claude and Codex composers.
Zooming Codex and restoring the split retained both composers, but left visible
wrapping/stray-column artifacts in older Codex transcript lines. This is NOT a
full redraw acceptance pass. No commands were injected into research panes and
no remote agent was terminated. A live forced network outage was not performed;
reconnect delta correctness is covered by the automated bridge test above.

### Broader stream and engine fixes, 2026-09-22

Four further paths were corrected:

- AppKit-predicted dimensions no longer overwrite the engine-confirmed grid.
  Remote explicit repaint waits for the matching engine resize callback.
- Hidden tabs keep parsing; only drawing and snapshot cadence pause. Removed
  the deferred-buffer reconstruction path that could lose primary-screen state.
- Live display bursts are no longer truncated using the snapshot-cache policy.
  The parser receives original bytes, without packet-local hyperlink rewriting
  that could inject OSC inside a control string split across packets.
- In the local libghostty-spm dependency, TerminalController.handleWakeup always
  drains the shared app mailbox before applying presentation visibility gates.
  The newest detached pane must not block other panes' IO progress.

22 targeted tests passed, including a real Ghostty surface test for hidden
alternate-screen exit, reconnect, and a detached second pane sharing a controller.
The latter is being strengthened with 4,096 distinct title events and rerun before
the next install. Changes to the dependency are local and must travel with the
Relay build; no dependency release or public push has been made.

The strengthened test with 4,096 distinct title events passed. Built, installed,
and reopened Relay; strict signature verification passed. Installed SHA-256:
`beed7be40405ce1ca0f8f96700ed80dd8b1f155720b2d72db6d81752184f8f63`.

Manual check: bridge Codex zoom/restore, switch to Rice, then return to bridge.
Both Claude and Codex composers remained visible and the previously observed
stray-column artifacts were not present in these captures. Computer control had
one noWindowsAvailable coordinate failure; accessibility-based tab switching
worked. No commands were injected into existing agents or research shells.

Checkpoint: these stream/engine fixes are installed and the bounded manual check
passed. Prolonged real SSH interruption and a freshly launched interactive-agent
stress fixture have not been exercised in this pass. The previous transcript is
not reconstructible from repaint alone. Further validation must distinguish
historical saved damage from newly produced corruption. No public push made.

### Installed remote fixture acceptance

Ran a disposable Python TUI in a new dandy-07 test tab, pane
`500b4d72-5aee-4a83-a063-e533f5a70c9f`. It entered alternate screen,
painted top/bottom markers, handled SIGWINCH, and updated a counter in place.
Splitting the tab changed its reported viewport from 184x56 to 90x56 with
correct marker placement. Restarted only the Relay client while the fixture
continued remotely: after reconnect its counter had advanced to 000766 and
both markers were intact. Typed q to exit; screenshot and native viewport
confirmed the original shell sentinel, RELAY_REDRAW_EXIT_OK, and shell prompt,
with no live counter or bottom marker remaining. No research-agent input or
termination was performed. This proves client restart/reconnect, not a prolonged
VPN/network outage. UI zoom clicks were intermittently blocked by computer
control (noWindowsAvailable/invalidated elements); the split resize did work.
