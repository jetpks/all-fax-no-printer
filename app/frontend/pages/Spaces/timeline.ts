import type { SpaceConversation, SpaceIteration } from '@/types'

export type TimelineItem =
  | { type: 'iteration'; data: SpaceIteration }
  | { type: 'conversation'; data: SpaceConversation }

export function sortIterationsByOrdinal(iterations: SpaceIteration[]): SpaceIteration[] {
  return [...iterations].sort((a, b) => a.ordinal - b.ordinal)
}

// Merge iterations (ascending ordinal) and conversations into a single timeline.
// Ordering keys: an iteration's occurred_at vs a conversation's updated_at, both
// ascending. A conversation whose updated_at strictly predates an iteration's
// occurred_at appears above that iteration (earlier in the ascending list).
// Conversations that postdate all iterations fall to the end.
// TIES: equal timestamps → iteration appears before the conversation (stable,
// documented order). An iteration without occurred_at can't be compared, so
// conversations only predate iterations that carry a time.
export function interleaveTimeline(
  iterations: SpaceIteration[],
  conversations: SpaceConversation[],
): TimelineItem[] {
  const sorted = sortIterationsByOrdinal(iterations)
  const result: TimelineItem[] = []

  const pending = [...conversations].sort(
    (a, b) => new Date(a.updated_at).getTime() - new Date(b.updated_at).getTime(),
  )

  let convIdx = 0

  for (const iter of sorted) {
    // Insert any conversations that strictly predate this iteration's occurred_at.
    // Tie (equal timestamps): do NOT insert before the iteration — iteration goes first.
    while (convIdx < pending.length && iter.occurred_at != null) {
      const convTime = new Date(pending[convIdx].updated_at)
      if (convTime < new Date(iter.occurred_at)) {
        result.push({ type: 'conversation', data: pending[convIdx++] })
      } else {
        break
      }
    }
    result.push({ type: 'iteration', data: iter })
  }

  // Append any remaining conversations (they postdate all iterations).
  while (convIdx < pending.length) {
    result.push({ type: 'conversation', data: pending[convIdx++] })
  }

  return result
}
