import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import Message from '@/components/Message'
import { buildToolResultIndex } from '@/lib/message-pairing'
import { initialState, mergedMessages, reduce } from '@/lib/sse-reducer'
import type { LiveMessage, SSEEvent, SSEState } from '@/lib/sse-reducer'
import type { Message as MessageType } from '@/types'

type Props = {
  conversationId: number
  onStatusChange?: (status: SSEState['status']) => void
}

// Adapts a LiveMessage to the Message component's expected shape.
// Uses the array index as the numeric id since live messages have no DB id.
function toLegacyMessage(msg: LiveMessage, index: number): MessageType {
  return {
    id: index,
    role: msg.role,
    model: msg.model,
    position: index,
    published: false,
    blocks: msg.blocks,
    can_publish: false,
  }
}

export default function ConversationStream({ conversationId, onStatusChange }: Props) {
  const [state, setState] = useState(initialState)

  // Tracks the live SSE connection across reconnects (mount + refocus) so a
  // re-sync can always tear down whatever is currently open before starting
  // the next one — never two subscriptions alive at once.
  const esRef = useRef<EventSource | null>(null)
  // Mirrors `state` for the visibilitychange handler below, which closes over
  // a stale `state` otherwise (it's registered once, not on every state change).
  const stateRef = useRef(state)
  stateRef.current = state

  const connect = useCallback(() => {
    esRef.current?.close()
    // Fresh stream state: a reconnect replays the capture from the top (Redis
    // backlog or db_replay), so stale accumulated messages must not linger
    // underneath it.
    setState(initialState)

    let done = false
    const es = new EventSource(`/conversations/${conversationId}/stream`)

    es.onmessage = (e: MessageEvent) => {
      try {
        const event = JSON.parse(e.data as string) as SSEEvent
        setState((prev) => reduce(prev, event, e.lastEventId || undefined))
        if (event.type === 'conversation_complete' && !done) {
          done = true
          es.close()
        }
      } catch {
        // ignore malformed events
      }
    }

    // Allow auto-reconnect on transient errors; only force-close once
    // conversation_complete seen.
    es.onerror = () => {
      if (done) es.close()
    }

    esRef.current = es
  }, [conversationId])

  useEffect(() => {
    connect()
    return () => esRef.current?.close()
  }, [connect])

  // A backgrounded tab's EventSource can die silently, leaving stale painted
  // "live" state with no subscription and no recovery short of a manual
  // reload. On refocus, re-sync automatically — unless the capture already
  // finished, in which case there's nothing left to stream.
  useEffect(() => {
    const onVisibilityChange = () => {
      if (document.visibilityState !== 'visible') return
      if (stateRef.current.status === 'complete') return
      connect()
    }

    document.addEventListener('visibilitychange', onVisibilityChange)
    return () => document.removeEventListener('visibilitychange', onVisibilityChange)
  }, [connect])

  useEffect(() => {
    onStatusChange?.(state.status)
  }, [state.status, onStatusChange])

  const messages = mergedMessages(state)

  const legacyMessages = useMemo(() => messages.map(toLegacyMessage), [messages])

  const toolResults = useMemo(() => buildToolResultIndex(legacyMessages), [legacyMessages])

  return (
    <>
      {state.status === 'pending' && (
        <p className="text-sm text-muted-foreground">Connecting…</p>
      )}

      <ol className="mt-4 space-y-3">
        {legacyMessages.map((msg, i) => (
          <li key={i}>
            <Message message={msg} conversationId={0} toolResults={toolResults} hideMenu />
          </li>
        ))}
      </ol>
    </>
  )
}
