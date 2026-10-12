# Agentic R workspace

Design specification, 21 September 2026. Proposed, not installed acceptance.
Extends [the workspace contract](WORKSPACE-DESIGN.md). RStudio source research
is a separate prerequisite for the plotting implementation; this document does
not claim that research or plotting parity is complete.

## Direction

An analysis bench, not a dashboard and not a chat window with a terminal attached.
The user watches results, asks for work, edits code and can always use R directly.
Agents work in the same explicitly bound R session. Local and remote work use
the same presentation; the host is always visible.

Use the existing native Relay chrome. No new plugin window, floating control
palette, setup toolbar or nested collection of cards. The memorable surface is
the figure or table itself. Activity explains it without competing with it.

## Layout

Default at a usable desktop width (dimensions exclude the existing sidebar):

```text
┌ barley-analysis     dandy-07 / pan-barley       R: Ready     ⋯ ┐
│ analysis.R                         │ Plots  Objects  Data  Help│
│                                    │                          │
│ Editor                             │                          │
│                         Run ▷      │     Figure / data        │
│                                    │                          │
├ Console ───────────────────────────┤                          │
│ > plot(1)                          │                          │
│                                    │ ‹  3 of 8  ›   Follow    │
├ Activity: Codex running PCA…          2 queued       Pause  ■ ┤
│ Ask agents…                                       Send       │
└──────────────────────────────────────────────────────────────┘
```

Start with 58% editor/console, 42% results. Editor takes 60% of the left column;
splitters are adjustable and persisted per tab. Minimum column widths: 420 and
320 points. Below 780 points of content width, results become a selectable
destination, retaining console state and an explicit return action. Never shrink
the terminal into an unusable strip. Account for enlarged text before applying
these thresholds.

Observe mode is an explicit layout action: collapse the editor, expand results,
retain a usable console and the activity strip. Edit restores prior split ratios.
Incoming plots do not switch modes, select tabs or move panes. Applying this
layout preserves all existing sessions; unrelated agent panes may be minimized
only through an explicit layout preview. No replacement R process.

## Visual tokens

Use native semantic colours in production; these light-appearance reference
values communicate the intended hierarchy, not hard-coded overrides:

| Role | Reference | Application |
| --- | --- | --- |
| Canvas | #FFFFFF | Editor, terminal and result surface |
| Chrome | #F5F5F7 | Toolbars and activity strip |
| Separator | #D8D8DC | One boundary between regions, no card borders |
| Primary text | #202124 | Content and labels |
| Secondary text | #62666D | Metadata with verified contrast |
| Accent | #0067C0 | Selection, focus and primary action |

SF system text for controls, 13-point regular with 11–12-point secondary text;
user-configured monospaced fonts for code and console. No all-caps labels,
decorative gradients, agent avatars or constantly pulsing status lights.
Spacing is 4/8/12/16/24 points. Use SF Symbols for familiar toolbar actions,
with tooltips and accessible names; keep words for ambiguous actions and states.
Icon targets are at least 28 points, even when the glyph is small.
Follow system dark appearance, contrast and reduced-motion preferences.

Critique against the brief: a permanent agent chat column would compete with
plots and repeat the session network UI. Use the compact activity strip with an
expandable run log instead. A four-quadrant IDE would crowd small windows; use
one results destination with contextual tabs instead of an always-visible object
panel stacked above an always-visible plot panel.

## Three input paths, one identified session

- Console: normal R/radian input; never reinterpret typed R as an agent prompt.
- Editor: Run sends selection, or the current executable unit when there is no
  selection. Show which behaviour is supported; do not claim expression parsing
  until implemented. Keyboard shortcut and button dispatch the same action.
- Ask agents: natural-language composer labelled as agent input, with an explicit
  recipient/group selector when more than one is available. This is not an R prompt.

The host/project/session target is captured on submission, not taken from later
focus. Switching panes cannot retarget queued work. Results identify the producing
session and run; console-originated results are labelled Console, not credited
to the last active agent.

Managed editor/agent requests need a single-writer broker and durable receipts.
Direct PTY input is NOT automatically part of that queue: until prompt/busy and
input-ownership integration is verified, Relay must not advertise serialized
human/agent execution. Fail closed for automatic agent dispatch on unknown or
busy state. Never inject agent code into a partially typed console line.
Taking control pauses future agent dispatch; interrupting the current R command
is a separate explicit action, whose outcome may be unknown after disconnect.

