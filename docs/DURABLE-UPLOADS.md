# Durable upload protocol

Installed local helper and native upload integration as of 2026-10-02.
Remote hosts require the new upload capabilities; legacy supervisor upgrades
remain pending. Native GUI and drag-and-drop acceptance remain unverified.
Downloads have a separately deployed recovery implementation.

The authenticated node RPC advertises `file_upload_begin`, `file_upload_status`,
`file_upload_chunk`, `file_upload_commit`, and `file_upload_cancel`. Every request
uses a fresh `request_id` and the same stable `job_id` for one upload.

## Requests

- Begin: `upload_pane`, `upload_name`, `upload_size`, `upload_sha256`, and optional
  absolute destination directory `path`. Without a path, the server requires the
  exact live pane and reads its current shell directory. It never defaults an
  unavailable pane to the home directory. The current limit is 64 MiB.
- Chunk: `offset` and base64 `data`, bounded to 4 MiB. Only the current offset can
  append. An exact replay of already acknowledged bytes is accepted; changed
  bytes, gaps, and overlaps across the checkpoint are rejected.
- Status, commit, cancel: stable `job_id` identifies the durable record.

Responses include the durable `offset`, `state`, and, after commit, final `path`.
The binding includes pane, canonical destination directory and inode, filename,
expected size and SHA256. Reusing an ID with different begin arguments fails.

## Recovery

Records and locks live in a private `host-uploads` directory. A process lock
serializes each upload across helper processes. Each chunk is flushed before an
atomic checkpoint rename and directory flush. Recovery verifies the saved prefix
hash and staging inode, then truncates any unacknowledged tail.

Commit requires the exact expected size and checksum. Existing names are
preserved; a numbered destination is selected and durably recorded before a
no-overwrite hard link publishes the completed file. After an uncertain commit,
recovery only accepts that same destination and staging inode. A foreign inode
at the reserved destination is an unknown outcome and never causes publication
under another filename. Completed receipts remain available after staging cleanup.

Cancel reserves an unseen upload ID too, so a delayed begin cannot recreate it.
Cancel records a terminal state before deleting staging bytes. A crash between
those operations may leave an unused staging file; automatic orphan collection
is not implemented. A staging file created before the first checkpoint may also
remain after a crash. Neither case publishes a completed destination.

## Acceptance so far

Targeted Go checks cover a separate executable continuing an upload, duplicate
chunk acknowledgement, byte corruption, unacknowledged tail recovery, collision
preservation, repeat commit, exact-inode commit recovery, unknown outcomes,
binding changes, concurrent lock rejection, checkpoint symlinks, cancellation,
and missing-parent rejection. An actual packaged-app pooled RPC check found a
first-use catalog bootstrap bug; the product now initializes its private upload
catalog before reserving an upload, including before a PTY has initialized it.

The native source uses bounded pooled RPC, private locked checkpoints, source
inode/version and content hash validation, and host/backend/pane binding. It
checks the whole selection for saved work before starting a new batch. Re-dropping
files offers Resume Upload, Forget Saved Upload, and Cancel. Resume uses the saved
destination, including after the pane changes directory. Completed receipts stay
saved until explicitly forgotten, preventing duplicate files after a partial
batch. Forget cancels unfinished work and clears local history while keeping
completed remote files. Older helpers are capability-gated before upload starts.

Four native source checks cover lost acknowledgements, recovery after releasing
the uploader, completed receipt recovery, changed/missing source, explicit forget,
private locks, target identity and symlink roots. An additional real Swift harness
and isolated real helper proof restarts both processes, resumes at 4 MiB, preserves
a collision, recovers the receipt and forgets it while keeping the completed file.
That fixture provides an explicit destination to the actual helper node RPC; it
does not prove the packaged app, pooled production transport, or native GUI.

The signed build was deployed with independent retention checks for 39 panes,
30 worker incarnations, 18 providers, draft hashes, caller registry and prior audit
history. A fresh isolated profile cloned from the installed bundle passed actual
pooled upload RPC, app restart recovery, 5 MiB byte verification, collision and
commit receipt checks. HTTP fixture requests used 96 KiB chunks; the separate
native actor/helper process proof used 4 MiB chunks. Both disposable process trees
exited. These checks do not establish native GUI or drag-and-drop acceptance.

Remaining work: GUI acceptance, remote helper upgrades, folder transfers, orphan
collection and recovery from an
unreadable local checkpoint whose remote upload ID cannot be recovered.

## Native transport bound

The pooled request bound is 8 MiB, accommodating a native 4 MiB upload chunk
after base64 JSON encoding while remaining below the 16 MiB wire frame limit.
The earlier 1 MiB bound rejected real native chunks; the actual folder actor
and pool now pass a full 5 MiB upload across separate client/helper restarts,
resuming at 4 MiB. Local folder uploads and checkpoints are installed. The
dandy-07 deployed remote file/folder protocol and native source actor over pooled
SSH now pass reconnect recovery and collision preservation. See
`FOLDER-TRANSFER-DESIGN.md` for scope and evidence. Native GUI acceptance remains
pending; current remote acceptance does not prove a daemon restart.
