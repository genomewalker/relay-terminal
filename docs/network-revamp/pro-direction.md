# Pro design direction

Source: https://chatgpt.com/c/6ab80353-7330-83ed-8b73-f814581f9944
Completed review, September 26, 2026. This is an implementation summary, not a verbatim transcript.

Use a native connection-first workbench: source list, operational ledger, optional inspector. Destinations: Live network; Sessions & agents; Link groups; Approvals; History. List and Map are representations of Live network, with remembered preference. Fresh launch: all hosts, no restrictive query or filters.

Hosts and all operational transport rows precede messaging routes, with no execution inventory wall above them. Distinguish multiple connection configurations/accounts per host. Routes remain visible without selection. Selection highlights relationships; filtering to related routes requires an explicit removable filter. Preserve route endpoints even when discovery is incomplete.

Map: compact host ownership lanes; remote transport connectors distinct from messaging arrows; bounded map viewport with independently scrolling complete route ledger below it. Dense bundles must expose all their individual ledger records. Ownership is containment, not communication. Team membership does not invent parentage.

Separate broker availability, SSH lifecycle, observation freshness, worker attachment, process activity, agent work and messaging route readiness. Broker loss leaves stale observations rather than fabricating disconnection. Cached panes are not connection evidence. Reconnecting requires a real attempt; fresh broker reports are authoritative, old generations are rejected. No invented latency.

System typography: 13 pt rows, 12 pt context, 13 pt semibold section headings, 17 pt inspector title. Spacing 4/8/12/16/24. Rows 32 or 44 pt; source list about 184 pt; inspector 300–400 pt. Semantic macOS backgrounds and selection; status colors paired with labels/icons. Eliminate repetitive negative messaging labels and cards around every entity.

Inspector starts closed. At >=1100 pt use optional trailing column; 800–1099 pt in-content detail with Back; below800 pt destination menu rather than fixed source list. Keyboard and VoiceOver must support all actions and routes. Preserve focus/query/scroll on return.

Separate data adapters/coordinator, typed projection store, presentation state, command routing, root composition and row/map/inspector rendering. Use existing services for commands, approval and retention; no parallel worker/SSH ownership. No discovery rerun on mode switch. Refresh rereads observations; it never reconnects as a side effect.

Preserve exact pane-first group setup, incarnation revalidation, configured groups with zero ready routes, guarded approval paths, existing-pane/task actions, history, provider/team metadata and diagnostics. Do not invent backend-supported actions. History's last-24-hours proposal requires actual event timestamps and storage support; current status files alone are not a full event history.

Gates: all seven live routes with no selection/toggle; every operational transport; List/Map parity; 0/1/63/250 mixed entities; stale/partial/out-of-order source fixtures; no Network-triggered transport or worker lifecycle mutation; full workflow parity; 640pt usability; light/dark/contrast/reduced-motion/keyboard/VoiceOver; release reference timings measured separately from fresh-source completion. Implement state foundations, live List, workflow migration, Map, then history and polish.
