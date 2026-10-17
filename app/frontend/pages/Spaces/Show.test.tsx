import { render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { SpaceArtifact, SpaceConversation, SpaceIteration } from '@/types'

vi.mock('@inertiajs/react', () => ({
  Link: ({ href, children }: { href: string; children?: ReactNode }) => (
    <a href={href}>{children}</a>
  ),
  Head: (_props: { title?: string }) => null,
}))

vi.mock('@/layouts/AppLayout', () => ({
  default: ({ children }: { children?: ReactNode }) => <div data-testid="layout">{children}</div>,
}))

import Show from './Show'

const SPACE = { id: 1, slug: 'test-space', title: 'Test Space', status: 'active', repos: [], git_utc_offset: -21600 as number | null }

const CONVERSATION: SpaceConversation = {
  id: 42,
  title: 'Build the deck',
  agent_role: 'builder',
  agent_name: 'Deck Builder',
  status: 'completed',
  model: 'claude',
  updated_at: '2026-06-01T01:00:00Z',
}

const ITERATION_1: SpaceIteration = {
  id: 10,
  ordinal: 1,
  name: 'first-iter',
  freeze_sha: 'abc1234',
  verdict: 'continue',
  created_at: '2026-06-01T00:00:00Z',
  occurred_at: '2026-06-01T00:00:00Z',
  decisions: [{ name: 'Grounds', body: 'The grounds section body.' }],
  artifacts: [],
}

const ITERATION_2: SpaceIteration = {
  id: 11,
  ordinal: 2,
  name: 'second-iter',
  freeze_sha: null,
  verdict: null,
  created_at: '2026-06-02T00:00:00Z',
  occurred_at: '2026-06-02T00:00:00Z',
  decisions: [],
  artifacts: [],
}

const OTHER_ARTIFACT: SpaceArtifact = {
  id: 1,
  kind: 'brief',
  path: 'architecture/BRIEF.md',
  title: 'BRIEF',
}

const DEFAULT_PROPS = {
  space: SPACE,
  iterations: [ITERATION_2, ITERATION_1], // deliberately out of ordinal order
  conversations: [] as SpaceConversation[],
  other_artifacts: [] as SpaceArtifact[],
}

describe('Spaces/Show', () => {
  it('renders iterations in ascending ordinal order (oldest first)', () => {
    const { container } = render(<Show {...DEFAULT_PROPS} />)
    const text = container.textContent ?? ''
    const pos1 = text.indexOf('first-iter')
    const pos2 = text.indexOf('second-iter')
    expect(pos1).toBeGreaterThan(-1)
    expect(pos2).toBeGreaterThan(-1)
    // ascending: first-iter (ordinal 1) appears before second-iter (ordinal 2)
    expect(pos1).toBeLessThan(pos2)
  })

  it('renders a decision section with its name and markdown body', () => {
    render(<Show {...DEFAULT_PROPS} />)
    // Decision name appears as a summary element
    expect(screen.queryByText('Grounds')).not.toBeNull()
    // Decision body rendered by Markdown (ReactMarkdown strips tags → plain text)
    expect(screen.queryByText('The grounds section body.')).not.toBeNull()
  })

  it('renders each conversation row linking to /conversations/:id', () => {
    render(<Show {...DEFAULT_PROPS} conversations={[CONVERSATION]} />)
    const link = screen.getByText('Build the deck').closest('a')
    expect(link).not.toBeNull()
    expect(link!.getAttribute('href')).toBe('/conversations/42')
  })

  it('shows role and status badges plus the model on conversation rows', () => {
    const { container } = render(
      <Show {...DEFAULT_PROPS} conversations={[CONVERSATION]} />,
    )
    expect(container.textContent).toContain('builder')
    expect(container.textContent).toContain('completed')
    expect(container.textContent).toContain('claude')
  })

  it('interleaves conversations on the timeline by updated_at vs occurred_at (ascending order)', () => {
    const before = { ...CONVERSATION, id: 50, updated_at: '2026-05-31T12:00:00Z' }
    const between = { ...CONVERSATION, id: 51, updated_at: '2026-06-01T12:00:00Z' }
    const after = { ...CONVERSATION, id: 52, updated_at: '2026-06-03T00:00:00Z' }
    const { container } = render(
      <Show {...DEFAULT_PROPS} conversations={[after, between, before]} />,
    )
    // Use DOM order within the timeline div
    const timeline = container.querySelector('[data-testid="timeline"]')
    expect(timeline).not.toBeNull()
    const children = Array.from(timeline!.children)
    const pos = (id: number) => children.findIndex((el) => el.id === `conversation-${id}` || el.id === `iteration-${id}`)
    // Ascending: before (May 31 noon) → iter1 (June 1) → between (June 1 noon) → iter2 (June 2) → after (June 3)
    expect(children.findIndex((el) => el.id === 'iteration-10')).toBeGreaterThan(-1)
    expect(pos(50)).toBeLessThan(children.findIndex((el) => el.id === 'iteration-10'))
    expect(pos(50)).toBeLessThan(pos(51))
    expect(children.findIndex((el) => el.id === 'iteration-10')).toBeLessThan(pos(51))
    expect(pos(51)).toBeLessThan(children.findIndex((el) => el.id === 'iteration-11'))
    expect(children.findIndex((el) => el.id === 'iteration-11')).toBeLessThan(pos(52))
  })

  it('renders in-page nav anchors when more than one iteration exists', () => {
    render(<Show {...DEFAULT_PROPS} />)
    const nav = screen.queryByRole('navigation')
    expect(nav).not.toBeNull()
    const anchor = screen.queryByRole('link', { name: /I01.*first-iter/ })
    expect(anchor).not.toBeNull()
    expect(anchor!.getAttribute('href')).toBe('#iteration-10')
  })

  it('renders other_artifacts in a trailing section', () => {
    render(<Show {...DEFAULT_PROPS} other_artifacts={[OTHER_ARTIFACT]} />)
    expect(screen.queryByText('Other Artifacts')).not.toBeNull()
  })

  it('renders an artifact row linking to /spaces/:id/artifacts/:artifact_id', () => {
    render(<Show {...DEFAULT_PROPS} other_artifacts={[OTHER_ARTIFACT]} />)
    const link = screen.queryByRole('link', { name: /^view$/i })
    expect(link).not.toBeNull()
    expect(link!.getAttribute('href')).toBe('/spaces/1/artifacts/1')
  })

  it('iteration card shows absolute timestamp in occurred_at_utc_offset', () => {
    const iter: SpaceIteration = {
      ...ITERATION_1,
      occurred_at: '2026-06-28T21:32:12.278Z',
      occurred_at_utc_offset: -21600,
    }
    const { container } = render(<Show {...DEFAULT_PROPS} iterations={[iter]} />)
    expect(container.textContent).toMatch(/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}[+-]\d\d:\d\d/)
  })
})
