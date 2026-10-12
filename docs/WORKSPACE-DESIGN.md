# Relay workspace design specification

## Shared conversation identities — 21 September 2026

A resumed conversation can have two live processes. A unique verified pane
binding plus PID/process-start identifies the selected instance; another pane
sharing the conversation ID no longer blocks it. Conflicting explicit pane
ownership cannot be overridden by process-root fallback. Multiple matches in
the same pane still block selection. The captured process, name and session
are checked again against fresh discovery before review and at send time.
Graph nodes for shared conversations retain separate pane identities rather
than merging their links; conversation-only edge reports are not assigned to
either instance. The inspector displays the real session ID and process.

## Native group reply and broadcast repair — 21 September 2026

Introductions advertise native peer names, not socket URLs as tool recipients.
Same-host native groups now install `~/.local/share/relay/native-group.py` on
their host. Its explicit `--send GROUP --sender SESSION --message-id UUID`
operation reads message text from stdin and sends to all permitted neighbours
(all other members for everyone topology; the configured star for coordinator).
Private replies are not intercepted or forwarded. This helper is not yet a
cross-host group transport or a native provider group tool.

Membership and process identity are revalidated. Private per-message receipts
are fsynced before writes, record partial failures separately, and prevent
replaying the same UUID; conflicting payload reuse is rejected. Same-UID local
processes are the security boundary, not the caller-supplied sender field.
Unknown outcomes are not retried, and socket writes are not model acknowledgements.

Eleven native tests and seven desktop-group tests pass, including three-member
fan-out, partial failure, duplicate suppression and replaced-process rejection.
Two bounded live repair notices for group 1b0d32cb-bc42-41a2-80ae-f94819f5c1b6
recorded successful writes from Codex to Rice/bridge and Rice to Codex/bridge;
the text explicitly identified them as Relay coordinator transport tests, not
new work assigned by those sessions. No model acknowledgement was requested.

## Pane selection appearance — 21 September 2026

Selection uses the existing 2-point pane corner radius, a 1.5-point accent
outline, a 3.5% accent tint and a small header-corner checkmark. Unselected panes
retain their normal appearance; hover adds a neutral 1-point outline. There are
no large overlay labels, dark scrims, animations or terminal-size changes.
The usual active-pane rail is hidden while linking to avoid competing states.
A compact count beside the toolbar link icon follows selection across tabs.
The full-pane hit target still intercepts input during explicit selection mode;
accessibility labels and values describe selection without relying on colour.

## Collaboration setup refinement — 21 September 2026

Directly selected panes proceed to setup as soon as all captured messaging
identities are verified; they are not selected again in a second list. Setup
uses compact session rows with right-aligned hosts, native semantic colours and system
type, a Message/Collaborate segmented choice, and a multiline task field. Pairwise
connections hide topology controls. Review separates connections, task and
working agreement; diagnostics and raw session IDs are not primary content.

Communication-only is the backwards-compatible default. Autonomous mode
requires a nonblank shared task, validated both in Swift and in the transport
before any side effect. All actual native and desktop introduction paths carry
the agreement: coordinate, divide work, review and resolve routine blockers
directly, without acknowledgement loops. Existing permissions remain unchanged;
missing decisions, required approvals and out-of-scope actions require the user.
Receipts preserve the task and agreement. This is a collaboration instruction,
not a scheduler, an acknowledgement or an approval bypass.

Verification: eight native socket tests, seven desktop group tests and five
Swift plan tests passed. The installed app was visually checked through direct
pane selection, mode switching, required-task validation, review and cancellation.
No test task or autonomous introduction was sent to the live sessions.

## Native same-host group delivery — 21 September 2026

Groups whose members are all native sessions on one host now use that host's
existing authenticated Unix sockets directly. The selected PID, process start,
session, name and socket are revalidated; no desktop mailbox or long-running SSH
forwarder is required. Each recipient receives its verified neighbours' native
addresses. No automatic acknowledgement requests or retries are sent.

