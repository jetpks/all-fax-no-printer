import { act, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { Conversation, Message as MessageType, Turn as TurnType } from '@/types'

vi.mock('@inertiajs/react', () => ({
  Head: (_props: { title?: string }) => null,
  Link: ({ href, children }: { href: string; children?: ReactNode }) => (
    <a href={href}>{children}</a>
  ),
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

vi.mock('@/layouts/AppLayout', () => ({
  default: ({ children }: { children?: ReactNode }) => <div>{children}</div>,
}))

// Isolate the live log; its own behavior is covered by LiveLog.test.tsx.
vi.mock('@/components/LiveLog', () => ({
  default: ({ conversationId }: { conversationId: number }) => (
    <div data-testid="live-log">live-log-{conversationId}</div>
  ),
}))

import Show from './Show'

const CONVERSATION: Conversation = {
  id: 5,
  title: 'Fix the frobnicator',
  status: 'completed',
  published: false,
  source: null,
  original_cwd: null,
  git_branch: null,
  agent_version: null,
  can_manage: false,
  owner: { username: 'eric', name: null, avatar_url: null },
  agent_role: null,
  agent_name: null,
  model: null,
  space_id: null,
}

function makeMessage(id: number, blocks: MessageType['blocks']): MessageType {
  return {
    id,
    role: 'assistant',
    model: null,
    position: id,
    published: false,
    can_publish: false,
    blocks,
  }
}

// A turn whose reply holds a narrative message and a decision-marked action
// message (an AskUserQuestion call), so the flat-body shape and the marker
// jump both have something real to land on.
function makeTurn(): TurnType {
  return {
    anchor_id: 12,
    prompt: makeMessage(21, [{ type: 'text', text: 'pick a color' }]),
    rounds: [
      {
        anchor_id: 22,
        messages: [
          makeMessage(22, [{ type: 'text', text: 'let me ask.' }]),
          makeMessage(23, [
            {
              type: 'tool_use',
              id: 'tu-1',
              name: 'AskUserQuestion',
              input: { questions: [{ header: 'Hue', question: 'Which hue?' }] },
            },
          ]),
        ],
      },
    ],
  }
}

function renderShow(conversation: Conversation, turns: TurnType[] = []) {
  return render(<Show conversation={conversation} turns={turns} />)
}

describe('Conversations/Show', () => {
  it('renders a parent link when parent is present', () => {
    const conversation = { ...CONVERSATION, parent: { id: 3, title: 'Parent session' } }
    renderShow(conversation)

    const link = screen.getByText('Parent session').closest('a')
    expect(link).not.toBeNull()
    expect(link).toHaveAttribute('href', '/conversations/3')
  })

  it('renders one link per child under "Subagent transcripts"', () => {
    const conversation = {
      ...CONVERSATION,
      children: [
        { id: 6, title: 'Subagent one', session_id: 'sess-a', agent_role: null },
        { id: 7, title: 'Subagent two', session_id: 'sess-b', agent_role: null },
      ],
    }
    renderShow(conversation)

    expect(screen.getByText('Subagent transcripts')).not.toBeNull()

    const linkOne = screen.getByText('Subagent one').closest('a')
    expect(linkOne).toHaveAttribute('href', '/conversations/6')

    const linkTwo = screen.getByText('Subagent two').closest('a')
    expect(linkTwo).toHaveAttribute('href', '/conversations/7')
  })

  it('renders neither section when parent/children are absent', () => {
    renderShow(CONVERSATION)

    expect(screen.queryByText('Subagent transcripts')).toBeNull()
    expect(screen.queryByText(/^part of/)).toBeNull()
  })

  it('renders neither section when children is empty', () => {
    renderShow({ ...CONVERSATION, parent: null, children: [] })

    expect(screen.queryByText('Subagent transcripts')).toBeNull()
    expect(screen.queryByText(/^part of/)).toBeNull()
  })

  it('shows the agent_role badge on each child that carries one', () => {
    const conversation = {
      ...CONVERSATION,
      children: [
        { id: 6, title: 'Subagent one', session_id: 'sess-a', agent_role: 'judge' },
        { id: 7, title: 'Subagent two', session_id: 'sess-b', agent_role: null },
      ],
    }
    renderShow(conversation)

    expect(screen.getByText('judge')).not.toBeNull()
  })
})

describe('Conversations/Show — live capture mount', () => {
  it('mounts the LiveLog when the capture is pending', () => {
    renderShow({ ...CONVERSATION, status: 'pending' })

    expect(screen.getByTestId('live-capture')).not.toBeNull()
    expect(screen.getByTestId('live-log')).not.toBeNull()
  })

  it('mounts the LiveLog when the capture is live', () => {
    renderShow({ ...CONVERSATION, status: 'live' })

    expect(screen.getByTestId('live-capture')).not.toBeNull()
    expect(screen.getByTestId('live-log')).not.toBeNull()
  })

  it('does not mount the live section once the capture is terminal', () => {
    for (const status of ['completed', 'failed']) {
      const { container } = renderShow({ ...CONVERSATION, status })
      expect(container.querySelector('[data-testid="live-capture"]')).toBeNull()
      expect(container.querySelector('[data-testid="live-log"]')).toBeNull()
    }
  })

  it('streams the mounted conversation by its id', () => {
    renderShow({ ...CONVERSATION, status: 'live' })

    expect(screen.getByTestId('live-log').textContent).toBe('live-log-5')
  })
})

describe('Conversations/Show — flat body', () => {
  afterEach(() => {
    window.location.hash = ''
  })

  it('renders one #turn-<anchorId> container per turn', () => {
    const turns: TurnType[] = [makeTurn(), { ...makeTurn(), anchor_id: 13 }]
    const { container } = renderShow({ ...CONVERSATION, status: 'completed' }, turns)

    const lis = container.querySelectorAll('li[data-turn-id]')
    expect(lis).toHaveLength(2)
    expect(container.querySelector('#turn-12')).not.toBeNull()
    expect(container.querySelector('#turn-13')).not.toBeNull()
  })

  it('hangs prompt-<id> on the prompt', () => {
    renderShow({ ...CONVERSATION, status: 'completed' }, [makeTurn()])

    expect(document.querySelector('#prompt-21')?.textContent).toContain('pick a color')
  })

  it('a marker deep link scrolls to and expands the target action row', () => {
    renderShow({ ...CONVERSATION, status: 'completed' }, [makeTurn()])
    // jsdom has no scrollIntoView.
    window.HTMLElement.prototype.scrollIntoView = vi.fn()

    // The decision row starts collapsed: the question text is not rendered.
    expect(screen.queryByText('Which hue?')).toBeNull()

    act(() => {
      window.location.hash = '#decision-23'
      window.dispatchEvent(new Event('hashchange'))
    })

    // The action row expanded in place — the question card is now rendered.
    expect(screen.getByText('Which hue?')).not.toBeNull()
  })

  it('a #round-<id> fragment degrades to #message-<id> (the round anchor is a message id)', () => {
    renderShow({ ...CONVERSATION, status: 'completed' }, [makeTurn()])
    window.HTMLElement.prototype.scrollIntoView = vi.fn()

    act(() => {
      window.location.hash = '#round-22'
      window.dispatchEvent(new Event('hashchange'))
    })

    // Rounds no longer render as containers; the flash lands on the message.
    expect(document.querySelector('.anchor-flash#message-22')).not.toBeNull()
  })

  it('no conversation-stream testid anywhere', () => {
    const { container } = renderShow({ ...CONVERSATION, status: 'live' }, [makeTurn()])

    expect(container.innerHTML).not.toContain('conversation-stream')
  })
})
