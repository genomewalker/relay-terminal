# Transfers

Download a file from the selected pane's project without pasting paths into a
shell. Source files stay on their original host; the completed copy is saved
where you choose on the Mac.

## Use

Install the local development manifest in Settings → Plugins, enable it, then
open Plugin tools with the intended terminal selected. Choose Transfers and
refresh to browse the project. Folder paths end with `/`. Choose a file and
click **Allow download**. After verification, **Save verified copy…** opens the
native save dialog, including overwrite review.

- Files up to 64 GiB; 4 MiB chunks, not whole-file buffering.
- Pause/resume from the last verified chunk while the panel stays open.
- Source identity is checked on resume; a replaced/changed source is rejected.
- SHA-256 checks each chunk and the completed file.
- Private temporary storage; closing/discarding the transfer releases its copy.
- Each read rechecks plugin authorization and the originating pane.
- Local saving stages a copy on the destination volume before an atomic rename.

The source must be a regular file within the approved project. Folders can be
browsed but are not recursively downloaded. Resume does not survive app exit;
the OS temporary directory may retain an incomplete copy after a crash. Final
checksum scanning may time out on unusually slow storage: this never marks a
partial download complete. No background polling or automatic retry.

Automated chunk/resume/integrity tests pass. Installed-app save, pause, revocation
and overwrite interactions remain part of deferred manual acceptance. 0.2.0 is
development source, not a released package.