The host keeps private, fsynced receipts in `.local/state/relay/native-groups`.
An exclusive group ID prevents repeated application; uncertainty is recorded
before socket writes. A socket-written receipt is not model acknowledgement.
Local desktop-to-desktop groups support a mesh or coordinator topology through the private App Server socket. Exact loaded tasks receive collaborator tool output; sends never resume tasks or retry automatically. Cross-host native groups and mixed desktop meshes remain unsupported.
Group receipts do not themselves manufacture a live map edge; that still needs
fresh provider/transport evidence.

Acceptance: five native socket tests passed on macOS and dandy-07, six existing
desktop-group tests and three Swift plan tests passed. Installed UI applied the
user-selected codex-3869443 / opencode-bridge-fb group on dandy-07, with both
recipients recorded as written_to_socket. No agent work was requested.

## Pane-first session connections — 21 September 2026

Primary entry: **Link sessions** beside the host Connect control. This explicitly
enters pane-selection mode: click whole panes, retain selections when switching
tabs, show a checkmark and outline, cap membership at eight, and use Review links
before any dispatch. Escape cancels without messages or routes. Selection mode
blocks terminal keyboard focus and pointer input; editors cannot be selected.
The grouped picker is an alternative and verification step, not a prerequisite
for selecting panes. Raw session identifiers belong in the inspector rather
than every overview card. Network remains an inspection destination.

One connection workflow serves both the terminal and Network. From a terminal
header, “Connect with other sessions…” captures that pane, verifies its current
messaging identity, and opens a picker grouped by tab. Other tabs may contribute
members. Changing terminal focus must not retarget the captured starting pane.
Selection creates no routes and sends no introductions; review and explicit
confirmation remain mandatory. Unsupported transport combinations remain blocked.

Network is primarily inspection: Sessions by default, Map and Connections as
alternate views. Map clicks inspect; there is no separate map-selection mode.
“Connect sessions…” opens the same picker without a starting pane. Low-level
connection management and manual discovery live under Network options, not as
competing primary actions. The workspace Connect button continues to mean host
connection. Group indicators and direct group messaging require verified durable
group state before they can be presented as implemented.

### Website design reference (planned, not implemented)

Use https://try.cloudflare.com/ only as a reference for its simple layout,
spacing, hierarchy and restrained presentation. Do not copy its code, branding,
wording or feature claims. Website work is deferred while the network interaction
is simplified. This does not replace the Pro workspace interaction contract.

## Network acceptance checkpoint — 21 September 2026

Automatic inventory refresh is bounded to known messaging hosts (maximum 16),
with a 20-second success interval and a 60-second failure backoff. Inventory
observations expire after 30 seconds; failure does not renew them. Active-only
is the default, with an explicit offline/history toggle. Discovery does not
send prompts, grant access, create links, or read conversation histories.

The edge model now accepts an explicit source host and renders same-host and
cross-host remote endpoints. Older snapshots retain their local-source meaning.
This rendering support is not automatic provider-edge reporting: the inspected
running remote Codex advertises only `notify_idle` and does not expose topology
introspection. Its previously verified message exchange is not a live-link
heartbeat and must not be inserted as a connected edge. Provider introspection,
incarnation-bound edge discovery, and graph message actions remain unaccepted.

Installed acceptance: automatic discovery populated 25 participant nodes; the
existing live desktop-to-Pan-barley edge opened its correct connection inspector.
The offline/history toggle was off by default. Nine focused Swift tests passed,
as did seven desktop-route Python tests and the Go peernet/helper suites.
Navigation changes clear hidden terminal focus and suppress expanded
terminal-agent subtrees while Network is visible. After reinstalling, manual
accessibility inspection confirmed the agent subtrees disappear in Network,
and selecting the Codex pane returns to the terminal with that terminal as
the focused element. No terminal input was injected during this check.

## Implementation checkpoint — 20 September 2026, shared Network destination

The latest Pro review (§9.1 and §13) keeps Participants/List as the initial
Network view, with Map optional and Connections retained. Network now has a
sidebar entrance and renders in the main workspace instead of requiring a new
window. Connection management is an inline subview with Back to Network.
The legacy Diagnostics window remains during acceptance; it is not the primary
entrance. Existing host/session grouping is deliberately unchanged.

