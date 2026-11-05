# Connection diagnostics

Relay's diagnostic timeline is kept in memory, so a restart used to erase the record of a stuck reconnect. Events in the connection, pane, network and app categories are now also appended, as they happen, to a connection journal. They include SSH starts, readiness, disconnects with their reason, heartbeat watchdog restarts, node eviction, failed wire writes, pane connection states, and launch and clean-shutdown markers.

The journal is under the active profile's application support root at Relay/connection-diagnostics.jsonl. New files use mode 0600 and directories 0700. The journal rotates at 1 MiB and keeps three archives, like the input journal. Values pass the same credential and home-directory redaction as the in-memory timeline. Terminal bytes never enter it.

Export diagnostics… shows the saved file in Finder and records the outcome in the journal: diagnostics-exported with the path, diagnostics-export-cancelled, or diagnostics-export-failed with the path and reason. It includes the newest 2,000 journal events, from the current file and its first archive, as `connection_journal`. An export taken after a restart therefore covers the earlier launch. Writes are queued off the main thread; an export reads the files without waiting for queued writes, whose events are still in the export's in-memory `events`. Unreadable lines, such as one torn by a crash, are skipped. Before appending, Relay ends a torn last line in either journal, so the first event after a crash starts its own line and is kept.

Pending journal writes share the input journal's cap of 128, so unavailable storage can omit events. Test processes write a connection journal only when a test supplies its own path.

Regression coverage is in Tests/RelayTests/RelayConnectionJournalTests.swift.
