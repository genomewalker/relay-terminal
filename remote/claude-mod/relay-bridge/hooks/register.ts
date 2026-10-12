// relay-bridge: observe-only bridge from a Claude Code session to Relay.
//
// Relay launches Claude with RELAY_SESSION (pane id), RELAY_BRIDGE_SOCKET (a Unix
// socket in a private directory, served by the pane's relayd worker) and
// RELAY_BRIDGE_TOKEN. Without all three the module stays inert: every hook only
// calls next(e). Nothing here changes what Claude Code stores, shows or sends.
//
// Events are queued in module memory and flushed by a timer, never awaited inside
// a hook, so a slow or absent Relay can never delay a turn. A hot reload starts a
// new `load` id with sequence 1; Relay resynchronises on any load change or gap.
import type { Register, EngineInterface } from 'claude-code'

type Bridge = { socket: string; token: string; pane: string }
type Event = { seq: number; at: number; kind: string; data: unknown }

const SCHEMA = 1
const MAX_QUEUE_EVENTS = 512
const MAX_QUEUE_BYTES = 8 << 20
const MAX_TEXT_BYTES = 256 << 10
const MAX_BATCH_BYTES = 1 << 20
const FLUSH_MS = 250

const encoder = new TextEncoder()
const byteLength = (s: string) => encoder.encode(s).length

/** Cuts a string to `limit` UTF-8 bytes on a code point boundary. */
function clip(text: string, limit: number): { text: string; truncated?: number } {
  const bytes = encoder.encode(text)
  if (bytes.length <= limit) return { text }
  let end = limit
  while (end > 0 && ((bytes[end] ?? 0) & 0xc0) === 0x80) end--
  return { text: new TextDecoder().decode(bytes.subarray(0, end)), truncated: bytes.length }
}

/** Bounds one content block; media bytes are never forwarded, only described. */
function boundBlock(block: unknown): unknown {
  if (!block || typeof block !== 'object') return block
  const b = block as Record<string, unknown>
  switch (b.type) {
    case 'text': {
      const c = clip(String(b.text ?? ''), MAX_TEXT_BYTES)
      return c.truncated ? { type: 'text', text: c.text, truncated_bytes: c.truncated } : { type: 'text', text: c.text }
    }
    case 'thinking':
    case 'redacted_thinking':
      return { type: b.type, omitted: true }
    case 'image':
    case 'document': {
      const source = (b.source ?? {}) as Record<string, unknown>
      const data = typeof source.data === 'string' ? source.data : ''
      return { type: b.type, media_type: source.media_type ?? null, source_type: source.type ?? null,
               bytes: Math.floor(data.length * 3 / 4), omitted: true }
    }
    case 'tool_use': {
      const input = clip(JSON.stringify(b.input ?? null), MAX_TEXT_BYTES)
      return { type: 'tool_use', id: b.id, name: b.name, input_json: input.text,
               ...(input.truncated ? { truncated_bytes: input.truncated } : {}) }
    }
    case 'tool_result': {
      const content = Array.isArray(b.content) ? b.content.map(boundBlock)
        : typeof b.content === 'string' ? [boundBlock({ type: 'text', text: b.content })] : []
      return { type: 'tool_result', tool_use_id: b.tool_use_id, is_error: b.is_error === true, content }
    }
    default:
      return { type: String(b.type ?? 'unknown'), omitted: true }
  }
}

// Module state: a hot reload re-evaluates the module, so it starts over with a new load id.
const state = {
  bridge: null as Bridge | null,
  load: '',
  seq: 0,
  queue: [] as { event: Event; bytes: number }[],
  queuedBytes: 0,
  dropped: 0,
  flushing: false,
  failures: 0,
  backoffUntil: 0,
}

function enqueue(kind: string, data: unknown, at: number) {
  if (!state.bridge) return
  const event: Event = { seq: ++state.seq, at, kind, data }
  const bytes = byteLength(JSON.stringify(event))
  if (bytes > MAX_BATCH_BYTES) { state.dropped++; return }
  state.queue.push({ event, bytes }); state.queuedBytes += bytes
  while (state.queue.length > MAX_QUEUE_EVENTS || state.queuedBytes > MAX_QUEUE_BYTES) {
    const first = state.queue.shift(); if (!first) break
    state.queuedBytes -= first.bytes; state.dropped++
  }
}

