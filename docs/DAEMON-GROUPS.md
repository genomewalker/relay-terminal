# Daemon-owned communication groups

The communication CLI and host RPC support group_set, group_get, group_list and group_retire. Group records live in the daemon's private communication state directory and do not depend on a desktop endpoint.

Groups have a stable, canonical ID, node ID, name, owner caller ID, member pane IDs, revision, retirement state and creation/update timestamps. IDs use the existing session-token grammar and are normalized to lowercase. A group contains 2–32 unique panes from this node's catalog. Names are valid UTF-8, at most 120 bytes, and contain no control characters. The catalog allows at most 256 group records, including retained retired records.

Every mutation uses the existing caller policy. Paused callers cannot change groups; provider callers must use registered credentials and their own actor pane. The owner is assigned from the verified caller identity. Updates and retirement require that owner and the exact expected_group_revision. Creation requires revision zero. The caller's actor pane must remain a member when a provider changes a group.

Retirement keeps the record and membership data. An owned group_set at the current revision can restore it. Records use mode 0600; metadata transitions are appended to the daemon event journal. A saved record followed by a journal error returns an explicit error; clients should read the group before deciding how to recover.

Request fields are group_id, group_name, member_pane_ids and expected_group_revision, together with existing caller authentication fields. Read responses include authority=relayd and desktop_required=false.

## Native group dispatch

group_send requires a current expected_group_revision, a sender in the group, and an existing reviewed native communication pair for each recipient. The daemon pins reviewed conversation/provider identities and revalidates live native endpoints. Changed conversations, retired groups, changed membership and paused callers block subsequent recipients.

The daemon durably claims the parent message before invoking native delivery. Each recipient has a deterministic child message ID and a separate durable claim/outcome receipt. A repeated parent ID returns its stored outcomes; it never resumes dispatch, including recipients with unknown outcomes. group_receipt reads those outcomes and recovers a committed child outcome if its parent summary was not updated.

Native I/O runs outside the metadata lock. Caller policy and membership are checked again before each recipient claim. Already claimed native requests may finish after a pause; later recipients are blocked. dispatch_finished means the dispatcher finished its attempts. Provider acceptance and writing to a socket do not imply that an agent processed the message.

Message text and caller tokens are not persisted in these receipts. Trusted provenance and replay fields are not overwritten by native replies.

## Server route registry

The communication CLI and host RPC support owner-only route_set, route_get, route_list and route_retire. Request fields are route_id, peer_node_id, transport_binding_id and expected_route_revision. Provider credentials and actor panes cannot administer or read this transport registry. Owner mutations obey the daemon caller policy, including its pause state.

Each record pins a peer node identity to an opaque reviewed transport binding ID. IDs use the session-token grammar and are normalized to lowercase. A binding ID contains no address, command, socket path or credential. A saved route cannot be repointed: retire it and create a new identity for a different peer or binding. Only one active route per peer is permitted. Creation requires revision zero; updates, retirement and restoration require the exact current revision.

Records are private (0600), bounded to 128 including retired history, and emit durable transition events. Retirement preserves the record. Reads validate the owning node, identity, file name and revision. Responses explicitly report connectivity=unverified and delivery_enabled=false: registration alone neither connects to the peer nor permits remote group membership or delivery.

## Authenticated peer transport and identity probe

Owner communication operations route_identity_create and route_identity_get expose the node's public enrollment certificate and SHA-256 fingerprint. Creation is idempotent and never replaces an existing identity. The Ed25519 private key stays in peer-identity.json (0600). Certificates are valid for 90 days; expired identities fail closed.

route_identity_rotate requires the exact current expected_identity_sha256 and obeys owner pause policy. It keeps the old identity in a private fingerprint-addressed archive (bounded to 32), generates a new key and certificate, and emits a transition event. It also permits explicit renewal of an expired identity after validating its node, signature and key. Repeating the old fingerprint after rotation is rejected. Running peer services load the current identity at each new handshake; peer administrators must enroll the new public certificate in a new binding and replace their retired route before trusting it. Existing connections remain subject to request authorization and bounded idle lifetime. No peer credentials are rewritten automatically.

