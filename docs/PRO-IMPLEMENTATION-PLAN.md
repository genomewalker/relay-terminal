# Pro migration implementation plan

## Pro source review — 22 September

Cache correction: results now carry original plugin/digest/operation/scope/resource
and request identity. Hidden presenters invalidate cache visibility; reopening
authorizes the original stamp before display, and exports use that stamp rather
than the current picker metadata. Display also requires matching enabled tool
metadata and scope. Added owner/reopen/stale-stamp regression. Injected sessions
are observed rather than StateObject-captured, avoiding stale injected identity.
Still required: installed revocation tests, active store-change propagation,
operation receipts independent of display, and the full Stage B native gates.

Review received against the four source files, three tests and legacy screenshots.
Do not embed/install the dock yet. Priority order: cancellation at effect/commit
boundaries; stamped protected-cache revalidation; owner-only observers/dialogs;
opening-command capture and immutable reviewed requests; retained outcome owner
and request-scoped retry state; transfer lifetime; active presentation lease.
Full review remains in the existing Pro conversation.

Second correction slice: refused wrappers no longer mount shared controls,
dialogs or selection observers; a presenter-ID-checked session transition clears
previews and obsolete transfer state without consuming another owner's job ID.
The toolbar captures pane/profile/directory synchronously before opening the
sheet. Confirmation compares an immutable reviewed payload/scope/digest with
the current request and rejects changes. Unit regressions cover refused-owner
selection and reviewed payload/revision mismatch. Protected-cache provenance,
retained outcomes and transfer lifetime still need their own acceptance gates.

First correction: suspension now removes the active read lease independently of
saved dock visibility; only explicit resume/reveal restores it. Regression covers
blocked new reads, invalid old tickets, no hidden follow, and hidden resume.
Added cancellation checks after authorization before dispatch/UI effects and
before read-result publication. These checks are not full request-ticket/cache
validation, detached-task cancellation or retained mutation-outcome acceptance.
Those remain required before dock wiring. No installed app changed.

Scope: Addendum A1 and Revision 2, with later user overrides recorded in
PRO-MIGRATION.md. No unrelated API/backend expansion.

1. **Ownership foundation:** inspect canvas/native lifecycle, persistence and
   plugin operation ownership. Add small per-tab captured-context state and
   stale-read tickets. Unit tests before presentation wiring.
2. **Operation lifetime extraction:** move existing PluginToolsView request,
   draft and result ownership into one captured presentation session. Preserve
   manager/store/executor checks; distinguish view reads from dispatched work.
3. **Shared host:** retained canvas with sibling collapsible dock; guarded
   reveal/focus, one unchanged tool, legacy wrapper using the same session.
4. **Persistence/isolation:** inspect actual codec; add compatible presentation
   persistence and rollback tests. Establish isolated app state before candidate
   installation. No second app against production preferences/plugin stores.
5. **Installed Stage B acceptance:** AT-B01–12; native lifecycle/focus, read
   cancellation/revocation, operation continuity, layout, MCP preconditions,
   saved preferences, accessibility, full-suite and performance baselines.
6. **Migrate capability surfaces:** Files/Artifacts/Transfers → Changes →
   Jobs/Actions → R → Network/activity. Reuse execution paths and validate each
   installed surface before retiring its legacy entrance.

## First source findings and checkpoint

- WorkspaceView currently constructs the selected WorkspaceCanvas and keeps it
  mounted underneath Network using opacity/hit-testing/accessibility state.
  Preserve this ownership seam; inspect native host dismantling before changing.
- PluginToolsView stores its Task and drafts/results in SwiftUI state, and
  cancels the task on disappearance. Blind dock embedding is unsafe for dispatched
  operation lifetime. Extract ownership before using it as dock content.
- Workspace persistence currently serializes TabSnapshot/PaneSnapshot through
  persistWorkspaceNow. No new schema or sidecar is assumed yet.
- Added WorkspaceChrome as a lazy, nonpublished per-tab object with captured
  anchor, explicit follow mode, draft freeze, visibility epoch and latest-read
  tickets. It contains no grants or operation callbacks. Not wired to UI yet.
- 100 unit-state cycles are NOT the native 100-cycle input/render acceptance.
  The installed app and saved layout are unchanged by this foundation slice.

### Operation-lifetime extraction, first increment

PluginToolsView now uses PluginPresentationOperation for its existing helper
task. Hiding/Done cancels view reads, not mutation waits; explicit Cancel retains
existing cancellation/unknown-outcome handling. The owner retains itself until
completion and rejects overlapping starts. Existing executor/store checks remain.
Four focused context/lifetime tests pass. Not installed.

Still required before dock embedding: extract draft/result state and retained
receipt presentation, share one presenter per context, cover nested transfer
lifetime, then wire the stable dock. This helper alone is not complete operation
history or installed lifetime acceptance.

### Retained presentation extraction

Draft/result fields now live in PluginToolPresentation with its operation owner;
the existing view accepts an injected presentation while preserving its legacy
initializer. Capture occurs once, and presenter IDs prevent two wrappers from
dispatching through the same presentation simultaneously. A nonowner cannot
release another presenter's claim. Existing view action methods still own the
execution path; no duplicate executor added. Tests cover draft/capture retention
and presenter exclusion. Not installed or dock-wired. A per-context owner and
reveal-existing routing, protected-result revalidation on reopen, nested transfer
lifetime and extraction of non-view callbacks still precede installed dock parity.