async function flush($: EngineInterface) {
  const bridge = state.bridge
  if (!bridge || state.flushing || state.queue.length === 0) return
  const now = await $.clock.now()
  if (now < state.backoffUntil) return
  state.flushing = true
  try {
    const batch: Event[] = []; let size = 0
    for (const item of state.queue) {
      if (batch.length > 0 && size + item.bytes > MAX_BATCH_BYTES) break
      batch.push(item.event); size += item.bytes
    }
    const body = JSON.stringify({ schema: SCHEMA, load: state.load, pane: bridge.pane, dropped: state.dropped, events: batch })
    const response = await $.http.fetch('http://relay/v1/claude/events', {
      method: 'POST', body, socketPath: bridge.socket,
      headers: { 'content-type': 'application/json', 'x-relay-bridge-token': bridge.token },
    })
    if (!response.ok) throw new Error('status ' + response.status)
    // Relay acknowledges the highest sequence it stored; anything at or below it leaves the queue.
    const acked = Number((JSON.parse(response.text || '{}') as { acked_seq?: number }).acked_seq ?? 0)
    const lastSent = batch[batch.length - 1]?.seq ?? 0
    const upTo = Number.isFinite(acked) && acked > 0 ? Math.min(acked, lastSent) : lastSent
    while (state.queue.length > 0 && (state.queue[0]?.event.seq ?? Infinity) <= upTo) {
      state.queuedBytes -= state.queue[0]!.bytes; state.queue.shift()
    }
    state.dropped = 0; state.failures = 0; state.backoffUntil = 0
  } catch {
    // Relay absent or restarting: keep the bounded queue and back off (max 30 s).
    state.failures++
    state.backoffUntil = now + Math.min(30_000, 500 * 2 ** Math.min(state.failures, 6))
  } finally {
    state.flushing = false
  }
}

export const register: Register = (on) => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    const [socket, token, pane] = await Promise.all([
      $.env.get('RELAY_BRIDGE_SOCKET'), $.env.get('RELAY_BRIDGE_TOKEN'), $.env.get('RELAY_SESSION'),
    ])
    if (!socket || !token || !pane || !socket.startsWith('/') || socket.length > 100) return result
    state.bridge = { socket, token, pane }
    state.load = crypto.randomUUID()
    const at = await $.clock.now()
    const [sessionId, version] = await Promise.all([$.session.id(), $.session.version()])
    enqueue('session.start', {
      session_id: sessionId, cwd: e.cwd, interactive: e.isInteractive,
      claude_version: version.version,
    }, at)
    $.clock.every(FLUSH_MS, () => { void flush($) })
    return result
  })

  // The provider states its own transcript path; Relay cross-checks it, never guesses.
  on('classic.SessionStart', async ($, e, next) => {
    const result = await next(e)
    enqueue('binding', { session_id: e.session_id, transcript_path: e.transcript_path, source: e.source },
            await $.clock.now())
    return result
  })

  // Observe each row as stored: the chain's answer, after every other plugin.
  on('session.append', async ($, e, next) => {
    const stored = await next(e)
    const message = stored.message
    enqueue('row', {
      uuid: stored.uuid, agent_id: e.agentId ?? null, door: e.door,
      origin_kind: (e.origin as { kind?: string }).kind ?? null,
      type: message.type, name: message.name ?? null, role: message.role ?? null, is_meta: message.isMeta === true,
      content: Array.isArray(message.content) ? message.content.map(boundBlock) : [],
    }, await $.clock.now())
    return stored
  })

  on('turn.start', async ($, e, next) => {
    const result = await next(e)
    enqueue('turn.start', { turn_id: e.turnId }, await $.clock.now())
    return result
  })

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    enqueue('turn.complete', {
      turn_id: e.turnId, agent_id: e.agentId ?? null, reason: e.reason,
      aborted: e.isAborted, duration_ms: e.durationMs,
    }, await $.clock.now())
    return result
  })

  on('session.end', async ($, e, next) => {
    enqueue('session.end', { reason: e.reason }, await $.clock.now())
    await flush($)
    return next(e)
  })
}
