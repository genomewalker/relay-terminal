# Folder transfer implementation status

Installed locally, 2026-10-02. The local helper advertises folder protocol 1
and explicit limits. Native mixed file/folder uploads and explicit recovery are
included. The dandy-07 remote helper now supports folder protocol 1; native GUI
drop acceptance remains unverified.

## Filesystem result

The required remote Linux filesystem returned `EINVAL` for exclusive directory
rename in both the plain and moved-parent cases. Corrected collision checks
passed, but they do not establish successful directory publication. There is no
fallback that overwrites a destination.

The implementation therefore reserves a real directory with `mkdirat` and will
publish individually completed files into it. A reserved directory can be visible
before the complete folder is ready. This is not atomic visibility of the tree.

## Source primitives

`folder_manifest.go` canonicalizes an explicit manifest of regular files and
directories, including empty directories. It requires declared parents, bounded
relative UTF-8 paths, unique entries, SHA256 per file, at most 1024 entries,
64 MiB per file and 1 GiB total. Symlinks and special files are unsupported.
The root ownership marker name is reserved. Sorting produces a stable manifest
digest without depending on enumeration order.

`folder_reservation.go` binds an ID and fingerprint to one exact parent inode and
child name. A private, flushed journal precedes `mkdirat`. A random ownership
marker and the resulting directory inode identify recovery. Parent and child
descriptors are pinned; the destination name is checked against the pinned child
before acknowledgment. Each reservation has a process lock.

Known collisions are terminal for that ID. A crash with missing, incomplete or
changed ownership evidence stops recovery. It never adopts an unmarked directory
or chooses a different destination. The reservation nonce is private journal
data and must not be included in future wire responses.

`folder_publication.go` supplies exact-name file publication and whole-tree
verification helpers. Descriptor-relative traversal rejects symlinks and checks
saved parent identities. Publication requires a caller-journaled `publishing`
receipt, private owned staging, matching inode, size and SHA256, then uses
`linkat` without overwrite. A repeat accepts only the same staged inode. The
destination directory is flushed and the named inode checked before returning;
the caller must durably record `committed` before removing private staging.

The manifest verifier checks declared directories (including empty ones), saved
file and directory identities, committed receipts, sizes and content hashes,
and rejects missing or unexpected entries. The root ownership marker is allowed;
the caller must separately verify its nonce and reservation. These helpers need
the future group lock and reservation validation before and after operations.
External filesystem writers can race verification; this is not a snapshot of a
tree being modified outside Relay.

`folder_group.go` now supplies a private journal bounded at 8 MiB and a process lock held
across each group operation. The binding includes pane, source-tree digest,
canonical manifest and exact destination parent/name. Prepared intent precedes
root reservation; reservation creation verifies the prepared parent inode.
Directory identities and file publication receipts cannot be replaced or
forgotten in later journal writes. Terminal records cannot be resurrected.
An unseen cancellation records a tombstone; cancellation preserves published
contents. An uncertain journal replacement requires reopening the group.

Group commit records `committing`, requires complete per-entry receipts,
verifies the actual tree, checks reservation ownership before and after, and
then records `committed`. A pending commit cannot be cancelled. The status
projection excludes private nonce and staging metadata. Host RPC now routes
begin, status, chunk, per-file commit, group commit, cancel and terminal cleanup.
Begin requires an explicit destination and materializes declared directories.
Status optionally returns one exact child's durable offset and prefix SHA256,
bounding response size independently of the full manifest. Native receipt handling is implemented.

`folder_directories.go` materializes declared directories, including empty
ones, under the group lock. A durable parent-inode creation intent precedes
`mkdirat`; child and parent flushes and named-inode validation precede the
directory receipt. A pending intent without a saved inode is an unknown outcome:
recovery neither adopts an existing child nor recreates a missing child. Child
directories contain no added marker, preserving nested manifest filenames.

`folder_staging.go` reserves a private sibling directory on the destination
parent filesystem. Its exact derived name, ownership nonce and inode are
journaled, and collisions cannot select another staging name. Partial file
contents stay outside the manifest tree. Terminal cleanup now removes saved
staging links and the private sibling directory under the group lock. Published
paths are never passed to cleanup unlink calls.

`folder_children.go` implements child chunks with journaled stage creation,
inode identity, durable offset and prefix SHA256. Replays must match acknowledged
bytes; an uncheckpointed tail is truncated on reopening. Publication intent
precedes exact-name linking, and a committed per-file receipt follows flush and
root reservation validation. Zero-byte files use the same protocol. A publishing
or committed child rejects further chunks. Any failed group journal write now
requires reopening the group, preventing in-memory offsets from acknowledging a
failed checkpoint.

