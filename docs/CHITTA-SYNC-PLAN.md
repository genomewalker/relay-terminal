# Laptop / cluster Chitta compatibility sync

Status: deployed locally 2026-09-20. Chitta/adapter 5.73.1 and bridge 0.41.0
are installed with the Mac fixes preserved. Live acceptance: 638 memories,
0 pending embeddings, 5/5 known recalls, exact embedding-space identity.
Remote maintainer `dandy-07--cc-soul-9f` acknowledged completion through the
original task and shared guidance. Relay and cluster services remain separate.

Current evidence and rollback instructions:
`/Users/kbd606/chitta-sync.9j4FTV/Documentation.md` and `completion.json`.
Immutable final backup: `preservation/mind-final4.tar` under that directory.
Local source commits: parent `c41e0d16`, field `0626415c`, bridge `88a674c`.
Ollama/Nomic was restored; 169 pre-existing zero vectors were not re-embedded.
Existing MCP sessions were preserved; new invocations load the upgraded packages.
The inventory below records the original proposal, not the current installed state.
Licensing is out of scope.

## Goal and boundaries

Align Chitta, its field store, MCP adapter and bridge source/protocol versions
without losing laptop memories, local macOS fixes, credentials or sessions.
This is a software upgrade, **not memory replication or federation activation**.
The cluster's live services stay untouched. The in-progress federation branch is
not an upgrade target until independently tested and pinned.

## Evidence and unresolved compatibility

- Laptop health: daemon 5.56.10, protocol 1.0, mind at
  `/Users/kbd606/.claude/mind` (approximately 1 GB).
- Plugin metadata: 5.71.0; this does not identify the running daemon build.
- Bridge: editable `/Users/kbd606/Downloads/opencode-bridge`, base commit
  `4c8d6b75cfef5aa8e9b2d0201b0ee25feb60f1fb`, package metadata 0.40.1,
  with seven modified tracked files. Local peer code contains macOS support
  absent from the cluster target. Preserve these edits; never reset this tree.
- The laptop mind contains `embed_1536_v1.migrated`. This is historical evidence,
  **not proof of the active embedding dimension or model**. Verify both before
  selecting build parameters. Do not re-embed implicitly.
- Revised proposed parent pin: `888d9cc87904c3ec8291e08f00a95a7cd59e5986`.
- Revised proposed field pin: `0626415c1acf3a9cd20b48f2eae51e52737d1849`.
  Maintainer reports these add the missing tracked Cargo.lock; not yet fetched
  or locally verified. Existing isolated checkout remains at the earlier pins.
- Proposed bridge pin: `cbb7a8694854437a96909f67c1b277eba4ffa547`.
- Private origins under
  `ssh://dandy-07/maps/projects/fernandezguerra/apps/repos/private/`:
  `chitta.git`, `chitta-field.git`, `chitta-bridge.git`.
- Isolated source copies: `/Users/kbd606/chitta-sync.9j4FTV/`.
- The pinned field source lacks Cargo.lock; the locked build correctly stopped.
  Resolve and preserve a dependency lock before claiming a reproducible build.
- Maintainer corrected the earlier migration warning: the store bundled with
  5.56.10 already writes V23. A V23 format migration is therefore not expected;
  verify actual local format and new-section compatibility in rehearsal.
  Preserve the untouched backup regardless. The principal reported risk is an
  embedding-space mismatch silently scheduling whole-store re-embedding.
  Compare model ID, dimension and text format, plus pending-count baseline and
  logs. An increased pending count warrants investigation; it is not by itself
  proof of a dimension mismatch.

## Ordered gates

1. **Inventory.** Record hashes and paths of live binaries, daemon arguments,
   source revisions, adapter origins, toolchains, embedding model/hash/dimension,
   store format and configured launchers. Record config paths without secrets.
   Distinguish the Python bridge from Relay's native peer transport.
2. **Preserve Mac changes.** Save the current bridge diff and configuration in a
   private backup. Integrate relevant fixes onto the pinned bridge in a separate
   worktree; review overlapping changes. Run peer identity, socket, lifecycle,
   shutdown and messaging tests. Leave the original editable checkout intact.
3. **Build a compatible candidate.** Pin parent, submodule and Python source;
   record dependency locks, compiler and ARM64 build options. Keep the laptop's
   verified embedding identity unless a separate migration is agreed. Build
   native components and adapters without installing or loading the live mind.