route_binding_set accepts peer_binding with id, peer_node_id, endpoint (host:port) and certificate_pem. The daemon assigns version and local node_id. Bindings are private, immutable and bounded to 128 records. Certificates must be valid, self-signed CA certificates for PEER_NODE_ID.relay.invalid. Only the public certificate is enrolled. Changing a peer certificate or endpoint requires a new binding and route identity.

An owner explicitly starts the service with relayd peer-serve --listen HOST:PORT. It requires an existing local identity; it does not replace a pane worker or an existing daemon. The service uses TLS 1.3, mutual certificate verification and exact certificate pins from active local routes. Trust is rebuilt for each handshake and rechecked for every request, including established connections after retirement. The listener permits at most 64 accepted connections and applies header/body/idle deadlines and an 8 KiB header bound.

route_probe requires route_id and the current expected_route_revision. It checks owner authorization and the binding under the metadata lock, performs network I/O outside that lock, then checks authorization and the route revision again. The HTTPS identity proof binds a random 32-byte nonce to the reviewed remote node. Requests and responses are bounded to 1 KiB, redirects and environment proxies are disabled, and network/handshake/response deadlines are finite. Successful probes report connectivity=verified with a timestamp and certificate fingerprint; delivery_enabled remains false. A stored route continues to report unverified connectivity because a past probe is not a current reachability guarantee.

## Reviewed remote pairs and delivery receipts

Owners use route_link_set/get/list/retire to review remote pane pairs. A set request supplies remote_link plus expected_remote_link_revision. Required review fields are peer_node_id, local_pane_id, peer_pane_id, route_id, route_revision, peer_certificate_sha256, local_conversation and peer_conversation (provider and session_id), peer_revision and allowed_peer_callers. The daemon assigns its node, canonical pair ID, timestamps and revision. The ID hashes the two qualified node/pane identities, so reciprocal reviews identify the same pair. Each owner pins the other's reviewed revision. Updating either review requires coordinating the reciprocal pins; a trusted node certificate alone grants no provider delivery.

The local conversation is discovered outside the metadata lock before enrollment. Owner authorization is checked before and after discovery. Saved route revisions/certificates must match the review. Records are private, bounded to 256 including retired history, and mutations require the current exact revision. The allowed remote caller IDs attribute credentials verified by the source daemon; they do not authenticate a desktop thread or prove authorship. Provider credentials cannot administer these records.

remote_send requires link_id, source_pane_id, pane_id, message_id, expected_remote_link_revision and text (1–16384 UTF-8 bytes). peer_node_id is an optional scope assertion. The source daemon verifies its caller/actor, live source conversation and reviewed pair/route, then durably claims the message before making the only peer send request. Its metadata lock is released before native discovery and network I/O. A duplicate ID reads the claim and never resumes dispatch.

The receiver independently verifies the pinned peer certificate, both conversation/review revisions, route revision and allowed source caller. It revalidates the live local recipient, then persists its own claim and journal event before the only native invocation. Native I/O runs outside the metadata lock. Pause/retirement/review changes block subsequent admission. A request canceled before admission does not start delivery; an already claimed native request may finish after a pause. Native replies cannot overwrite authority, attribution, routing or replay fields. Provider acceptance remains distinct from an agent processing the message.

remote_receipt reads the source claim and, when its outcome is unknown, queries the receiver using the stored scope and fingerprint without the original text. Recovery never resubmits a message. A lost reply, partial journal write or daemon crash leaves an unknown outcome that cannot be replayed. A delayed failed send cannot downgrade a receipt outcome committed by a concurrent recovery reader. route_link_received_receipt lets the receiving owner inspect retained receipts by peer_node_id and message_id after pair retirement. Receipts are private and retain no message text or raw caller token; incoming message file identities hash the peer and message separately to avoid ambiguous namespaces.

Peer message requests/responses are bounded to 128 KiB, covering JSON escaping of the full text limit; header and handshake limits remain bounded. Peer message requests have a 40-second client deadline, and the service has a 35-second response-write deadline. A timeout requires receipt recovery. Identity proofs retain their separate 1 KiB bounds.

Cross-server group dispatch, MCP/UI integration and installed/live-provider acceptance remain open. Tests use isolated native callbacks, private route fixtures, real loopback mutual TLS and a separate fixture daemon process. End-to-end send tests deliberately drop a native-acceptance reply and recover it without another native invocation. No original provider conversations were messaged, and no production peer service or credential enrollment has been installed. Existing local pairs, groups and receipts are retained.