The terminal canvas remains mounted while hidden, with hit testing and
accessibility suppressed. Explicit navigation clears its first responder;
returning through a tab restores the existing controller. A focused regression
test checks that tab, pane identities and pane collection survive navigation.
This does not replace installed typing/selection/IME testing or the 100-cycle
acceptance gate. Thirteen focused tests passed on this source revision; installed
visual acceptance is tracked separately and is not implied by that count.

Remaining design gaps include complete destination-tab identity/persistence,
shared action review for desktop route control and MCP, large-map bounds and
directional evidence, contextual plugin dock consolidation, and the full
accessibility/performance matrix. These are not marked shipped.

Status: proposed v0.1, 2026-09-20. This is a target design, not a claim that the
current application implements it. Review the interaction model before broad UI
migration. Implementation and installed acceptance remain separate gates.

## Problem and goals

Relay has accumulated terminal, editor, R, plugin and agent-network interfaces
with separate entry points and overlapping navigation. Repeated user reports
describe confusing activation, lost panels, incorrect selection and redraws.
Adding a control window for every capability makes that worse.

Relay is a workspace for local and HPC work, with human and agent participants.
The terminal remains a first-class working surface. Features must share context,
navigation and lifecycle rules without requiring users to understand transport.

Goals:

- Reach each enabled capability from its relevant working surface in at most two
  actions, excluding first-use permission review.
- Always identify the host/project and execution target before an operation.
- Preserve sessions, drafts, selection and layout across view changes.
- Provide one place to understand participants and work without conflating
  connectivity, provider activity, task completion or shared-memory state.
- Keep optional features out of the default terminal workflow and idle cost.

Non-goals: replacing every IDE feature, running arbitrary plugin code, silently
  granting agent authority, automatic pane rearrangement, or presenting a
  speculative agent graph as live state.

## Information architecture

| Surface | Responsibility | Not its responsibility |
| --- | --- | --- |
| Workspace sidebar | Workspaces, their tabs, pinned destinations | A second plugin/host navigation tree |
| Tab canvas | Terminals, editors, explicit layouts | Global configuration |
| Context dock | Files, Changes, Jobs, R results as relevant | Independent copies of workspace navigation |
| Network destination | Participants, connections and associated work | Raw transport configuration as the default screen |
| Activity popover | Transfers and operation progress needing attention | Replacing durable operation history |
| Settings | Hosts, plugins, permissions, advanced setup | Routine use of enabled features |
| Diagnostics | Versions, logs, IDs, transport and performance | Primary feature discovery |

A workspace may span several hosts. Every terminal/file/operation retains its
own host and project identity. The sidebar must not imply that a mixed-host
workspace belongs to one machine. Existing host grouping needs an explicit,
reversible migration; do not silently rename or relocate existing tabs.

Show a compact host/project breadcrumb in contextual tools. A view captures its
target when opened; focus changes do not silently retarget a pending operation.
Offer an explicit follow-active-pane action for browsing, never for a pending
mutation. A missing or ambiguous target produces a chooser, not a guess.

## Seven-plugin integration map

Inventory checked against `docs/plugins/*/README.md`; these describe staged
capabilities and limitations, not uniformly verified installed releases.

| Plugin | Normal entry point | Working surface | Boundary retained |
| --- | --- | --- | --- |
| HPC jobs | Context dock: Jobs | Job list, selected job details/logs | Owned-job scope; submit/cancel require separate review; unknown outcome is not failure |
| Artifacts | Files: select a file | Shared preview/editor surface | Bounded previews; no executable HTML; original export distinct from preview |
| Transfers | Files: Download / existing upload action | Shared activity popover and transfer detail | Integrity, overwrite review, source identity; no claim of restart-resume |
| Git review | Context dock: Changes | File list and editor diff | Read-only unless a separately designed permission adds mutations |
| Project actions | Tab action menu / command palette | Reviewed action sheet and output detail | Captured argv, environment, host, directory; no automatic execution/retry |
| Agent activity | Network / selected agent details | Participant task/activity inspector | Observed events only; checklist differs from plan mode; approvals remain authoritative at provider |
| Radian | Tab layout: R workspace | Editor/console plus R context dock | Exact R process binding, opt-in companion, no implicit package install or execution |

Plugin names remain visible in Settings and capability attribution, not as a
mandatory intermediate menu. Do not remove existing access paths until the new
entry point is verified. Features that are disabled may have a contextual setup
entry, but must not fill toolbars with disabled controls.

