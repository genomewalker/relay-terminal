# Pro migration — priority contract

Status: migration in progress; not completed or accepted.
User directive, 22 September 2026: complete the Pro migration before unrelated
feature expansion. Pause MCP feature expansion and additional plugin features.
Preserve existing work and address correctness defects that block migration.

## Source and precedence

Original review: https://chatgpt.com/c/6ab013e8-f18c-83eb-b9d5-b70609c79cc5
Use **Revision 2.0**, not the first response. Sections 3–4 and the staged
acceptance sequence were reread from the sidebar browser on 22 September.
The full revision still needs a section-by-section traceability pass before
claiming reconciliation is complete. WORKSPACE-DESIGN.md remains the existing
implementation record; historical claims are not acceptance of a new build.

User instructions after that review override its earlier recommendations:
human Cmd+Enter in a bound R editor is direct, not agent submission; icons are
preferred for familiar actions, but context destinations, ambiguous actions,
permission reviews and meaningful states retain labels.

## Binding decisions

- One workspace sidebar, stable tab/pane identities, optional per-tab dock.
- Primary contextual entrances: Context → Files / Changes / Jobs. Project
  actions belong in Actions; R workspace belongs in Layout; agent activity
  belongs in Network participant details. No extra plugin tree.
- Capture context on open. Follow Active Pane is explicit browsing only.
  Pending operations never retarget on focus or navigation changes.
- Reveal and focus are separate operations. Preserve existing terminal/editor
  controllers while changing presentation; no process launch in view appearance.
- Participants/List is the Network default; map is an alternate supported view,
  not an excuse to remove working functionality or fabricate discovery evidence.
- Semantic colours, system type, shared 4/8/12/16/24 spacing, accessible actions.
  Preserve user terminal colours/fonts. Compact changes padding, not readability.
- Existing host grouping remains until explicit reversible migration. Never
  merge by display name, move tabs silently, or discard drafts/layouts.
- Keep operation permission checks, plugin bounds and concurrency limits.
  Navigation simplification is not permission expansion.
- Legacy entry points remain until installed replacements pass acceptance.

## Delivery sequence

| Stage | Deliverable | Gate |
| --- | --- | --- |
| A | Full revision traceability, current surface inventory and baseline | Every requirement mapped to existing code, gap, or explicit later dependency |
| B | Shared tokens, captured context, focus rules, per-tab dock around retained controllers | 100 reveal/hide/tab-switch cycles; no input/selection/identity loss or retargeting |
| C | Files/Artifacts/Transfers, then Changes and selected-file diff | Existing bounds, permissions and failure cases; local/SSH installed parity |
| D | Jobs and Actions on shared surfaces | Owned scope, exact target, cancellation/unknown outcomes, no replay |
| E | R layout/environment/results/help on shared surfaces | Existing process/objects retained; local and remote human/agent workflow |
| F | Network/activity consistency and independent route states | Exact addresses, coverage and real disconnect/recovery evidence |
| G | Remove verified duplicate navigation; saved-layout migration | Recoverable snapshot, compatibility and rollback tests |

Do not treat all source additions as shipped. Each stage records code, component
tests, installed build identity, visual/manual acceptance and rollback separately.
No production-ready claim until terminal failures and the full acceptance matrix
are resolved. Capture normal/narrow widths, light/dark, keyboard/VoiceOver and
measured performance versus baseline. Do not install an unfinished migration over
the working app merely because it compiles.

## Current checkpoint

### Implementation Addendum A1 — read in full

The completed 22 September addendum (33,016 characters) was read in full from
the original Pro conversation. It is advice grounded in our reported state,
not an independent inspection of current code. Its binding implementation
corrections are:

- Preserve existing Map and saved view preferences; List is the unset default.
- Stable PaneModel identity does not prove native view/controller/core lifetime.
  Inspect make/update/dismantle and focus before altering host composition.
- Small per-tab chrome state belongs to existing ownership; no publishing a
  global chrome dictionary or instantiating seven heavy tool sessions per tab.
- Binding revision and presentation epoch reject superseded view reads but are
  not authorization, transport generation or process incarnation.
- Keep one retained canvas host beside one collapsible dock host. Never create
  separate terminal branches keyed by dock visibility or selected capability.
- Reveal preserves focus; deliberate Focus Dock is distinct. Deferred focus
  restoration is guarded against later user input and is attempted once.
- Extract PluginToolsView operation-facing state once, reusable content second,
  legacy/dock wrappers last. One active presenter per tool/context; no duplicate
  helpers, approvals, saves or permission implementations.
- Hiding a dock cancels view-only reads, not already dispatched operations.
  Extract operation/receipt ownership before embedding a view that owns both.
- Inspect the real workspace codec before persistence changes. Prefer a safe
  existing extension; otherwise a versioned sidecar coordinated with the base
  save and fingerprinted to its exact bytes. Two files are not an atomic save.
  Reject mismatched/unknown overlays without losing the base or overwriting them.
- Distinguish feature rollback, existing run-scoped arrangement restore and
  binary rollback. Never restore an old base automatically over new tabs.
- Human Cmd+Enter uses authoritative live editor capture and exact binding,
  not the lagging MCP mirror. MCP cannot assert human provenance.

Acceptance IDs AT-B01–12 cover retained lifecycle over 100 cycles, immutable
context, follow freeze, stale/revoked results, presenter dedup, retained dispatched
operations, guarded focus, geometry, MCP revalidation, persistence failures,
Map preference preservation and seven-plugin accessibility/width checks.

Gates: G0 source/full-suite baseline; G1 separately isolated installed candidate
and disposable state; G2 per-surface installed acceptance; G3 integrated retirement
of duplicate entrances. Do not run a second candidate against production state.
Long real SSH outage remains separate from the passed bounded remote TUI test.

Next source review: ownership/navigation/save/load, native terminal host lifecycle,
PluginToolsView and its scope/authorization/cancellation/result interfaces, a
sanitized layout fixture, and MCP workspace dispatch. First implementation target
is Stage B plus one unchanged embedded tool, not the whole migration at once.

Existing implementation has partial shared Network navigation and icon actions,
but lacks the complete contextual dock/navigation migration. Recent editor-read
and plugin-inventory MCP additions are tested source work, not yet installed;
leave them intact but do not expand that stream ahead of this migration.

Next action: finish reading Revision 2, map its requirement matrix and existing
shell/context ownership, then implement Stage B as one reversible slice. No
wholesale rewrite, no unrelated new harness/federation/website features.
