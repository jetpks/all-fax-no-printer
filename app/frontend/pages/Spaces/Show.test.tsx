import { render, screen } from '@testing-library/react'
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { SpaceArtifact, SpaceConversation, SpaceIteration, SpaceNarrator } from '@/types'

vi.mock('@inertiajs/react', () => ({
  // Forward extra props (data-testid, className) so full-row anchors can be queried.
  Link: ({ href, children, ...rest }: { href: string; children?: ReactNode } & Record<string, unknown>) => (
    <a href={href} {...rest}>{children}</a>
  ),
  Head: (_props: { title?: string }) => null,
}))

vi.mock('@/layouts/AppLayout', () => ({
  default: ({ children }: { children?: ReactNode }) => <div data-testid="layout">{children}</div>,
}))

// LiveLog opens a real EventSource on mount — stub it (same pattern as
// ConversationStream.test.tsx) so the page renders offline.
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
}

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

const NARRATOR: SpaceNarrator = {
  conversation_id: 42,
  text: 'The deck now renders a live log.',
  updated_at: '2026-06-03T00:00:00Z',
}

const DEFAULT_PROPS = {
  space: SPACE,
  iterations: [ITERATION_2, ITERATION_1], // deliberately out of ordinal order
  conversations: [] as SpaceConversation[],
  other_artifacts: [] as SpaceArtifact[],
  narrator: null as SpaceNarrator | null,
}

describe('Spaces/Show', () => {
  beforeEach(() => {
    MockEventSource.instances = []
    vi.stubGlobal('EventSource', MockEventSource)
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('mounts the live log on the space stream URL', () => {
    render(<Show {...DEFAULT_PROPS} />)
    expect(MockEventSource.instances).toHaveLength(1)
    expect(MockEventSource.instances[0].url).toBe('/spaces/1/stream')
  })

  it('renders top-to-bottom: live log, narrator, conversation rows, iterations', () => {
    const { container } = render(
      <Show {...DEFAULT_PROPS} conversations={[CONVERSATION]} narrator={NARRATOR} />,
    )
    const liveLog = container.querySelector('[data-testid="live-log"]')!
    const narratorSection = container.querySelector('[data-testid="narrator-section"]')!
    const row = container.querySelector('[data-testid="conversation-row-link"]')!
    const iteration = container.querySelector('section[id^="iteration-"]')!
    // compareDocumentPosition: a FOLLOWING b ⇔ a renders before b.
    const before = (a: Element, b: Element) =>
      (a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0
    expect(before(liveLog, narratorSection)).toBe(true)
    expect(before(narratorSection, row)).toBe(true)
    expect(before(row, iteration)).toBe(true)
  })

  it('omits the narrator section entirely when narrator is null', () => {
    render(<Show {...DEFAULT_PROPS} />)
    expect(screen.queryByTestId('narrator-section')).toBeNull()
  })

  it('renders the narrator markdown text linked to its conversation', () => {
    render(<Show {...DEFAULT_PROPS} narrator={NARRATOR} />)
    expect(screen.queryByText('The deck now renders a live log.')).not.toBeNull()
    const section = screen.getByTestId('narrator-section')
    const link = section.querySelector('a')
    expect(link!.getAttribute('href')).toBe('/conversations/42')
  })

  it('renders one full-row anchor per conversation wrapping title + badges + time', () => {
    render(<Show {...DEFAULT_PROPS} conversations={[CONVERSATION]} />)
    const links = screen.getAllByTestId('conversation-row-link')
    expect(links).toHaveLength(1)
    const link = links[0]
    expect(link.getAttribute('href')).toBe('/conversations/42')
    // The anchor IS the row: every piece of content lives inside it.
    expect(link.textContent).toContain('Build the deck')
    expect(link.textContent).toContain('builder')
    expect(link.textContent).toContain('completed')
    expect(link.textContent).toContain('claude')
    expect(link.textContent).toMatch(/ago|just now/)
    // No nested interactive elements inside the anchor.
    expect(link.querySelectorAll('a, button')).toHaveLength(0)
  })

  it("falls back to 'Untitled conversation' for empty AND whitespace-only titles", () => {
    const { container } = render(
      <Show
        {...DEFAULT_PROPS}
        conversations={[
          { ...CONVERSATION, id: 43, title: '' },
          { ...CONVERSATION, id: 44, title: '   ' },
        ]}
      />,
    )
    const links = container.querySelectorAll('[data-testid="conversation-row-link"]')
    expect(links).toHaveLength(2)
    expect(links[0].textContent).toContain('Untitled conversation')
    expect(links[1].textContent).toContain('Untitled conversation')
  })

  it('renders conversations in PROP ORDER (newest-first server order, no re-sort)', () => {
    const newer = { ...CONVERSATION, id: 50, updated_at: '2026-06-05T00:00:00Z' }
    const older = { ...CONVERSATION, id: 40, updated_at: '2026-05-01T00:00:00Z' }
    const { container } = render(<Show {...DEFAULT_PROPS} conversations={[newer, older]} />)
    const links = Array.from(container.querySelectorAll('[data-testid="conversation-row-link"]'))
    // Prop order preserved: 50 (newest) before 40 (older) — ascending updated_at
    // would reverse them and would be the defect this layout kills.
    expect(links.map((l) => l.getAttribute('href'))).toEqual(['/conversations/50', '/conversations/40'])
  })

  it('renders a muted empty-state line when there are no conversations', () => {
    render(<Show {...DEFAULT_PROPS} />)
    expect(screen.queryByText('No conversations yet.')).not.toBeNull()
  })

  it('renders iterations in ascending ordinal order with #iteration-<id> anchors', () => {
    const { container } = render(<Show {...DEFAULT_PROPS} />)
    const text = container.textContent ?? ''
    const pos1 = text.indexOf('first-iter')
    const pos2 = text.indexOf('second-iter')
    expect(pos1).toBeGreaterThan(-1)
    expect(pos2).toBeGreaterThan(-1)
    // ascending: first-iter (ordinal 1) appears before second-iter (ordinal 2)
    expect(pos1).toBeLessThan(pos2)
    expect(container.querySelector('#iteration-10')).not.toBeNull()
    expect(container.querySelector('#iteration-11')).not.toBeNull()
  })

  it('renders a decision section with its name and markdown body', () => {
    render(<Show {...DEFAULT_PROPS} />)
    // Decision name appears as a summary element
    expect(screen.queryByText('Grounds')).not.toBeNull()
    // Decision body rendered by Markdown (ReactMarkdown strips tags → plain text)
    expect(screen.queryByText('The grounds section body.')).not.toBeNull()
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
