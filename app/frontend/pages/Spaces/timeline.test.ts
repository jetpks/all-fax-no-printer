import { describe, expect, it } from 'vitest'
import type { SpaceConversation, SpaceIteration } from '@/types'
import { interleaveTimeline, sortIterationsByOrdinal } from './timeline'

const BASE_ITER: SpaceIteration = {
  id: 1,
  ordinal: 1,
  name: 'first',
  freeze_sha: null,
  verdict: null,
  artifacts: [],
}

const BASE_CONV: SpaceConversation = {
  id: 100,
  title: 'a capture',
  agent_role: null,
  agent_name: null,
  status: 'completed',
  model: null,
  updated_at: '2026-01-02T00:00:00Z',
}

// --- sortIterationsByOrdinal ---

describe('sortIterationsByOrdinal', () => {
  it('returns iterations sorted by ordinal ascending (oldest first)', () => {
    const a: SpaceIteration = { ...BASE_ITER, id: 2, ordinal: 2, name: 'second' }
    const b: SpaceIteration = { ...BASE_ITER, id: 1, ordinal: 1, name: 'first' }
    const sorted = sortIterationsByOrdinal([a, b])
    expect(sorted[0].name).toBe('first')
    expect(sorted[1].name).toBe('second')
  })

  it('does not mutate the input array', () => {
    const a: SpaceIteration = { ...BASE_ITER, id: 2, ordinal: 2, name: 'second' }
    const b: SpaceIteration = { ...BASE_ITER, id: 1, ordinal: 1, name: 'first' }
    const input = [a, b]
    sortIterationsByOrdinal(input)
    expect(input[0].name).toBe('second')
  })

  it('handles a single iteration', () => {
    const result = sortIterationsByOrdinal([BASE_ITER])
    expect(result).toHaveLength(1)
    expect(result[0].ordinal).toBe(1)
  })
})

// --- interleaveTimeline ---

describe('interleaveTimeline', () => {
  it('returns iterations in ascending ordinal order (oldest first) when no conversations', () => {
    const iter1: SpaceIteration = { ...BASE_ITER, id: 1, ordinal: 1, name: 'first' }
    const iter2: SpaceIteration = { ...BASE_ITER, id: 2, ordinal: 2, name: 'second' }
    const result = interleaveTimeline([iter2, iter1], [])
    expect(result[0].type).toBe('iteration')
    expect((result[0] as { type: 'iteration'; data: SpaceIteration }).data.name).toBe('first')
    expect(result[1].type).toBe('iteration')
    expect((result[1] as { type: 'iteration'; data: SpaceIteration }).data.name).toBe('second')
  })

  it('interleaves a conversation between iterations by its updated_at (ascending: oldest → newest)', () => {
    const iter1: SpaceIteration = {
      ...BASE_ITER,
      id: 1,
      ordinal: 1,
      name: 'first',
      occurred_at: '2026-01-01T00:00:00Z',
    }
    const iter2: SpaceIteration = {
      ...BASE_ITER,
      id: 2,
      ordinal: 2,
      name: 'second',
      occurred_at: '2026-01-03T00:00:00Z',
    }
    const conv: SpaceConversation = { ...BASE_CONV, updated_at: '2026-01-02T00:00:00Z' }
    // Ascending order: iter1 (Jan 1), conv (Jan 2), iter2 (Jan 3)
    const result = interleaveTimeline([iter2, iter1], [conv])
    expect(result).toHaveLength(3)
    expect(result[0].type).toBe('iteration')
    expect((result[0] as { type: 'iteration'; data: SpaceIteration }).data.name).toBe('first')
    expect(result[1].type).toBe('conversation')
    expect((result[1] as { type: 'conversation'; data: SpaceConversation }).data.id).toBe(100)
    expect(result[2].type).toBe('iteration')
    expect((result[2] as { type: 'iteration'; data: SpaceIteration }).data.name).toBe('second')
  })

  it('places a conversation before all iterations when it predates them (oldest first)', () => {
    const iter: SpaceIteration = {
      ...BASE_ITER,
      occurred_at: '2026-06-01T00:00:00Z',
    }
    const conv: SpaceConversation = { ...BASE_CONV, updated_at: '2026-01-01T00:00:00Z' }
    // conv (Jan 1) predates iter (June 1) — in ascending timeline it floats to the top
    const result = interleaveTimeline([iter], [conv])
    expect(result[0].type).toBe('conversation')
    expect(result[1].type).toBe('iteration')
  })

  it('places a conversation after all iterations when it postdates them', () => {
    const iter: SpaceIteration = {
      ...BASE_ITER,
      occurred_at: '2026-01-01T00:00:00Z',
    }
    const conv: SpaceConversation = { ...BASE_CONV, updated_at: '2026-06-01T00:00:00Z' }
    const result = interleaveTimeline([iter], [conv])
    expect(result[0].type).toBe('iteration')
    expect(result[1].type).toBe('conversation')
  })

  it('breaks timestamp ties in favor of the iteration (documented stable order)', () => {
    const iter: SpaceIteration = {
      ...BASE_ITER,
      occurred_at: '2026-01-01T00:00:00Z',
    }
    const conv: SpaceConversation = { ...BASE_CONV, updated_at: '2026-01-01T00:00:00Z' }
    const result = interleaveTimeline([iter], [conv])
    expect(result[0].type).toBe('iteration')
    expect(result[1].type).toBe('conversation')
  })

  it('treats an iteration without occurred_at as unsynchronized (conversations postdate it)', () => {
    const iter: SpaceIteration = { ...BASE_ITER, occurred_at: undefined }
    const conv: SpaceConversation = { ...BASE_CONV, updated_at: '2025-01-01T00:00:00Z' }
    const result = interleaveTimeline([iter], [conv])
    expect(result[0].type).toBe('iteration')
    expect(result[1].type).toBe('conversation')
  })

  it('sorts multiple conversations among themselves by updated_at ascending', () => {
    const early: SpaceConversation = { ...BASE_CONV, id: 101, updated_at: '2026-01-01T00:00:00Z' }
    const late: SpaceConversation = { ...BASE_CONV, id: 102, updated_at: '2026-02-01T00:00:00Z' }
    const result = interleaveTimeline([], [late, early])
    expect(result.map((r) => (r.data as SpaceConversation).id)).toEqual([101, 102])
  })
})