`folder_cleanup.go` uses a separate durable journal so terminal transfer receipts
stay immutable. It verifies staging ownership, parent identity and each saved
file inode, rejects unknown entries, and journals directory removal intent.
Missing stage after a saved removal intent can finish cleanup; an extant stage
with a missing ownership marker remains unresolved and is preserved. Completed
cleanup retries never touch a replacement at the old staging name. External
writers with the same UID are not serialized by the Relay group lock.

The sources build for Darwin and Linux amd64. Sixteen focused tests passed on
local Darwin (6.261 seconds) and the required remote Linux filesystem in a
private fixture. They cover group lock contention, restart binding, status
privacy, cancellation tombstones, terminal immutability, collisions, parent/root/
stage replacement, unknown mkdir outcomes, empty directory trees, zero-byte and
nonempty files, chunk replay and tail truncation, exact-name publication, and
recovery after a link but before its committed receipt. Additional coverage
includes routed host RPC, framed request/response serialization, child resume
in a separate executable process, terminal cleanup preserving published bytes,
repeat cleanup preserving a replacement, cancelled partial-stage cleanup, and
unknown marker rejection. This remains helper/host RPC evidence, not native
pooled transport or installed application acceptance. Required
remote production panes, workers, shells, providers, revision and supervisor
identities matched before/after and the prior preservation snapshot. The private
fixture was removed. The earlier failed exclusive directory rename still has
no destructive fallback.

## Next implementation

## Native source phase

`RemoteFolderSource.swift` now enumerates a real source tree through pinned
directory descriptors. It preserves empty directories, uses regular files only,
enforces the helper's path/entry/file/total bounds, hashes file contents, and
checks inode/size/mtime/ctime before and after reads and enumeration. Opening a
child later checks saved root/parent/file versions and the current named inode.
UTF-8 byte ordering and exact byte comparisons preserve helper path semantics.

The native canonical manifest encoding matches Go field order, omitted zero
sizes, and string escaping (including HTML characters and Unicode line
separators). A deterministic source-version encoding avoids JSON key-order
instability. A native fixture with Unicode/control-character names, nested
empty directories and a zero-byte file passed the actual Go canonical digest
check. Native checks also passed repeat snapshots, symlink rejection, source
mutation detection, pinned child hashing and stale-snapshot rejection.

The existing private upload store now supports typed bounded checkpoints, with
the original 8 KiB default for file uploads and up to 8 MiB for folder metadata.
Its locking, ownership checks and flushed atomic writes remain in use. A real
native file-upload regression restarted both native and helper processes,
resumed at 4 MiB, preserved an original collision, repeated commit without a
duplicate, and forgot the receipt while retaining the completed file.

The app source builds using `/private/tmp/relay-swiftpm-build`. The workspace
default build path encountered regenerated Finder metadata during resource
signing. The native folder actor, typed checkpoint schema and mixed routing are now
packaged and deployed locally. Independent verification retained 39 pane IDs,
30 worker identities, 18 provider identities, drafts and the caller audit prefix.

## Remaining implementation

Exercise the actual pooled transport and installed application restart.
Native models, source enumeration and checkpoints are implemented in source.
The helper advertises protocol 1, manifest/file/total/chunk bounds, and lack of
atomic tree visibility. Native code must require this capability and validate
the returned source, pane, manifest, destination and child resume data.

Native checkpoints must bind the source tree version and content, host/backend,
pane and exact saved destination. Resume, Forget and Cancel need the existing
explicit recovery flow. Capability advertisement and deployment follow actual
local and remote filesystem acceptance. Active production panes, providers,
drafts and jobs must be preserved throughout.

## Native actor acceptance and live destination

The isolated actual Swift actor and actual helper node RPC passed separate
client and helper process restarts, resuming a 5 MiB file at 4 MiB. It requires
explicit Resume, retains the original destination, verifies child prefix
digests, preserves empty directories and zero-byte files, cleans private
staging, repeats completed receipts without another upload, and preserves
completed bytes on Forget and root collisions. This fixture uses a framing
bridge; it does not prove the application's pooled transport or GUI drop path.

Mixed file/folder routing checks saved receipts before starting new transfers.
Folder capability gating requires protocol 1, the operation set and limits.
The read-only destination RPC validates the exact pane and live worker
incarnation and resolves the shell's current working directory. Darwin now
uses bounded kernel proc_vnodepathinfo; Linux uses the existing procfs lookup.
Focused Darwin checks passed live directory lookup, stale metadata avoidance,
unchanged manifest bytes, wrong-incarnation rejection and different-pane
manifest rejection. A working directory can change after lookup; the new
transfer binds the returned exact parent and resumes that saved destination.

## Transport and packaged acceptance

