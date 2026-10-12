# Network redesign: current evidence and preserved workflows

Requested September 26, 2026: refactor Network and its full UI/UX, consult Pro.

Pro consultation: https://chatgpt.com/c/6ab80353-7330-83ed-8b73-f814581f9944
Status: Pro completed its specification (9m 27s); reviewed September 26, 2026.

## Confirmed UI failures

- Overview advertises seven connected links but initially hides all route rows behind an unchecked Show all links toggle and a selection requirement.
- Connection rows appear below the complete participant inventory, making discovery harder as session counts grow.
- The initial inspector is empty; host/session/agent ownership and communication evidence compete for attention.
- Persistent host SSH/broker connections are absent. The seven connected links are messaging routes, not host transports.
- Machine identifiers and repeated negative messaging labels overwhelm useful session names and activity.

## Current implementation boundaries

- `PeerNetworkControlCenter.swift`: topology state, discovery, refresh, Overview/List/Connections routing, inspector, connection selection and sheets.
- `PeerNetworkMap.swift`: host groups, session and child-agent tiles, live/historical route rows, provider/group/team reports. Show all links defaults false.
- `PeerNetworkView.swift`: connection configuration and management workflows.
- `NetworkParticipant.swift`: identity, ownership, participant projections and selection continuity.
- `PeerNetworkStatus.swift`: messaging evidence, freshness and identity-review states.
- `RelayNodeTransport.swift`: shared node pool; node readiness, generation, reconnect attempts and heartbeat tracking are private. Pool exposes cached node count, which is not connection health. Add a read-only status projection at real lifecycle boundaries.
- `RelayRemoteTransport.swift`: per-session attached, reconnecting, waiting-for-network, error and other status callbacks; these cannot alone certify the state of an independently retained broker.
- `Models.swift`: observable pane connection state. Keep pane readiness distinct from host readiness and broker lifetime.

## Workflows to retain

Search and host discovery; participant and link inspection; open-pane actions; native and desktop messaging setup; group selection and setup; identity approvals/review; route management and stopping; provider introductions; Claude team/agent ownership metadata; current and earlier evidence.

## Implementation constraints

Preserve existing dirty repository changes and all running workers. No transport reconnect, session restart or process termination as a side effect of viewing Network. No invented latency, process health, confirmed message processing or connection freshness. Make all live host connections and messaging links discoverable on entry. History remains accessible but does not imply current connectivity. Support native macOS appearance, keyboard navigation and narrow windows.

## Next gate

Read Pro's completed recommendation, capture it here, choose the concrete design system and component plan, then implement and validate the complete Network experience. The first implementation slice adds read-only remote protocol observations, a live host/route ledger, an explicit earlier-observation view, and a split map/route layout. Full workflow migration, responsive inspectors, broker inventory, and visual QA remain. The installed app has not been replaced.
