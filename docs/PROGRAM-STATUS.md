# Program status (OSC 7501)

Relay's implementation follows [Program Status Protocol revision 0.3](https://www.superlogical.com/rex/docs/build/program-status).

## Ownership and display

The retained pane worker collects fresh output from its own PTY. It keeps at most 256 records, validates reports before replacement, resolves app inheritance, and drops running or blocked records at process exit or a new shell prompt. Completed and failed records survive those events; a full terminal reset clears them.

The pane header displays a compact state badge. Opening it shows the program's task hierarchy, title, message, blocked reason and progress. All text is plain display data. A disconnected pane identifies its last state as stale. There is no heartbeat requirement.

A report does not identify a trusted provider, approve a request, change input ownership, run a tool, or alter the native conversation. Permission, question and authentication requests use the program's normal controls. The detail view identifies the originating pane.

## Transport and replay

New viewers explicitly request program-status observation. Workers send complete replacement snapshots, including an empty array when cleared, a session-local revision and a replay marker. Older viewers receive no additional metadata. Attach reconstruction does not re-ingest reports and does not create new attention events.

The desktop admits snapshots only from the current pane transport and delivery epoch. Duplicate and stale revisions are ignored. Metadata is not persisted as a substitute for authoritative worker state.

## Detection

The PTY worker responds to fresh OSC 7501 detection queries with the fixed protocol reply only. Report IDs and text never become input. The reply queue is bounded to eight batches of at most 32 fixed replies, preventing a query flood from creating unbounded pending writes. Replies share PTY write ordering but do not acquire a client lease or count as human input.

Workers advertise reply ownership to attached Relay clients. The native renderer's identical detection reply is then suppressed, preventing duplicate responses. Reconstruction never causes a worker reply. The standalone xterm-relay terminfo entry includes the extended Pst capability.

## Compatibility and rollout

Existing retained workers are immutable and keep running. Workers predating this feature cannot supply snapshots or answer queries; reconnecting their original conversation is not an upgrade. New supporting workers provide the feature without requiring provider-specific output parsing.

A retained supervisor can predate the observation field and remove it while rebuilding the attach request. Supporting workers advertise `program_status_negotiation_v1`; after attachment, Relay requests observation on that authenticated connection with a bounded capability frame. The worker sends an ordered replay snapshot once, then fresh replacements. Repeated requests do not duplicate replay. This observation also works without an input lease and cannot acquire input ownership. Older workers receive no capability request. This path preserves the running supervisor and existing workers; installed acceptance is required before declaring the rollout complete.

Claude Code 2.1.295 reports OSC 7501 status, as documented in [Anthropic's release notes](https://github.com/anthropics/claude-code/releases/tag/v2.1.295). Older programs remain usable and may not emit reports. Do not restart an existing provider solely to enable reporting.

Opaque strings are ignored except the explicit tmux passthrough envelope (DCS tmux; ... ST). The worker decodes doubled ESC bytes only after a complete envelope, with an 8192-byte decoded payload limit and four-envelope nesting limit. Malformed escaping or oversized envelopes cannot emit reports or detection replies. Other DCS/APC/PM/SOS strings remain opaque.

The encoding follows the [tmux FAQ](https://github.com/tmux/tmux/wiki/FAQ). Live multiplexer acceptance remains required. tmux 3.3 and later require allow-passthrough to be enabled by the session owner; Relay does not change the user's tmux configuration.

## Validation and delivery

Parser, owned-session, wire/replay, fixed-reply and desktop validation tests are recorded in work/relay-closure-goal-20261008.md. The closure register distinguishes source implementation, automated checks, isolated acceptance and installed delivery. A passing parser test alone does not prove the live feature is installed.

## Structured attention

Fresh blocked, error and done state transitions can create a program-reported item in the existing activity inbox. Each item identifies its pane. Replay snapshots create no item; unchanged state, progress and message edits create no item. At most one item per pane is emitted every five seconds, prioritizing error, blocked, then done when several arrive together. Suppressed transitions are dropped, not delayed. These reports remain exact display data and bypass automatic summaries; the app field does not select a trusted provider or approve a request. Production acceptance is tracked separately in the closure register.

The wire decoder follows the worker's boolean encoding: an omitted program-status replay flag means false (fresh), while replay is explicitly true. Unrelated status messages retain their optional flag. This normalization never grants provider or input authority.
