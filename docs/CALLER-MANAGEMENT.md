# Client management

Implementation status: signed production build installed. Focused Swift store
checks and the installed MCP helper credential-header/redaction fixture passed.
Native GUI acceptance remains pending while the console is locked. Existing
registry entries, pause settings and audit history were preserved during upgrade.

Settings → Clients → Manage clients shows registered client names, claimed
thread labels, pause switches and recent request activity. The native view and
HTTP server share one store. An unreadable store disables changes. Isolated
app profiles use their own store rather than production client metadata.

To migrate a client from shared access, create an individual credential and
copy it from the native view. Relay persists its hash, not the credential. Set
`RELAY_MCP_CALLER_TOKEN` in that client's Relay MCP helper environment while
retaining its installation credential configuration. API clients send
`X-Relay-Caller-Token` alongside their existing installation authentication.
The helper supports scoped credentials for its lifetime; existing per-request
`caller_token` remains supported. Errors redact both credentials.

Registering a client does not pause shared access. Update each client and verify
its activity appears under the new name before pausing “Shared installation
credential.” Pause blocks mutations; existing read/status behavior remains
available. Scoped credentials cannot change administrative pause settings.
Native controls represent direct user administration.

Thread labels are claims, not verified task or process identities. Audit rows
retain caller, request path, operation, resource IDs and outcome; they do not
store request bodies or credentials. The native view exposes recent activity
and resource IDs, with filtering by client, operation or resource. Existing
agents and helper processes are not restarted or reconfigured by this view.
