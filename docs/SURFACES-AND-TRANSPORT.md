# Shared surfaces and transport

## Implemented

`RelaySurfaceContent` describes bounded text, status, table and diff content. R tables and agent status cards use the same native `RelaySurfaceView`. Content is declarative and carries no executable callbacks.

`RelaySurfaceState` validates exact pane/host/session/producer ownership supplied by an authenticated caller, schema version, generation and monotonically increasing revisions. Exact replay is idempotent; conflicting revisions and closed-surface resurrection are rejected. Durable checkpoints preserve the latest events, including close tombstones. Limits are 128 surfaces, 1 MiB per content value and 8 MiB per checkpoint.

The node connection has bounded queues on Go and Swift sides. Independent route heads are prioritized; traffic within a pane retains order. Control, terminal, structured events and bulk responses have decreasing priority. Eight priority overtakes trigger an oldest-first selection.

New peers negotiate `wire_fragments_v1` through capabilities frame 20. Frame 19 carries 32 KiB fragments with an 18-byte header: version byte, original type byte, big-endian message ID (8 bytes), total payload length (4), offset (4). Assemblers permit control frames between chunks and deliver only complete logical frames. They reject discontinuous offsets, mismatched metadata and recently completed IDs. Limits are 16 MiB per logical frame, 64 incomplete frames and 32 MiB reserved reassembly memory. Older peers retain ordinary framing.

Fragmentation improves application scheduling. SSH still runs over TCP, so packet loss can delay all application routes sharing that connection. Fragmentation does not eliminate TCP head-of-line blocking.

## Transport comparison

| Transport | Fit for Relay | Remaining cost |
| --- | --- | --- |
| SSH with scheduled frames | Existing HPC accounts, jump hosts, established credentials | TCP loss affects the shared connection |
| QUIC with separate streams | Candidate for independent interactive/bulk traffic and network migration | UDP access, authentication bootstrap, server listener and client integration |
| TLS WebSocket | Browser access and networks where UDP is unavailable | TCP loss blocking remains |

There is no measured QUIC win in this implementation: no QUIC backend or network benchmark has been added. Keep SSH as the deployed transport. An optional QUIC backend should use separate streams for control and each route, preserve Relay session IDs and receipt semantics, and retain SSH fallback. Compare p50/p95/p99 input acknowledgment latency during artifact transfer, loss recovery, throughput, reconnect time and memory under identical bandwidth/RTT/loss conditions. Do not enable command-bearing early data without replay protection.

Primary specifications: [SSH channels](https://www.rfc-editor.org/rfc/rfc4254), [QUIC](https://www.rfc-editor.org/rfc/rfc9000), [WebSocket](https://www.rfc-editor.org/rfc/rfc6455).

## AI observability

`relay-settings.sh ai-status` reports recovery model availability and production decision counters/source. `ai-check` calls the production Apple proposal schema using synthetic evidence, verifies the expected action and permission/freshness guards, and cannot reconnect or change agents. An unavailable or skipped model fails the check. A passing check demonstrates this recovery decision path, not every AI feature or overall model quality.

## Remaining integration

The durable surface store, registered publisher HTTP API, exact-owner revision recovery, pane restoration and native rich-content integration are installed. Generic MCP publication/recovery and explicit native refresh/error feedback are implemented in the next source build. Actual private HTTP and app restart proof passed; the new stdio helper also published a fresh R computation table and a separate bridge status card. Native R and agent views additionally supply content directly. Real provider tool use, native visual acceptance, push subscriptions and the remaining transport rollout still require evidence. Active remote daemons have not been upgraded; fragmentation is used only when the connected daemon advertises it.
