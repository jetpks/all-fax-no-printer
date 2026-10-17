import { act } from 'react'
import { render, screen } from '@testing-library/react'
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'
import LiveLog, { LIVE_LOG_LIMIT, TAG_COLORS } from './LiveLog'

// Same stub pattern as ConversationStream.test.tsx — a minimal stand-in for the
// browser EventSource: capture instances, emit(data, lastEventId).
class MockEventSource {
  static instances: MockEventSource[] = []
  url: string
  closed = false
  onmessage: ((e: MessageEvent) => void) | null = null
  onerror: (() => void) | null = null

  constructor(url: string) {
    this.url = url
    MockEventSource.instances.push(this)
  }

  close() {
    this.closed = true
  }

  emit(data: unknown, lastEventId = '') {
    act(() => {
      this.onmessage?.({ data: JSON.stringify(data), lastEventId } as MessageEvent)
    })
  }
}

// HH:MM:SS the way the component derives it: local wall clock from the id's ms.
function expectedStamp(id: string): string {
  const ms = Number(id.includes(':') ? id.slice(id.indexOf(':') + 1).split('-')[0] : id.split('-')[0])
  const d = new Date(ms)
  const p = (n: number) => String(n).padStart(2, '0')
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`
}

describe('LiveLog', () => {
  beforeEach(() => {
    MockEventSource.instances = []
    vi.stubGlobal('EventSource', MockEventSource)
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('conversation mode opens /conversations/:id/stream', () => {
    render(<LiveLog conversationId={1} />)
    expect(MockEventSource.instances).toHaveLength(1)
    expect(MockEventSource.instances[0].url).toBe('/conversations/1/stream')
  })

  it('space mode opens /spaces/:id/stream', () => {
    render(<LiveLog spaceId={2} />)
    expect(MockEventSource.instances).toHaveLength(1)
    expect(MockEventSource.instances[0].url).toBe('/spaces/2/stream')
  })

  it('space mode with conversationId filter renders only that conversation_id events', () => {
    render(<LiveLog spaceId={2} conversationId={5} />)
    const es = MockEventSource.instances[0]
    // Two interleaved conversations stream into the same connection.
    es.emit({ type: 'message_start', role: 'assistant', conversation_id: 5, tag: 'bld' }, '5:1000-1')
    es.emit({ type: 'block_open', block_id: '0', block_type: 'text', conversation_id: 5, tag: 'bld' }, '5:1000-2')
    es.emit({ type: 'text_delta', block_id: '0', text: 'from-five', conversation_id: 5, tag: 'bld' }, '5:1000-3')
    es.emit({ type: 'message_start', role: 'assistant', conversation_id: 6, tag: 'spec' }, '6:1000-1')
    es.emit({ type: 'block_open', block_id: '0', block_type: 'text', conversation_id: 6, tag: 'spec' }, '6:1000-2')
    es.emit({ type: 'text_delta', block_id: '0', text: 'from-six', conversation_id: 6, tag: 'spec' }, '6:1000-3')
    expect(screen.queryByText(/from-five/)).not.toBeNull()
    expect(screen.queryByText(/from-six/)).toBeNull()
  })

  it('renders tool use as ONE line with clipped args', () => {
    render(<LiveLog conversationId={1} />)
    const es = MockEventSource.instances[0]
    es.emit({ type: 'message_start', role: 'assistant' }, '1-1')
    es.emit({ type: 'block_open', block_id: '0', block_type: 'tool_use', name: 'Read' }, '1-2')
    es.emit({ type: 'tool_args_delta', block_id: '0', partial_json: `{"path":"app/x.rb","blob":"${'y'.repeat(LIVE_LOG_LIMIT + 100)}"}` }, '1-3')
    es.emit({ type: 'block_close', block_id: '0' }, '1-4')
    // ONE line: the args live in a single text node with no line breaks.
    const args = screen.getByText(/path: app\/x\.rb/)
    expect(args.textContent).not.toMatch(/\n/)
    // Clipped at the frozen budget with an ellipsis.
    expect(screen.getByTestId('live-log').textContent).toMatch(/…$/)
    const text = screen.getByTestId('live-log').textContent ?? ''
    expect(text.length).toBeLessThan(LIVE_LOG_LIMIT + 200)
  })

  it('renders tool results as ONE line with a "(N lines)" note', () => {
    render(<LiveLog conversationId={1} />)
    const es = MockEventSource.instances[0]
    es.emit({ type: 'tool_result', tool_use_id: 't1', content: 'alpha\nbeta\ngamma' })
    // ONE line: exactly one <li>, no stamp (id-less), marker + body + note inline.
    const lines = screen.getByTestId('live-log').querySelectorAll('li')
    expect(lines).toHaveLength(1)
    expect(lines[0].textContent).toBe('← alpha beta gamma (3 lines)')
  })

  it('renders thinking dimmed', () => {
    render(<LiveLog conversationId={1} />)
    const es = MockEventSource.instances[0]
    es.emit({ type: 'message_start', role: 'assistant' }, '1-1')
    es.emit({ type: 'block_open', block_id: '0', block_type: 'thinking' }, '1-2')
    es.emit({ type: 'text_delta', block_id: '0', text: 'pondering' }, '1-3')
    const line = screen.getByText('pondering')
    expect(line.className).toContain('text-muted-foreground')
  })

  it('renders a "✓ done" line with usage stats on message_complete', () => {
    render(<LiveLog conversationId={1} />)
    const es = MockEventSource.instances[0]
    es.emit({ type: 'message_start', role: 'assistant' }, '1-1')
    es.emit({ type: 'message_complete', stop_reason: 'end_turn', usage: { output: 42, cache_read: 7, cost: { total: 0.25 } } }, '1-2')
    const text = screen.getByTestId('live-log').textContent ?? ''
    expect(text).toContain('✓ done')
    expect(text).toContain('42 out')
    expect(text).toContain('7 cache read')
    expect(text).toContain('$0.25')
  })

  it('renders per-line timestamps from the SSE id wall-clock ms', () => {
    render(<LiveLog conversationId={1} />)
    const es = MockEventSource.instances[0]
    es.emit({ type: 'tool_result', content: 'hello' }, '1:1700000000000-3')
    expect(screen.getByTestId('live-log').textContent).toContain(expectedStamp('1:1700000000000-3'))
  })

  it('renders no timestamp for id-less events', () => {
    render(<LiveLog conversationId={1} />)
    const es = MockEventSource.instances[0]
    es.emit({ type: 'tool_result', content: 'hello' })
    expect(screen.getByTestId('live-log').textContent).not.toMatch(/\d\d:\d\d:\d\d/)
  })

  it('space-mode lines carry a "[tag]" prefix colored by conversation_id; conversation mode has none', () => {
    render(<LiveLog spaceId={2} />)
    const es = MockEventSource.instances[0]
    es.emit({ type: 'tool_result', content: 'hello', conversation_id: 5, tag: 'bld' }, '5:1000-1')
    const tagged = screen.getByText(/\[bld\]/)
    expect(tagged.className).toContain(TAG_COLORS[5 % TAG_COLORS.length])
    expect(screen.getByTestId('live-log').textContent).toContain('[bld]')

    render(<LiveLog conversationId={1} />)
    const convEs = MockEventSource.instances[1]
    convEs.emit({ type: 'tool_result', content: 'hello' }, '1-1')
    expect((screen.getAllByTestId('live-log')[1].textContent ?? '')).not.toMatch(/\[/)
  })

  it('drops stale events (id <= last applied for that conversation)', () => {
    render(<LiveLog conversationId={1} />)
    const es = MockEventSource.instances[0]
    es.emit({ type: 'message_start', role: 'assistant' }, '1-5')
    es.emit({ type: 'block_open', block_id: '0', block_type: 'text' }, '1-6')
    es.emit({ type: 'text_delta', block_id: '0', text: 'fresh' }, '1-7')
    es.emit({ type: 'text_delta', block_id: '0', text: 'STALE' }, '1-6')
    es.emit({ type: 'text_delta', block_id: '0', text: 'STALE' }, '1-5')
    expect(screen.queryByText(/STALE/)).toBeNull()
    expect(screen.queryByText(/fresh/)).not.toBeNull()
  })

  it('space mode does NOT close the EventSource on conversation_complete', () => {
    render(<LiveLog spaceId={2} />)
    const es = MockEventSource.instances[0]
    es.emit({ type: 'conversation_complete', conversation_id: 5, tag: 'bld' }, '5:1000-9')
    expect(es.closed).toBe(false)
  })

  it('conversation mode DOES close the EventSource on conversation_complete', () => {
    render(<LiveLog conversationId={1} />)
    const es = MockEventSource.instances[0]
    es.emit({ type: 'conversation_complete' }, '1-9')
    expect(es.closed).toBe(true)
  })
})
