# Updating Relay's native Codex bundle

Relay's shell shim launches `relayd`, which selects the separately installed
native inbox bundle in `~/.local/share/relay/native-codex`. Updating the normal
npm or standalone Codex installation does not update that bundle.

The bundle contains three matching executables: `codex`, `codex-peer-worker`,
and `codex-code-mode-host`. Build and install them together. The source patch
is `scripts/native-codex-inbox.patch`; its current upstream base is the official
`rust-v0.160.1` tag, commit `d27764b82f7118f674371e6d6e76271d9d606edb`.
Apply it to a fresh checkout of the requested official release. A later release
may require adapting the patch and verifying the native inbox behavior.

Also apply `scripts/native-codex-mcp-recovery.patch` to that checkout. It adds
bounded MCP recovery to Relay-managed sessions (`RELAY_NATIVE_MESSAGES=1`).
The existing prewarm worker checks published connection state every 30 seconds;
failed connections trigger reconciliation with retry delays capped at five
minutes. Healthy clients are reused, and disabled, cancelled or
authentication-required clients do not trigger automatic retries. Recovery
does not submit a model turn. Running older native bundles acquire this behavior
only when a later session starts with the updated bundle.

Verify recovery against the freshly built binary using the private fixture:

```sh
scripts/test-native-mcp-recovery.sh \
  --binary /absolute/path/to/codex-source/codex-rs/target/release/codex \
  --result /absolute/path/to/recovery-result.json
```

The fixture deliberately fails one MCP initialization, repairs its helper, and
requires automatic tool discovery while preserving the loaded thread and the
healthy MCP process. It runs from a private directory and home, records the SHA-256
hash of every companion executable, and submits no model turn. Unit
tests for retry selection and backoff do not establish this runtime behavior.

For the macOS arm64 bundle, from the Relay checkout:

```sh
sh scripts/build-native-codehost.sh /absolute/path/to/codex-source aarch64-apple-darwin --native-bundle
sh scripts/install-native-codex.sh \
  --codex /absolute/path/to/codex-source/codex-rs/target/release/codex \
  --worker /absolute/path/to/codex-source/codex-rs/target/release/codex-peer-worker \
  --code-mode-host /absolute/path/to/codex-source/codex-rs/target/release/codex-code-mode-host
```

The build script checks the V8 assets against the manifests in the selected
official source checkout. The installer reads the built CLI's stable version,
hashes the executables, writes `native_inbox_protocol: 1`, and atomically switches
the public installation symlink. The launcher pins that symlink's resolved
directory before checking the manifest and executables, so a concurrent update
cannot mix bundle versions. Running agents keep their existing executables.

Deploy the updated Relay launcher before installing a new bundle. Older
launchers require the exact `0.160.0-relay-native-1` manifest label and reject
newer installations. Updated launchers accept protocol 1 bundles and continue
to recognize that legacy bundle. `RELAY_CODEX_BIN` remains an explicit override.

Use `--stage-only` with the installer to prepare and hash a new bundle while
the launcher update is pending. It prints the immutable bundle directory and
leaves the active installation symlink in place.

There is no automatic native bundle updater yet. The standard `codex update`
command updates the distribution that owns that CLI; it is not a substitute
for building the matching Relay inbox bundle and validating its integration.
