import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
// Types only — the SSE event vocabulary lives in '@/types' alongside the rest
// of the wire shapes.
import type { SSEEvent } from '@/types'

export type LiveLogProps = {
  /** Conversation mode: consume /conversations/:id/stream, unfiltered. */
  conversationId: number
  className?: string
} | {
  /** Space mode: consume /spaces/:id/stream (long-lived). */
  spaceId: number
  /** Space-mode filter: render only this conversation's events. */
  conversationId?: number
  className?: string
}

// Frozen truncation budget (looplog's RUNLOG_LIMIT parity): tool args and
// tool results clip to this many characters per line.
export const LIVE_LOG_LIMIT = 2000

// Initial replay window: the streams send only the last TAIL_MESSAGES messages
// (?tail=, message-boundary windowed server-side). Older pages load on upward
// scroll (PAGE_MESSAGES at a time) from the /stream/history endpoints.
export const TAIL_MESSAGES = 20
export const PAGE_MESSAGES = 100

// Within this many px of the bottom counts as pinned (new lines follow);
// scrolling this close to the top loads a history page.
const PIN_BOTTOM_PX = 24
const TOP_LOAD_PX = 48

// looplog TAG_COLORS parity (36 35 33 32 34 95 96 91) as Tailwind CSS color
// classes. Space-mode lines hash their conversation_id over this palette
// (looplog hashes the run id) so interleaved conversations stay distinguishable.
export const TAG_COLORS = [
  'text-cyan-400', // 36 cyan
  'text-fuchsia-400', // 35 magenta
  'text-yellow-400', // 33 yellow
  'text-green-400', // 32 green
  'text-blue-400', // 34 blue
  'text-fuchsia-300', // 95 bright magenta
  'text-cyan-300', // 96 bright cyan
  'text-red-400', // 91 bright red
] as const

// One rendered log line. Markers are their own lines (looplog discipline:
// "● assistant" bold above text, "· thinking" dim above thinking).
type LineKind =
  | 'assistant-marker'
  | 'thinking-marker'
  | 'text'
  | 'thinking'
  | 'tool'
  | 'result'
  | 'done'

type Line = {
  kind: LineKind
  text: string
  // HH:MM:SS derived from the SSE id's wall-clock ms; null for id-less events.
  ts: string | null
}

// A line tagged with the conversation that produced it (space mode interleaves
// conversations; the tag is the envelope's `tag` field, conversation mode has none).
type Entry = { convId: number; tag: string | null; line: Line }

// Per-conversation accumulation state (our own — enough to paint lines, not to
// replay a message tree).
type ConvAcc = {
  lastId: string | null
  complete: boolean
  role: string | null
  textMarked: boolean // assistant marker already emitted for the current message
  thinkMarked: boolean // thinking marker already emitted for the current message
  open: { kind: 'text' | 'thinking'; entryIdx: number } | null
  tools: Record<string, { name: string; json: string }>
}

type LogState = {
  convs: Record<string, ConvAcc>
  entries: Entry[]
}

const DIM = 'text-muted-foreground'

const LINE_CLASS: Record<LineKind, string> = {
  'assistant-marker': 'font-bold',
  'thinking-marker': DIM,
  text: '',
  thinking: DIM,
  tool: '',
  result: '',
  done: '',
}

function emptyConv(): ConvAcc {
  return {
    lastId: null,
    complete: false,
    role: null,
    textMarked: false,
    thinkMarked: false,
    open: null,
    tools: {},
  }
}

const emptyState: LogState = { convs: {}, entries: [] }

// One retained raw frame (the SSE id plus the applied event) — the store the
// history pager prepends into and rebuilds the rendered state from.
type Frame = { sseId: string | null; convId: number; event: SSEEvent }

function str(v: unknown): string {
  return typeof v === 'string' ? v : ''
}

function num(v: unknown): number | undefined {
  return typeof v === 'number' ? v : undefined
}

// SSE ids are "<conv>:<ms>-<seq>" (space envelope) or "<ms>-<seq>" (bare).
function parseSseId(id: string): { ms: number; seq: number } | null {
  const rest = id.includes(':') ? id.slice(id.indexOf(':') + 1) : id
  const m = rest.match(/^(\d+)-(\d+)$/)
  return m ? { ms: Number(m[1]), seq: Number(m[2]) } : null
}

