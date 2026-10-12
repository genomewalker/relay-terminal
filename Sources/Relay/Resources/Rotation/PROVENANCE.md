# Context rotation policy

Base source: Chitta `feat/rotation-policy`, commit `0d914051`; Relay activity/TTL and bounded scheduling extensions reviewed 2026-10-10.
SHA-256: `cb6cf0ee65b4d0110354196733f8fedc004e3c64cfb480e10e201e62cbc32d3a`.

The policy consumes the nested `chitta.rotation/1` status. It emits
`rotate`, `hold`, or `abstain` and proposed signal arguments; it performs
no session lifecycle operation.

Economics are token equivalents using measured token counters and assumed
price ratios. The 38,000-token fresh-context baseline came from 308 Claude
sessions; the 52,000-token rework prior came from a small-context pilot.
Neither the replay model nor those priors establish realized savings for
large-context rotations. No dollar-cost or guaranteed-savings claim is made.

Relay independently verifies enrollment, exact backend incarnation, completed
turn identity, ledger ownership, capsule durability, and the lifecycle fence.
The packaged source is pinned and its verified bytes are passed directly to
the Python interpreter. A changed source requires review and a new pin.

Cache scheduling emits at most a pre-expiry wakeup and an expiry wakeup for one
exact session/turn/model/request/TTL binding. It grants no refresh or lifecycle
permission. Unknown evidence has no timer. The host must reload the ledger before
acting; no polling or synthetic provider request is implied.