The actual native actor and pool with the actual wire scheduler/fragments
passed 4 MiB chunk transfer and separate native/helper restart recovery at
4 MiB, with full 5 MiB byte verification. This found and fixed the pool's
old 1 MiB request bound: 4 MiB chunks need about 5.6 MiB after base64 JSON.
The new request bound is 8 MiB, below the 16 MiB frame limit. The fixture
stubs UI registry and diagnostics and does not prove native GUI behavior.

A signed packaged app fixture passed pooled folder RPC across app restart,
full 5 MiB byte verification, empty directories, zero-byte files, live pane
destination lookup, collision preservation, caller pause enforcement and
terminal cleanup retaining published files. Its HTTP chunks are 96 KiB; the
separate native pool fixture proves actual 4 MiB transport. Local deployment
passed exact installed-byte and strict-signature verification. Native drop/GUI
acceptance remains required.

## Earlier deployed remote and native SSH acceptance — 2026-10-02

At this acceptance phase, the running dandy-07 helper and stable disk image had SHA256
`be5103e98362122e76c9c788b2a3d835ee297c5f530c39b380f0dc3631504f81`,
matching `Contents/Resources/relayd-linux-amd64` in the installed Relay app.
The previous guarded upgrade receipt remains intact and records the earlier
unstripped candidate. This comparison establishes current image identity; it
does not establish the later replacement's lifecycle history.

`work/verify-deployed-remote-transfers.py` passed actual deployed NodeMux folder
and single-file uploads, reconnect checkpoint recovery at 96 KiB, byte and digest
checked download, empty directories, zero-byte files, repeated commit/cancel,
folder collision rejection and single-file collision naming without overwrite.
The verifier binds the expected image SHA and kernel socket peer PID/UID.

`work/verify-native-remote-folder.py` passed the native folder actor, pool, wire
scheduler and fragments over actual SSH: 4 MiB chunks, separate native process
recovery at 4 MiB, full 5 MiB byte verification, explicit Resume, receipt recovery
without uploading again, Forget retaining files and folder collision preservation.
It uses canonical remote destinations, matching the helper's resolved workspace.
UI/profile/registry are fixture stubs; this is source-path acceptance, not installed
app or drag-and-drop acceptance. The remote daemon was not restarted.

Both fixtures removed their remote trees and retained all before-inventory panes,
workers, shells, providers, original job artifact hashes, worker record PIDs,
launcher hash, state root and supervisor incarnation. Terminal fixture receipts
remain in the durable ledger. Native evidence is recorded in
`/private/tmp/relay-native-remote-folder-n40pvi02/summary.json` and deployed RPC
evidence in `/private/tmp/relay-deployed-remote-transfer-result.json`.

## Current remote retention release — 2026-10-02

Helper 0.5.3 supersedes the image above. Its SHA256 is
`543d8375a271faf83a03a6af3df673e35826d4500d6820e30faabbd6e0f022e8`,
deployed through guarded attempt `a506b2c72a074b01a42d82cacb005ce1`.
Imported catalog entries are retained through startup garbage collection, including
the historical dormant pane. The deployment verified all 85 original pane receipts,
83 workers, 77 shells, 43 providers and original job artifacts. The current deployment
preserved its launcher; the comparison with the earliest historical launcher is
explicitly false, as recorded in `docs/LEGACY-SUPERVISOR-HANDOFF.md`.

Actual deployed upload/download, reconnect, empty/zero-byte, collision, repeated
receipt and cancel acceptance passed again against 0.5.3. Evidence is in
`/private/tmp/relay-retained-deployed-transfers.log`. Installed native drag-and-drop
acceptance remains pending. A later read-only loss audit confirmed all original
remote metadata and process identities retained, with one additional owned GUI
fixture pane; see `/private/tmp/relay-loss-audit-remote.json`.

## Installed native mixed paste and recovery acceptance — 2026-10-02

An isolated, signed clone of the installed app uploaded a Finder selection
containing one file and one folder through its native paste handler into its
owned remote pane. The visible terminal reported “Uploaded 2 files” and inserted
the two quoted remote paths without executing them. Independent remote reads
verified all six payload entries, 63 bytes, Unicode names, a zero-byte file, an
empty directory and the helper's reserved ownership marker.

Repeating the paste displayed the native recovery sheet. Resume recovered the
completed receipts with no duplicate names and matching bytes. Forget cleared
both local checkpoints; a subsequent remote read proved all published bytes
and inode identities unchanged. The original local baseline remained intact:
39 panes, 31 worker identities, 19 provider identities, two drafts and the caller
registry hash. The fixture used its own app process, listener, defaults and state.

Evidence: `/private/tmp/relay-surface-runtime-a8q4buf7/` contains
`gui-mixed-upload-proof.json`, `gui-resume-proof.json`, `gui-forget-proof.json`
and `inspection.json`. Paste and drag share the runtime import handler, but this
acceptance does not prove the cross-window drag gesture. The fixture remains
open for that remaining check.