## Results

Plots fill the content area with aspect-preserving rendering. A quiet footer has
previous/next, history position and Follow latest. Zoom/export sit in the result
toolbar. Selecting an older plot disables following; new plots increment an
unseen count instead of jumping the user forward. Resize re-renders the device
display list, never re-executes analysis code. Preserve the last valid figure
while rendering; show it as stale on disconnection. No blank flashing on resize.

Objects shows searchable rows: name, type, dimensions and approximate size only
when cheaply available. Do not force promises or active bindings for previews.
Selecting an inspectable object opens Data; lazy/custom evaluation needs an
explicit action. No typing object names into a separate setup form.

Data uses a bounded, source-paged grid with sticky headings, row numbers, type
indicators, visible truncation and copy/export actions. List columns expand on
demand. Never send a whole dataframe to an agent by default. Replaced objects
invalidate old page cursors instead of mixing versions.

Help opens contextually from editor/object actions and retains a search field.
Saved files and device configuration belong in the options disclosure, not the
main result toolbar. Automatic updates must be backed by real events/versioned
snapshots; a Refresh control is recovery, not the normal workflow.

## Agent work and control

The collapsed activity strip shows one truthful current operation and queue
count. Expand it for the task checklist, code, actor, timestamps, output and
receipts. A checklist is not provider plan mode. Missing provider state reads
Unknown; transport delivery is not task completion.

Pause stops admission of future agent requests. Stop targets the bound active
evaluation, not every agent/process. Keep both available while work runs.
The user can edit the task, inspect proposed code or take over without opening
Network. Network remains the place to configure collaborators.

Reusable autonomy requires a separately implemented, revocable workspace grant:
session/host, permitted actions, file roots, limits and expiry. Show its scope in
one concise review. Within a valid grant, routine permitted evaluations should
not cause repeated confirmation sheets. Package installation, external effects
and scope expansion are separate decisions. Until the grant and broker are
implemented and tested, existing approvals stay in force.

## Setup and failure states

R plugin installation owns dependency detection and versioned companion setup
for the selected local/remote environment. Inspect first; show the exact changes
before installing missing packages. Do not overwrite user profiles or inject a
wall of source into an arbitrary live prompt. Previously configured, verified
sessions can reconnect automatically without rerunning user code.

Use one inline state per affected surface:

| State | Presentation and action |
| --- | --- |
| Not configured | Set up R workspace; environment and host named |
| Connecting | Keep prior results visible; no execution enabled |
| Ready | Quiet state in context header |
| Busy | Active operation and available interrupt |
| Disconnected | Last results retained with last-seen time; reconnect |
| Session replaced | Explicitly choose new session; old results stay attributed |
| Unknown execution outcome | Inspect receipt/session; never automatically rerun |

Credentials, forwarding ports and artifact paths stay in diagnostics. A valid
saved handshake alone is not liveness. SSH recovery validates process identity,
device generation and credentials before resuming observations.

## Delivery and acceptance

Implement shared context and presentation first; do not fake automatic behaviour
to make the mockup appear complete. Then integrate setup, execution arbitration,
event-backed results and scoped autonomy behind their own tested capabilities.
The RStudio plotting source study must precede choosing missing device features.

Installed-build acceptance must cover local R and dandy-07 radian:

1. Run plot(1) manually, from the editor and through an authorized agent. Each
   appears without manual file browsing; source attribution is correct.
2. Inspect an older plot during incoming output: no jump or focus theft.
3. Resize/maximize/restore repeatedly: figure, console, splitter positions and
   selected result survive; no analysis code is rerun.
4. Type a console draft while agent work is queued: draft unchanged, no interleaved
   code. Pause, interrupt and take-over have distinct verified effects.
5. Drop SSH during evaluation: stale view, unknown outcome, no duplicate run;
   reconnect to the same session or explicitly handle its replacement.
6. Inspect a large tibble, a list column, a lazy object and a replaced object:
   bounded reads, no accidental evaluation, no mixed pages.
7. Verify narrow/light/dark layouts, keyboard-only use, VoiceOver, visible focus
   and reduced motion. Results updates never seize keyboard focus.
8. Measure idle and busy CPU, wakeups, memory and typing latency against baseline;
   hidden views cancel rendering requests, not terminal data ingestion.

Record build identity and pass/fail evidence. A design document, source tests or
an HTML preview cannot substitute for installed-app validation.