## Layout and interaction contract

- Default: sidebar and terminal canvas. Context dock is optional, one per tab.
- R workspace: add or reuse an editor beside its console without replacing the
  tab's split tree or minimizing other panes. Environment and Results live in a
  closable context dock; hiding it returns space to the existing pane canvas.
- Applying a layout shows how existing panes will be retained. No session is
  killed, detached or assigned a new execution target by a layout change.
- Minimize a floating pane to the tab's compact restore strip; process continues.
- Tile/cascade are explicit actions. Restore returns to the saved prior geometry.
- Maximize is a presentation change, preserving dock visibility, zoom, selection
  and editor/console association when restored.
- Close view, detach session and terminate process are separate labelled actions.
  Destructive actions identify the affected session and require appropriate review.
- Focus and keyboard routing are visible and deterministic. Terminal selection
  is copy selection, not editable text. Prompt-editing support must be explicitly
  provided by the running shell/agent, not simulated by deleting terminal output.
- Command palette provides a searchable secondary path to the same actions and
  authorization logic. It is not a separate implementation of those actions.

## Network and shared memory

Implementation checkpoint (2026-09-20): Network now defaults to a host-grouped
session list with local registry discovery and observed remote link endpoints.
The Connections view retains the transport inspector. Participant identity is
host + session, not display name; discovery does not grant communication access.
Activity remains explicitly unknown until an activity source is attached. This
is not full remote inventory, swarm orchestration or memory federation. Local
discovery is bounded and refreshed every 15 seconds while the view is mounted;
link snapshots refresh every two seconds. Installed acceptance is tracked
separately from the participant identity and approval tests.

The default view answers: who is present, where are they running, what work is
associated with them, and which links are available? Use a compact participant
list grouped by host; provide topology as an alternative representation of the
same selection and data, not another configuration hierarchy.

Selecting a participant reveals its observed tasks, links, last update and
available actions. Reveal raw IDs, receipts and reconnect counters in Diagnostics.
Show unavailable provider activity as unknown. Transport connected does not mean
agent idle; socket-written does not mean processed; no response does not prove
failure. Offline peers remain identifiable with last-seen time, not apparently live.

Connect/disconnect manage the messaging link, never kill an agent. Starting an
agent, opening its pane and terminating it are distinct future orchestration
operations with explicit scope. Swarm membership and task assignments appear only
when supplied by a supported source, never inferred from proximity or names.

Chitta is project-scoped memory infrastructure. Show synchronization state and
scope only when backed by the implemented interface. Current durable handoff and
federation are pending; do not show healthy sync or promise offline delivery.
Disconnecting SSH must not destroy local work or imply remote processes ended.

## Plugin and component architecture

Plugins contribute capabilities to a small set of host-owned extension points:
context section, file action/preview, tab layout, reviewed operation, participant
detail. This is a proposed extension contract, not an existing manifest API.
Version the schema and reject unsupported contributions visibly.

Use one shared operation context: workspace/tab/pane, host, project, provider
session where relevant, capability and authorization snapshot. Revalidate at
dispatch and display; never derive the target from mutable global focus.

Separate services (transport, files, scheduler, R), state models and presentation.
Views consume scoped state and dispatch typed actions. No SSH construction in
views, no plugin-specific branches spread across sidebar and terminal handlers,
and no singleton owning all workspace/plugin/network state. Extract interfaces
incrementally with tests, not through an unrelated wholesale rewrite.

Shared components: context header, empty/loading/error/stale state, bounded data
table, preview, operation review, progress/receipt, permission explanation and
diagnostics disclosure. All support keyboard navigation and accessibility labels.

Permissions retain current operation-level checks. Installed, enabled and
authorized are different states. Simplifying navigation must not silently broaden
grants. Any reusable grant needs a separately reviewed permission design; current
per-operation approval remains until then. Revocation cancels future access,
does not claim to undo a remote action already dispatched.

## Visual system and performance

Use native macOS semantic colours and system typography, with monospaced text for
code/identifiers only. Shared spacing scale: 4/8/12/16/24; reuse native controls and
focus rings. Colour reinforces a written state, never carries it alone. Avoid
dashboard cards around every field and decorative graph animation.