4. **Rehearse safely.** Obtain a consistent store backup through a verified
   snapshot mechanism or a short quiesced stop. A copy taken while writes race is
   not a certified backup. Copy the backup again for testing; keep the original
   immutable. Use isolated sockets, paths and launch configuration, with hooks,
   autonomous jobs and external effects disabled. Test migration, save, restart,
   recovery, representative recall and preservation of memory counts/metadata.
5. **Prepare rollback.** Back up binaries, editable-install metadata, plugin and
   launcher configuration alongside the consistent store. Check space, permissions
   and restore procedure. Old binaries must reopen the old backup, not the newly
   migrated store. Retain a failed upgraded store for diagnosis.
6. **Switch locally.** Only after the preceding gates pass: announce brief
   downtime, quiesce writers, take a final consistent backup, stop only the exact
   laptop daemon, install reviewed artifacts atomically, update necessary adapter
   paths and start with the same intended store/model. Never broadly kill MCP
   servers or replace credentials. Reload individual clients only as required.
7. **Acceptance.** Check actual daemon version/protocol, field/model identity,
   readiness, recall, memory counts, errors and restart recovery. Test local and
   remote bidirectional messaging with disposable messages and exact recipients.
   Verify source and installed package versions, not only stale pip metadata.

## Responsibilities and stop conditions

### Embedding acceptance evidence requested by maintainer

Verify the pinned serialization code before decoding a backup's `*.shdr`:
extract embed_dim, model_id, text_format_version and vector_space_id. Select the
header belonging to the committed snapshot family, not merely the newest file
by modification time. Compare with the daemon's recorded model-ready log and
launcher settings. Verify that `chitta format-id` is a non-mutating command in
the candidate source, then require its compiled identity to equal the stored
vector_space_id before starting a candidate daemon on even the rehearsal copy.

Build Rust and C++ with explicit, verified CHITTA_EMBED_DIM,
CHITTA_EMBED_MODEL_ID and CHITTA_TEXT_FORMAT_VERSION; confirm how each build
system propagates all three. Do not rely on conflicting historical defaults or
the cluster's model configuration. These checks are planned, not completed.

Remote Claude supplies source-grounded migration/build guidance and compatibility
review. This Relay task prepares the Mac candidate, preserves local changes and
validates installation. Neither party independently changes the other's services.

Stop before deployment on embedding mismatch, unresolved overlapping bridge edits,
inconsistent backup, failed migration/recovery tests or credential/config changes
that expand access. Resolve the issue or ask for the specific missing decision.

Relay's current MCP does not yet provide the complete create-pane/execute/follow
job workflow. Add that separately with exact target binding and native approvals;
do not hide this upgrade behind blind terminal input. Opening a local Relay tab
is still unverified because computer control failed with `noWindowsAvailable`.


## 2026-09-21 laptop follow-up
User authorized matching remote runtime and controlled federation testing. Live upgrade accepted with 636 records preserved, pending0, exact remote Nomic Q8 model through llama.cpp, restart and recall verified. Mac launch and explicit-model fallback fixes pushed privately. Details and rollback evidence: `/Users/kbd606/chitta-sync.9j4FTV/federation-upgrade/Documentation.md`. Backup: `preservation/mind-final5.tar` in that directory. Codex hooks installed/discovered but remain untrusted. Federation pairing is limited to disposable `fedtest`; no production realm enabled.


## Laptop battery requirement — user instruction 2026-09-21

Battery efficiency is an acceptance requirement for federation rollout. Preserve
fast on-demand reads and embedding/ranking quality; optimize idle transport and
background work instead. Prefer blocking/event-driven connection supervision,
bounded reconnect backoff, and reused connections. Do not prevent laptop sleep
or add wake-for-sync behavior. Defer bulk catch-up and optional maintenance on
battery/Low Power Mode, resuming safely on external power; keep explicit reads
available and prioritize revocation handling. Avoid repeatedly scanning every
realm while idle. Measure idle CPU/wakeups and background embedding work before
claiming battery efficiency.

Inspection found peer-read-tunnel.py supervising children with a 0.2-second
poll loop and SSH keepalives every15 seconds; review these before production
activation. These are findings, not yet fixed. Current replication has pending
embedding/disk pressure limits but no battery policy. Coordinate matching remote
behavior without changing retrieval quality.
