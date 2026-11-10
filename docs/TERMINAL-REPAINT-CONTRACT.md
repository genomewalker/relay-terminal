# Terminal repaint contract (0.5.57)

## The problem

Panes sometimes showed garbled text: fragments of old frames, or rows that did
not match the terminal. Resizing the pane always fixed it. The terminal state
was correct throughout: every visible pane's worker size matched its drawn grid,
and the text grid that `relay_read_viewport` returns was clean. Only the pixels
were stale.

## What Ghostty guarantees

Checked against upstream Ghostty at the vendored commit
`332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.

- `ghostty_surface_refresh` → `refreshCallback` → `queueRender`. This only wakes
  the renderer thread. It does not force anything to be rebuilt.
- The renderer thread's `renderCallback` runs `updateFrame`, then `drawFrame`.
  `updateFrame` runs even when the surface is occluded; only `drawFrame` is
  skipped (`if (!self.flags.visible) return`).
- `terminal/render.zig` `RenderState.update` redraws the whole viewport only
  when one of these holds:
  - the active screen changed;
  - any terminal-wide dirty flag is set (`palette`, `reverse_colors`, `clear`,
    `preedit`);
  - the screen's dirty flags are set;
  - the rows or columns changed;
  - the viewport pin moved.

  Otherwise it rebuilds only rows whose page or row dirty bit is set, and
  clears those bits as it goes.
- `renderer/generic.zig` `rebuildCells` resets every cell only when
  `state.dirty == .full` or the grid size changed. Otherwise it skips each row
  that is not dirty.
- `ghostty_surface_draw` → `drawFrame(true)`. It draws the frame data as it is
  now; if nothing was rebuilt it presents the last target again.
- Who draws output: the renderer thread draws on its own after each rebuild.
  - A pane without focus is drawn on change: `hasVsync()` is false while the
    renderer's display link is stopped.
  - The focused pane is drawn by the renderer's own display link.
  - Nothing calls back into Swift. On a real surface (probe on the vendored
    binary), output, `refresh()` and an empty preedit produced no `render`
    action and no app wakeup.
  - Relay's display-link tick (`controller.tick()` + `draw()`) is an extra
    main-thread draw, mainly for input, resize and presentation.

So a row whose dirty bit is lost, or whose rebuild races a presentation change,
stays stale until something forces a full redraw. A resize does that through the
grid-size check, which is why resizing always fixed the garble.

**The full-rebuild lever.** `Surface.preeditCallback` always sets
`terminal.flags.dirty.preedit = true`, then queues a render. Called with no
text and no composition open, it does nothing else: it clears the selection
only when a preedit existed or text is given. So `ghostty_surface_preedit(s, "", 0)`
forces the same full rebuild a resize does, without changing the size and
without sending anything to the program. Relay's native patch does not touch
preedit. The lever is unsafe while an IME composition is open, so it waits
until the composition ends.

Other options considered:
- `ghostty_surface_update_config` also marks everything dirty. It also rebuilds
  the font grid, drops key sequences and reconfigures termio, so it is too
  heavy to use on every transition.
- A small native patch exporting `markDirty` would be the clean long-term lever.
  It needs the Zig 0.15.2 toolchain to rebuild the xcframework, which is not
  installed. That is left for a later release.

## The contract

1. **Exact change.** Output repaints only the rows it damaged. This is unchanged:
   Ghostty's dirty-row rebuild plus Relay's `draw()`-only display-link tick.
2. **Full repaint on transitions.** `TerminalSurfaceCoordinator.requestFullRepaint(reason)`
   is the single entry point. It marks the viewport fully dirty and arms a
   frame.
   - It is never downgraded to the 250 ms cursor-animation tick.
   - It runs after any occlusion change the caller made.
   - If the pane cannot draw (hidden, inactive, mid-inspection) or an IME
     composition is open, the repaint is *owed*. The next frame that can apply
     it redeems it.
   - Requests closer together than 1/120 s share one rebuild, and the rest is
     redeemed by the next frame.
3. **Settle (self-heal).** After output has been quiet for 300 ms, or every 2 s
   under continuous output, a visible pane gets one full rebuild. Because
   Ghostty never reports output to Swift, the settle subscribes to the
   session's `parsedHostOutputEvents()`: one coalesced event per parsed batch. Any row that
   escaped rule 1 is then stale for at most that long, not until the next
   resize.
   - A full rebuild produces no host output, so it cannot trigger another
     settle through that path. Ticks driven by layout, focus or title changes
     also count as damage; any of those within 0.5 s of a full rebuild is
     ignored, so the settle can never trigger itself.
   - Cursor-blink requests arrive inside a frame and never schedule a settle,
     so an idle pane does not repaint repeatedly.

## Where each transition enters

| Transition | Entry point | Before 0.5.57 |
|---|---|---|
| Size | `AppTerminalView.setFrameSize` when the size really changed (`.size`), plus a trailing repaint 150 ms later for the resize throttle's last size | grid rebuild only when rows/columns changed |
| Scale / screen | `viewDidChangeBackingProperties`, `windowDidChangeScreen` (`.scale`, with trailing) | tick only |
| Scroll | `scrollWheel`, `scrollToRow`, `jumpToPrompt` (`.scroll`) | none from the view; relied on Ghostty's viewport-pin redraw |
| Replay / presentation | `synchronizeAndRenderImmediately` (`.replay`), used by TerminalRuntime after an attach replay and when a pane is presented or resumed | `refresh()` (renderer wakeup only) |
| Visibility | coordinator `setDisplayVisible(true)`, `setApplicationActive(true)` (`.visibility`) | tick only, no rebuild |
| Attach | `viewDidMoveToWindow` with a window (`.attach`) | tick only |
| Width inspection end | `finishViewportInspection` (`.inspection`) | tick only |
| Output | unchanged (exact change) plus the settle (`.settle`) | exact change only |

TerminalRuntime's presentation epochs, the atomic-resize cover and the replay
ordering are not changed. They reach the contract through the existing
`synchronizeAndRedraw`, `setSurfaceVisible` and `scrollToRow` calls.

## Diagnostics

`AppTerminalView.repaintStatistics` counts the following, and `summary` formats them on one line:
- requests by reason;
- rebuilds applied;
- repaints owed;
- repaints held while an IME composition was open;
- render requests deferred as cursor animation (`deferredAsAnimation`). A high
  count while output streams would point to the "not smooth" half of the
  report.

The applied and requested events are also logged under `TerminalDebugLog`
category `.render`.

## What 0.5.57 guarantees and what it doesn't

- **Guaranteed:** every transition in the table rebuilds and draws every row
  within one frame, or as soon as the pane can draw. Any stale row heals within
  0.3 s of quiet, or within 2 s under continuous output.
- **Not guaranteed:**
  - Why a row's damage is lost in the first place is still unknown. The settle
    hides it within that window but does not explain it.
  - If a garble still lasts longer than 2 s on 0.5.57, it is not a stale cell
    buffer. It would be a presentation problem: the layer showing an old
    drawable, or a wrong contents scale. Note the pane, the time and whether
    the garble outlasted 2 s, before resizing. `repaintStatistics` is not yet
    shown anywhere in Relay; adding it to the Performance panel is planned
    for 0.5.58.

## Tests

`Tests/RelayTests/TerminalRepaintContractTests.swift`:
- The policy rules.
- On a real offscreen Ghostty surface:
  - the lever sends no bytes to the session and keeps the screen and the selection;
  - a hidden pane owes the repaint and redeems it on show;
  - an open composition defers the repaint;
  - real session output schedules exactly one settle, and a quiet pane is not
    rebuilt again;
  - requests within one frame coalesce;
  - the settle fires once and does not trigger itself;
  - size and scroll transitions request a full repaint.