Inspector/dock reveal should not steal terminal focus. Support reduced motion,
light/dark appearance, keyboard-only use and VoiceOver. At smaller widths collapse
secondary information explicitly; do not hide the execution target.

Views subscribe only while needed; prefer push events, bounded caches and
cancelled hidden-view refresh tasks. Pausing presentation must not discard PTY
data or corrupt terminal state. No background polling merely to decorate badges.
Performance acceptance compares the same recorded terminal workload with plugins
disabled/enabled, including idle CPU, wakeups, memory and typing latency. Set
numeric release budgets from that baseline before performance sign-off.

## Migration and acceptance gates

1. Inventory current entry points and capture baseline screenshots/workflows.
2. Validate low-fidelity default, R, HPC and network layouts at normal/narrow widths.
3. Introduce shared context/components with no behaviour change.
4. Move Files/Artifacts/Transfers and Changes first; retain old entry points during QA.
5. Integrate Jobs, Project actions, R and agent/network views one workflow at a time.
6. Remove duplicate navigation only after installed-app acceptance; migrate saved
   layouts with versioned data and a recoverable previous snapshot.

Required scenarios, all on the installed candidate:

- Local and SSH terminals retain correct input, selection, clipboard and scroll
  after tab switching, resizing, maximizing and layout restoration.
- Enabling all seven plugins adds no mandatory windows and does not rearrange tabs.
- Given a tool for host A, switching focus to B does not change its pending target.
- Given disabled/revoked permission, a visible stale action cannot execute it.
- Given existing R objects, applying/restoring R layout preserves their process;
  configured plot capture displays a console plot without manual file browsing.
- Given an HPC timeout after dispatch, UI shows unknown outcome and no auto retry.
- Given a lost SSH link, terminals and network show accurate independent states;
  reconnect does not duplicate a mutation or manufacture task completion.
- Each plugin is reachable in two actions from its relevant surface after setup.
- Keyboard-only navigation and VoiceOver identify target, action and status.
- No plugin success can waive terminal correctness or unresolved full-suite failures.

Track each gate as not run/pass/fail with build identity and evidence. Historical
screenshots and component tests are not installed acceptance of a new candidate.

## Decisions still requiring validation

### Icon-first workspace chrome

Editor recovery is separate from Save. Each pane/document retains an atomic local
snapshot (including unsaved content and the original file's write precondition)
under Relay's private Application Support directory. Ordinary close flushes the
draft; it does not write the source file. Recent Documents restores closed files
or a selected draft; restored workspace panes recover their own drafts. Separate
panes/hosts never overwrite one another's recovery entries. An externally changed
source must still pass the existing conflict check before Save. If draft storage
fails, retain the existing cancel/discard prompt rather than silently losing edits.
Drafts are local copies, not encrypted backups, and are not automatically pruned.
Reopening currently requires the document's host/file read path to be available;
offline/deleted-file recovery is not yet provided by the UI.

Main-window, pane and results action bars use compact SF Symbols rather than
repeated verb labels. Shared `RelayIconAction` provides a 28-point hit target,
tooltip and VoiceOver name. Keep visible keyboard focus and disabled states;
never communicate selection or failure by colour alone. Use the same symbol
and action name across editor, plots, network and plugin surfaces.

Keep text for session/project identity, meaningful state, errors, first-use setup,
menu entries and confirmation dialogs. Do not turn ambiguous permissions into
unlabelled icons. Overflow menus hold secondary actions; avoid decorative icons
on every row. Results categories remain labelled until icon-only navigation has
passed usability testing. Apply this policy incrementally across the existing
UI, with installed-app checks; the initial implementation covers R result actions
and floating-plot controls, not a completed app-wide migration.

- Confirm workspace-first navigation against existing host-grouped workflows.
- Validate whether users prefer list or topology as the remembered network view.
- Establish measured performance budgets on this Mac and a representative HPC link.
- Finalize Chitta handoff schema with its maintainer before exposing sync controls.

Every new feature must state its context, extension point, lifecycle, permission,
failure behaviour and acceptance scenario here or in a linked feature spec.
Exceptions require a written design decision; a new window is not the default.
