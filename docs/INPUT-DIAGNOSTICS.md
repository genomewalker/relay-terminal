# Input diagnostics

Relay records sampled input path metadata in its diagnostic timeline and input journal. It never records key text, clipboard content, or drafts in these events.

The journal is under the active profile's application support root at Relay/input-diagnostics.jsonl. New files use mode 0600 and directories 0700. The journal rotates at 1 MiB and keeps three archives.

Sampling admits up to four events per pane/event name in each five-second window, and 128 events across all panes. Each window resets admission so a long-running pane remains observable. Pending journal writes are capped at 128; unavailable storage can cause samples to be omitted.

Allowed numeric byte and character counts must be integers from 0 through 1,000,000,000. Unknown metadata fields are removed before the in-memory timeline and disk journal. Other allowed fields describe pane identity, focus, input inspection, paste approval, and outcome state.

A sample's absence does not prove that input was absent or rejected: sampling and the pending-write limit can omit events. Correlate the key, committed-text, surface-write and bridge-send stages with focus and transport state.

Regression coverage is in Tests/RelayTests/RelayInputDiagnosticSamplerTests.swift. It checks continued sampling, bounds, field filtering, counts, file permissions and journal rotation using private temporary paths.
