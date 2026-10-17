import { act } from 'react'
import { render, screen } from '@testing-library/react'
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'

vi.mock('@inertiajs/react', () => ({
  usePage: () => ({ props: { current_user: null, flash: {} } }),
  useForm: () => ({
    data: {} as Record<string, string>,
    setData: () => {},
    post: () => {},
    processing: false,
    errors: {} as Record<string, string>,
  }),
  router: { patch: () => {}, delete: () => {}, post: () => {} },
}))

// A minimal stand-in for the browser EventSource — see Conversations/Show.test.tsx,
// which mounts this component through the page.
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

import ConversationStream from './ConversationStream'

describe('ConversationStream', () => {
  beforeEach(() => {
    MockEventSource.instances = []
    vi.stubGlobal('EventSource', MockEventSource)
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('opens a live EventSource for the given conversation on mount', () => {
    render(<ConversationStream conversationId={1} />)
    expect(MockEventSource.instances).toHaveLength(1)
    expect(MockEventSource.instances[0].url).toBe('/conversations/1/stream')
  })

  it('renders streamed content', () => {
    render(<ConversationStream conversationId={1} />)
    const es = MockEventSource.instances[0]
    es.emit({ type: 'message_start', role: 'assistant', model: 'claude' }, '1-1')
    es.emit({ type: 'block_open', block_id: '0', index: 0, block_type: 'text' }, '1-2')
    es.emit({ type: 'text_delta', block_id: '0', text: 'hello live' }, '1-3')
    expect(screen.queryByText('hello live')).not.toBeNull()
  })

  it('reports status transitions via onStatusChange', () => {
    const onStatusChange = vi.fn()
    render(<ConversationStream conversationId={1} onStatusChange={onStatusChange} />)
    expect(onStatusChange).toHaveBeenCalledWith('pending')

    const es = MockEventSource.instances[0]
    es.emit({ type: 'message_start', role: 'assistant', model: 'claude' }, '1-1')
    expect(onStatusChange).toHaveBeenCalledWith('live')
  })

  it('closes the EventSource once conversation_complete is seen', () => {
    render(<ConversationStream conversationId={1} />)
    const es = MockEventSource.instances[0]
    es.emit({ type: 'conversation_complete' }, '1-9')
    expect(es.closed).toBe(true)
  })
})