// Local wall clock HH:MM:SS from the id's epoch-ms (looplog stamp parity).
function stampFromMs(ms: number): string {
  const d = new Date(ms)
  const p = (n: number) => String(n).padStart(2, '0')
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`
}

// looplog Support#oneline parity: collapse whitespace so a value stays on one
// line, clip at the budget with an ellipsis.
function oneline(value: unknown, limit: number = LIVE_LOG_LIMIT): string {
  const s = String(value ?? '')
    .replace(/\s+/g, ' ')
    .trim()
  return s.length > limit ? `${s.slice(0, limit)}…` : s
}

// tool_result content is a string or an array of {text} / string chunks.
function resultText(content: unknown): string {
  if (Array.isArray(content)) {
    return content
      .map((c) => (typeof c === 'string' ? c : typeof (c as { text?: unknown }).text === 'string' ? (c as { text: string }).text : ''))
      .join('')
  }
  return typeof content === 'string' ? content : ''
}

// Ruby's String#lines semantics: a single trailing newline does not add a line.
function lineCount(text: string): number {
  return text.replace(/\n$/, '').split('\n').length
}

type Usage = { out?: number; cache?: number; cost?: number }

// usage arrives when the provider supplies it; the wire spells cache_read in
// snake_case but pi's harness shape is cacheRead — accept both. cost may be a
// plain number or nested {total: …} (run.jsonl-shaped events, looplog parity).
function parseUsage(u: unknown): Usage | null {
  if (typeof u !== 'object' || u === null) return null
  const rec = u as Record<string, unknown>
  const costRaw: unknown = rec.cost
  const cost =
    num(costRaw) ??
    (costRaw !== null && typeof costRaw === 'object' ? num((costRaw as Record<string, unknown>).total) : undefined)
  const usage = { out: num(rec.output), cache: num(rec.cache_read) ?? num(rec.cacheRead), cost }
  if (usage.out === undefined && usage.cache === undefined && usage.cost === undefined) return null
  return usage
}

// "42 out  7 cache read  $0.25" — parts joined with two spaces (looplog parity).
function usageStats(usage: Usage | null): string {
  if (!usage) return ''
  const parts: string[] = []
  if (usage.out !== undefined) parts.push(`${usage.out} out`)
  if (usage.cache !== undefined) parts.push(`${usage.cache} cache read`)
  if (usage.cost !== undefined && usage.cost > 0) parts.push(`$${usage.cost.toFixed(2)}`)
  return parts.join('  ')
}

// Parsed tool args as "k: v" pairs, each value onelined (looplog parity); a
// non-object payload falls back to its JSON text.
function summarizeArgs(parsed: unknown): string {
  if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
    return Object.entries(parsed as Record<string, unknown>)
      .map(([k, v]) => `${k}: ${oneline(v)}`)
      .join('  ')
  }
  return oneline(typeof parsed === 'string' ? parsed : JSON.stringify(parsed))
}

// Apply one normalized vocabulary event to a conversation's accumulator.
// `ts` is the stamp for lines created by this event (null when the SSE frame
// carried no id). Returns the updated accumulator and entry list.
function applyEvent(
  convId: number,
  tag: string | null,
  conv: ConvAcc,
  entries: Entry[],
  event: SSEEvent,
  ts: string | null,
): { conv: ConvAcc; entries: Entry[] } {
  const next = { ...conv }
  let out = entries
  const add = (line: Line) => {
    out = [...out, { convId, tag, line }]
  }

  switch (event.type) {
    case 'session_init':
      break // no lines
    case 'message_start': {
      next.role = typeof event.role === 'string' ? event.role : 'assistant'
      next.textMarked = false
      next.thinkMarked = false
      next.open = null
      next.tools = {}
      break
    }
    case 'block_open': {
      const blockId = str(event.block_id)
      const blockType = typeof event.block_type === 'string' ? event.block_type : 'text'
      if (blockType === 'tool_use') {
        next.tools = { ...next.tools, [blockId]: { name: str(event.name), json: '' } }
        break
      }
      if (blockType !== 'text' && blockType !== 'thinking') break // redacted_thinking has no display
      if (next.role !== 'assistant') break // user text: no lines
      const marked = blockType === 'text' ? next.textMarked : next.thinkMarked
      if (!marked) add({ kind: blockType === 'text' ? 'assistant-marker' : 'thinking-marker', text: blockType === 'text' ? '● assistant' : '· thinking', ts })
      if (blockType === 'text') next.textMarked = true
      else next.thinkMarked = true
      next.open = { kind: blockType, entryIdx: out.length }
      add({ kind: blockType, text: '', ts })
      break
    }
    case 'text_delta': {
      if (!next.open) break
      const appended = str(event.text)
      const idx = next.open.entryIdx
      out = out.map((e, i) => (i === idx ? { ...e, line: { ...e.line, text: e.line.text + appended } } : e))
      break
    }
    case 'tool_args_delta': {
      const t = next.tools[str(event.block_id)]
      if (!t) break
      next.tools = { ...next.tools, [str(event.block_id)]: { ...t, json: t.json + str(event.partial_json) } }
      break
    }
    case 'block_close': {
      const blockId = str(event.block_id)
      const tool = next.tools[blockId]
      if (tool) {
        // ONE line per tool block: "⚒ <name>" + parsed args (looplog parity).
        let parsed: unknown
        try {
          parsed = JSON.parse(tool.json || '{}')
        } catch {
          parsed = undefined
        }
        const args = parsed === undefined ? oneline(tool.json) : summarizeArgs(parsed)
        add({ kind: 'tool', text: `⚒ ${tool.name} ${args}`.trimEnd(), ts })
        const tools = { ...next.tools }
        delete tools[blockId]
        next.tools = tools
        break
      }
      next.open = null
      break
    }
    case 'tool_result': {
      const body = resultText(event.content)
      const count = lineCount(body)
      const note = count > 1 ? ` (${count} lines)` : ''
      const marker = event.is_error === true ? '✗' : '←'
      add({ kind: 'result', text: `${marker} ${oneline(body)}${note}`, ts })
      break
    }
    case 'message_complete': {
      const stop = str(event.stop_reason) || null
      // Final stop reason only — a toolUse round continues the exchange
      // (looplog final_stop? parity).
      if (next.role !== 'assistant' || !stop || stop === 'tool_use') break
      const failed = stop.toLowerCase() === 'error'
      const stats = usageStats(parseUsage(event.usage))
      add({ kind: 'done', text: (failed ? '✗ failed' : '✓ done') + (stats ? `  ${stats}` : ''), ts })
      break
    }
    case 'conversation_complete': {
      next.complete = true
      break
    }
    default:
      break
  }
  return { conv: next, entries: out }
}

// Apply one SSE frame: per-conversation stale-id dedup, then the event, then
// the per-conversation lastAppliedId update. In conversation mode the stream is
// terminal on conversation_complete — later frames are ignored entirely.
function applyFrame(
  state: LogState,
  convId: number,
  event: SSEEvent,
  sseId: string | null,
  isConversationMode: boolean,
): LogState {
  const tag = typeof event.tag === 'string' ? event.tag : null
  const key = String(convId)
  const conv = state.convs[key] ?? emptyConv()
  if (isConversationMode && conv.complete) return state

  const parts = sseId ? parseSseId(sseId) : null
  if (parts && conv.lastId) {
    const last = parseSseId(conv.lastId)
    // Stale for THIS conversation (<= last applied) → drop.
    if (last && (parts.ms < last.ms || (parts.ms === last.ms && parts.seq <= last.seq))) return state
  }
  const ts = parts ? stampFromMs(parts.ms) : null
  const { conv: nextConv, entries } = applyEvent(convId, isConversationMode ? null : tag, conv, state.entries, event, ts)
  return {
    convs: { ...state.convs, [key]: parts ? { ...nextConv, lastId: sseId } : nextConv },
    entries,
  }
}

export default function LiveLog(props: LiveLogProps) {
  const spaceMode = 'spaceId' in props
  const convModeId = spaceMode ? null : props.conversationId
  const spaceModeId = spaceMode ? props.spaceId : null
  const url = spaceMode ? `/spaces/${spaceModeId}/stream` : `/conversations/${convModeId}/stream`

  const [state, setState] = useState<LogState>(emptyState)
  // Tracks the live SSE connection across reconnects (mount + refocus) so a
  // re-sync can always tear down whatever is currently open before starting
  // the next one — never two subscriptions alive at once.
  const esRef = useRef<EventSource | null>(null)
  // Retained raw frames (chronological): the initial ?tail window plus live
  // events, prepended into by the history pager and reduced back through
  // applyFrame to rebuild rendered state after a page lands.
  const framesRef = useRef<Frame[]>([])
  const scrollRef = useRef<HTMLElement | null>(null)
  const pinnedRef = useRef(true) // follow the bottom while the user hasn't scrolled up
  const loadingRef = useRef(false) // one history fetch in flight at a time
  const anchorRef = useRef<number | null>(null) // scrollHeight to restore after a prepend
  const [showJump, setShowJump] = useState(false)
  const [hasMore, setHasMore] = useState(true)
  // Conversation-mode terminal flag, readable from the visibilitychange handler
  // (which closes over a stale closure otherwise) and the error path.
  const doneRef = useRef(false)

  const connect = useCallback(() => {
    esRef.current?.close()
    // Fresh stream state: a reconnect replays the capture from its tail (Redis
    // backlog or db_replay), so stale accumulated lines must not linger.
    framesRef.current = []
    setState(emptyState)
    doneRef.current = false
    pinnedRef.current = true
    setShowJump(false)
    setHasMore(true)

    const es = new EventSource(`${url}?tail=${TAIL_MESSAGES}`)

    es.onmessage = (e: MessageEvent) => {
      try {
        const event = JSON.parse(e.data as string) as SSEEvent & { conversation_id?: unknown }
        // Space events carry the envelope conversation_id at top level;
        // conversation events don't (the URL names the conversation).
        const convId = spaceMode ? Number(event.conversation_id) : (convModeId as number)
        if (!Number.isFinite(convId)) return
        const frame: Frame = { sseId: e.lastEventId || null, convId, event }
        framesRef.current.push(frame)
        setState((prev) => applyFrame(prev, convId, event, frame.sseId, !spaceMode))
        // Conversation mode: conversation_complete is terminal — close (the capture
        // has finished landing). Space mode NEVER closes: the stream is
        // long-lived and native reconnect carries Last-Event-ID.
        if (!spaceMode && event.type === 'conversation_complete') {
          doneRef.current = true
          es.close()
        }
      } catch {
        // ignore malformed events
      }
    }

    // Allow auto-reconnect on transient errors (native reconnect carries
    // Last-Event-ID); only force-close once the conversation capture finished.
    es.onerror = () => {
      if (!spaceMode && doneRef.current) es.close()
    }

    esRef.current = es
  }, [url, spaceMode, convModeId])

  useEffect(() => {
    connect()
    return () => esRef.current?.close()
  }, [connect])

  // A backgrounded tab's EventSource can die silently. On refocus, re-sync —
  // unless the conversation-mode capture already finished, in which case
  // there's nothing left to stream.
  useEffect(() => {
    const onVisibilityChange = () => {
      if (document.visibilityState !== 'visible') return
      if (!spaceMode && doneRef.current) return
      connect()
    }
    document.addEventListener('visibilitychange', onVisibilityChange)
    return () => document.removeEventListener('visibilitychange', onVisibilityChange)
  }, [connect, spaceMode])

  // One upward history page: fetch the PAGE_MESSAGES messages strictly before
  // the oldest retained frame, prepend them, and rebuild rendered state from
  // the full frame list (the reducer is deterministic — same frames, same
  // lines; dedup rides the per-conversation lastId check as always).
  const loadHistory = useCallback(async () => {
    if (loadingRef.current || !hasMore) return
    const oldest = framesRef.current[0]
    if (!oldest) return // nothing retained yet — nothing to page below
    if (!oldest.sseId) {
      // db_replay frames carry no ids — there is no bound to page below.
      setHasMore(false)
      return
    }
    const before = oldest.sseId

    loadingRef.current = true
    try {
      const base = spaceMode ? `/spaces/${spaceModeId}/stream/history` : `/conversations/${convModeId}/stream/history`
      const res = await fetch(`${base}?before=${encodeURIComponent(before)}&limit=${PAGE_MESSAGES}`)
      if (!res.ok) {
        setHasMore(false)
        return
      }
      const page = (await res.json()) as { events: { id: string; data: SSEEvent & { conversation_id?: unknown } }[]; more: boolean }
      const frames: Frame[] = page.events.map(({ id, data }) => ({
        sseId: id,
        convId: spaceMode ? Number(data.conversation_id) : (convModeId as number),
        event: data,
      }))

      // Restore the scroll position after the prepend: record the current
      // height, let the layout effect set scrollTop from the new one.
      const el = scrollRef.current
      anchorRef.current = el ? el.scrollHeight : null
      framesRef.current = [...frames, ...framesRef.current]
      setState(framesRef.current.reduce(
        (st, f) => applyFrame(st, f.convId, f.event, f.sseId, !spaceMode),
        emptyState,
      ))
      setHasMore(page.more)
    } catch {
      setHasMore(false)
    } finally {
      loadingRef.current = false
    }
  }, [hasMore, spaceMode, spaceModeId, convModeId])

  // Pin-to-bottom panel: while the user is at (or near) the bottom, new lines
  // keep it scrolled to the bottom; scrolling up un-pins (reading mode) and
  // near the top pages a history window in.
  const onScroll = useCallback(() => {
    const el = scrollRef.current
    if (!el) return
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight <= PIN_BOTTOM_PX
    pinnedRef.current = atBottom
    setShowJump(!atBottom)
    if (el.scrollTop <= TOP_LOAD_PX) void loadHistory()
  }, [loadHistory])

  const jumpToBottom = useCallback(() => {
    pinnedRef.current = true
    setShowJump(false)
    const el = scrollRef.current
    if (el) el.scrollTop = el.scrollHeight
  }, [])

  // After every rendered change: restore the anchor after a history prepend
  // (the viewport stays where the reader was), else follow the bottom while
  // pinned.
  useLayoutEffect(() => {
    const el = scrollRef.current
    if (!el) return
    if (anchorRef.current != null) {
      el.scrollTop = el.scrollHeight - anchorRef.current
      anchorRef.current = null
    } else if (pinnedRef.current) {
      el.scrollTop = el.scrollHeight
    }
  }, [state])

  const filterId = spaceMode && props.conversationId != null ? props.conversationId : null
  const shown = filterId != null ? state.entries.filter((e) => e.convId === filterId) : state.entries

  return (
    <section
      ref={scrollRef}
      onScroll={onScroll}
      data-testid="live-log"
      className={`relative max-h-[50vh] overflow-y-auto ${props.className ?? ''}`}
    >
      {shown.length === 0 ? (
        <p className="text-sm text-muted-foreground">Waiting for events…</p>
      ) : (
        <ol className="space-y-0.5 font-mono text-xs leading-snug">
          {shown.map((entry, i) => (
            <li key={i}>
              <LineView entry={entry} spaceMode={spaceMode} />
            </li>
          ))}
        </ol>
      )}
      {showJump && (
        <button
          type="button"
          data-testid="jump-to-live"
          className="sticky bottom-1 ms-auto me-2 block rounded-full border border-border bg-background px-2 py-0.5 font-mono text-xs text-muted-foreground shadow-sm"
          onClick={jumpToBottom}
        >
          ↓ live
        </button>
      )}
    </section>
  )
}

function LineView({ entry, spaceMode }: { entry: Entry; spaceMode: boolean }) {
  const { line } = entry
  // Space-mode lines carry a "[<tag>]" prefix colored by conversation_id hashed
  // over the frozen palette (looplog TAG_COLORS parity); conversation mode has none.
  const tagColor = spaceMode ? TAG_COLORS[entry.convId % TAG_COLORS.length] : null
  const stamp = line.ts && (
    <span className={`font-mono ${DIM}`}>{line.ts} </span>
  )
  const tag = spaceMode && entry.tag && tagColor && (
    <span className={`font-mono ${tagColor}`}>[{entry.tag}] </span>
  )

  return (
    <div className={LINE_CLASS[line.kind]}>
      {tag}
      {stamp}
      <LineBody line={line} />
    </div>
  )
}

function LineBody({ line }: { line: Line }) {
  switch (line.kind) {
    case 'tool': {
      // "⚒ <name>" then the args, dimmed (looplog parity).
      const m = line.text.match(/^(⚒\s+\S+)\s([\s\S]*)$/)
      if (!m) return <>{line.text}</>
      return (
        <>
          <span className="text-cyan-400">{m[1]}</span>
          {m[2] && <span className={DIM}> {m[2]}</span>}
        </>
      )
    }
    case 'result': {
      // "←"/"✗" marker, body, dim "(N lines)" note when multiline.
      const m = line.text.match(/^([←✗])\s([\s\S]*?)( \(\d+ lines\))?$/)
      if (!m) return <>{line.text}</>
      return (
        <>
          <span className={m[1] === '✗' ? 'text-red-400' : 'text-green-400'}>{m[1]} </span>
          {m[2]}
          {m[3] && <span className={DIM}>{m[3]}</span>}
        </>
      )
    }
    case 'done': {
      // "✓ done"/"✗ failed" + dim usage stats.
      const m = line.text.match(/^(✓ done|✗ failed)(?:  ([\s\S]*))?$/)
      if (!m) return <>{line.text}</>
      return (
        <>
          <span className={m[1] === '✗ failed' ? 'text-red-400' : 'text-green-400'}>{m[1]}</span>
          {m[2] && <span className={DIM}>  {m[2]}</span>}
        </>
      )
    }
    default:
      return <>{line.text}</>
  }
}
