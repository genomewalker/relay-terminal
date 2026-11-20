# Two-investigator Relay prototype

Run from this directory. The recorded pilot is sufficient for offline replay.

```sh
out=$(mktemp -d)
swiftc Investigation.swift checks/main.swift -o "$out/check"
"$out/check"
swiftc ../../Sources/Relay/RelayMikoTaskEngine.swift Investigation.swift main.swift -o "$out/replay"
"$out/replay" sample.json "$out/journal.json"
```

To generate a new sample with three hosted model calls, run `python3 pilot.py "$out"`. The control is Sol on both questions. The two investigators are Sol and Opus on one question each. The lead checks both answers against Git. Times cover the model processes and omit the journal and Chitta steps. Model token accounting is provider-specific.

The sample asks about ancestry and patch equivalence in a frozen release. Neither test excludes a manually rewritten implementation. This checks mechanics and overhead. A diagnostic accuracy comparison needs harder incidents with independently known causes.

## Integration contract

Use one Miko task ID, one coordinator and two assignments. Store the board in Miko's checkpoint payload alongside existing adapter state; preserve the existing payload schema. Publish a compact checkpoint to Chitta under the exact session/project key after the local journal commit. Use the Miko revision to identify stale Chitta copies. Miko remains authoritative for dispatch and receipts.

The CLI replay uses role aliases and recorded model returns. In Relay bind each role to the exact pane and provider session, use beginDispatch and its stable operation ID, and accept ownership only from an authenticated response. A transport receipt alone leaves the assignment offered. Persist identity, board and operation consistently on restart. Reconcile uncertain sends under their original IDs. The coordinator must independently check the cited source before marking a finding verified.

Both original branches must settle before one follow-up may address one disputed or refused question. Preserve dissent and any unresolved branch in the final report. Acceptance for main integration includes an actual Codex/Claude pane exchange, a refused offer, restart during an outstanding offer, duplicate delivery, an unresolved conflict, exact-key Chitta recovery, and user-visible progress. This directory can be qualified without starting Relay or contacting agents.
