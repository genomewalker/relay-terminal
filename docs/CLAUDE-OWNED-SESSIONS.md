# Owned Claude SDK sessions (source integration in progress)

`scripts/relay-claude-sdk-adapter.py` is a thin host bridge over the official
Python Agent SDK. It uses `ClaudeSDKClient`, `ClaudeAgentOptions`, source message
objects, `can_use_tool`, and SDK permission results. It never speaks the private
Claude CLI control protocol or resumes an existing terminal session.

## Dependency and preflight

The currently verified SDK is `claude-agent-sdk==0.2.163`, Python 3.10 or later.
Install in a dedicated virtual environment, then run an import-only preflight:

```sh
python3 -m venv /path/to/relay-sdk
/path/to/relay-sdk/bin/python -m pip install --only-binary=:all: claude-agent-sdk==0.2.163
/path/to/relay-sdk/bin/python scripts/relay-claude-sdk-adapter.py --preflight
```

Preflight never connects or starts Claude. Production invocation also requires
`--claude-cli /absolute/path/to/claude`; the owning worker must provide this path
and the Python interpreter explicitly. The detached worker launch path and
`owned_claude_start` host RPC are implemented in source, with provider-tagged
manifests and a pinned bridge handshake. Native provider selection and explicit SDK settings are integrated in source.
The adapter is included in the isolated candidate app resources. The installed
production app has not been updated. The native “Set up SDK on this host” action runs the bundled
`relay-claude-sdk-install.py` using an explicitly selected Python 3.10+ interpreter.
Local assets live under Relay’s application support directory; remote assets live
under the canonical host home at `~/.local/share/relay/SDK/managed`. Remote setup
and discovery use the pooled node host-execution channel, with a durable job ID
and no execution replay on an uncertain outcome. Home and `.local/share` aliases are resolved before
the installer checks path components; links within the SDK tree are rejected.
Setup transfers the signed adapter,
installs the pinned SDK in a private immutable venv, and checks it without
starting Claude. Existing runtimes remain at their original paths. Setup returns
explicit Python and adapter paths. Selecting Claude also checks the saved managed
runtime without writing files or starting a provider. Missing or stale assets
require setup; discovery does not install automatically or replace paths edited
while its check is running. Native creation runs import-only preflight before
reserving a session.

## Internal bridge contract

JSONL frames use Relay's bounded owned item envelope (`relay.owned-provider/1`).
The `initialize`, `thread/start`, `turn/start` and `turn/interrupt` method names
are internal Relay operations. They are not Claude API method names.

`thread/start` accepts only `cwd`, optional `model`, `permissionMode`,
`settingSources` and `sandboxEnabled`. Modes currently supported are `default`,
`plan`, `dontAsk` and `acceptEdits`. Settings sources are explicit `user`,
`project` and/or `local`; an omitted list is empty. Sandbox defaults on, with
automatic sandboxed Bash approval off and unsandboxed fallback disabled. These
choices affect only a new session and do not edit user configuration.

Creation is consumed before the SDK connects. Each process creates at most one
SDK session, with a new UUID, and never uses resume or continue. Both creation
failure and uncertain submission require explicit handling by the owning
worker; neither permits automatic replay. Source session IDs must remain equal
to the bound UUID. A reset or foreign session ends the connection.

SDK permission callbacks retain exact tool arguments until an explicit decision.
Timeouts deny. Supported question answers become SDK `updated_input.answers`.
Multiple-selection questions use native checkbox controls and SDK answer arrays.
Answers require 1–32 unique nonempty values per question and a 64 KiB total limit. Interrupts require the
exact active turn and use `ClaudeSDKClient.interrupt()`.

The CLI's documented replay flag is supplied through SDK `extra_args`; it gives
source acknowledgements for user messages. Client submission intents are not
rendered as provider messages. Source text, partial text, tool uses/results,
reasoning and typed metadata events are normalized into the item channel.
Image/PDF/SVG tool-result payloads become private content-addressed files in the
owned session artifact directory, with 8 MiB per file and 128 MiB/128-file limits.
The item channel carries only absolute host-bound paths, so existing lazy previews
fetch bytes separately. Task lifecycle events update stable task items, retain
parent-turn identity after the parent finishes, and treat stopped/killed as terminal.
Task patches preserve source summaries, usage, parent-tool IDs and output paths.
Child messages and stream deltas carry parent-tool IDs, with separate stream
identities for main and child messages. Background child messages retain their
known parent turn after it becomes idle. Native rows display lifecycle status.
Full provider/live rich-message GUI coverage remains unfinished.

## Checks and remaining delivery gates

Adapter tests instantiate actual SDK message/options types and a fake client,
with no model calls, CLI processes, credentials or external tools. They cover
creation, source/identity checks, decisions, question mapping, timeout, interrupt,
and process exit while stdin remains open.

```sh
/path/to/relay-sdk/bin/python -m unittest discover -s scripts/tests -p test_claude_sdk_adapter.py
```

Before delivery: verify native provider selection, saved provider identity and
multiple selection in the GUI; finish full attachments; verify SDK subprocess lifecycle and
live provider behavior; package and deploy while preserving existing sessions,
drafts and jobs. Screen-locked builds cannot substitute for native GUI evidence.

Primary references checked 1 October 2026:

- [Python SDK reference](https://code.claude.com/docs/en/agent-sdk/python)
- [SDK source](https://github.com/anthropics/claude-agent-sdk-python)
- [CLI replay acknowledgement flag](https://code.claude.com/docs/en/cli-reference)

## Real provider acceptance — 2 October 2026

Disposable sessions against the installed detached worker and actual SDK 0.2.163
verified fresh UUID creation, successful model turns, transport reconnect retaining
the same worker/provider/thread, an exact file-write approval and replay rejection,
multiselect questions returning Alpha and Beta, changed-owner/replayed-answer and
replayed-composer rejection, and wrong-turn interrupt rejection. The original
39 panes, 30 worker and 18 provider kernel identities and saved draft hash remained
unchanged. Only the new proof workers were stopped afterward.

A real interrupt exposed cancelled turns being labelled failed. The adapter now
tracks the exact requested interrupted turn, reports it as interrupted, and clears
that marker before the next turn. Real-provider verification and 19 adapter tests
pass against the changed source. The fix is deployed in the signed production app and refreshed remote SDK
adapter assets. A real installed SDK interrupt again returned interrupted and idle.
These results do not constitute native GUI acceptance, original
Codex frontend binding or background-child approval acceptance.
