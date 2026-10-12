# Project actions

Recognizes project manifests and shows suggested build/test commands. Suggestions
are not executed automatically. The separate **Run project command** tool requires
the `projectExecute` permission and review of every invocation.

## Run a command

Select a terminal with a known working directory, open Plugin tools and choose
Run project command. Review the captured host and directory, then enter:

```json
{
  "argv": ["/absolute/path/to/executable", "argument"],
  "environment": {},
  "timeout_seconds": 60
}
```

Arguments are passed literally, without shell expansion. Environment starts with
`PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin` and `LC_ALL=C`; the reviewed
environment overrides these defaults. Parent-process credentials are not inherited.
Add required environment explicitly. This is **not a sandbox**: the executable has
your user permissions, can read credentials from disk and can modify files or use
the network. Never run untrusted project code without reviewing it.

Type RUN, review the final confirmation, then execute. Each request gets a durable
receipt and can be attempted only once. Output is bounded; execution is limited to
60 seconds. This tool is for short commands, not interactive shells or long builds.
Use a terminal for those.

Closing the panel stops waiting, not necessarily the remote command. After a
disconnect, inspect the target before issuing a new request: a transport failure
does not prove execution failed. Relay never retries mutations automatically.

## Acceptance

Automated tests cover validation, literal arguments, environment isolation,
timeout, and duplicate-request rejection. Installed-app manual acceptance is
deferred until the laptop is unlocked. Version 0.2.0 is development source, not a
validated release.
