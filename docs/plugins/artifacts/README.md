# Artifacts

Browse and preview files from the selected pane's project on demand. Enable the
package in Settings → Plugins, select the intended terminal, then open Plugin
tools → Artifacts → Allow once & refresh. Open folders or select a file.

Supported previews include images, plain text, Markdown and CSV tables. Images
are downsampled for display. Text/table previews are bounded; **Save copy…**
preserves the original file rather than the shortened preview. No remote HTML
or repository scripts execute. Files are not sent to an AI provider.

Each read is scoped to the captured host/project, verifies SHA-256, and rechecks
authorization before showing data. Preview files are limited to 8 MiB. Use
Transfers for larger downloads. Directory listings show at most 500 entries.

Manual keyboard, resizing, preview and revoke checks are deferred until the
laptop is unlocked. See the main plugin acceptance checklist before release.
