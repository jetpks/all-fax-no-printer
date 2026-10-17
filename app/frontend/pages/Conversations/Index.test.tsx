import { render } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { ConversationListItem } from '@/types'

const { visit } = vi.hoisted(() => ({ visit: vi.fn() }))

vi.mock('@inertiajs/react', () => ({
  Link: ({ href, children }: { href: string; children?: ReactNode }) => (
    <a href={href}>{children}</a>
  ),
  Head: (_props: { title?: string }) => null,
  router: { visit },
}))

vi.mock('@/layouts/AppLayout', () => ({
  default: ({ children }: { children?: ReactNode }) => <div>{children}</div>,
}))

import Index from './Index'

const CONVERSATION: ConversationListItem = {
  id: 1,
  title: 'A conversation',
  status: 'completed',
  published: false,
  turns_count: 3,
  owned: true,
  agent_role: 'builder',
  agent_name: 'Deck Builder',
  model: 'claude',
  original_cwd: '/home/eric/architect',
  space_id: 2,
  updated_at: '2026-06-28T21:32:12.278Z',
}

const NO_PAGINATION = { page: 1, has_more: false }

function renderIndex(props: Partial<Parameters<typeof Index>[0]> = {}) {
  return render(
    <Index
      conversations={[CONVERSATION]}
      pagination={NO_PAGINATION}
      {...props}
    />,
  )
}

describe('Conversations/Index', () => {
  it('renders a link to each conversation', () => {
    const { container } = renderIndex()
    expect(container.querySelector('a[href="/conversations/1"]')).not.toBeNull()
  })

  it('renders empty state when no conversations', () => {
    const { container } = render(
      <Index conversations={[]} pagination={NO_PAGINATION} />,
    )
    expect(container.textContent).toContain('No conversations yet')
  })

  it('renders no pagination controls on a lone page', () => {
    const { queryByRole } = renderIndex()
    expect(queryByRole('button', { name: 'Next' })).toBeNull()
  })

  it('renders pagination controls from the prop when a further page exists', () => {
    const { getByRole } = render(
      <Index conversations={[CONVERSATION]} pagination={{ page: 1, has_more: true }} />,
    )
    expect(getByRole('button', { name: 'Next' })).not.toBeDisabled()
    expect(getByRole('button', { name: 'Prev' })).toBeDisabled()
  })

  it('renders the agent_role badge, model, and original_cwd on the row', () => {
    const { container } = renderIndex()
    expect(container.textContent).toContain('builder')
    expect(container.textContent).toContain('claude')
    expect(container.textContent).toContain('/home/eric/architect')
  })

  it('omits the agent_role badge for interactive (role-less) conversations', () => {
    const { container } = renderIndex({
      conversations: [{ ...CONVERSATION, agent_role: null }],
    })
    expect(container.textContent).not.toContain('builder')
  })

  it('renders a space context header when filtered by space', () => {
    const { container } = renderIndex({
      space: { id: 2, slug: 'my-space', title: 'My Space' },
    })
    expect(container.textContent).toContain('My Space')
    expect(container.textContent).toContain('my-space')
    expect(container.querySelector('a[href="/spaces/2"]')).not.toBeNull()
  })

  it('renders a cwd context header when filtered by cwd', () => {
    const { container } = renderIndex({ cwd: '/home/eric/architect' })
    expect(container.textContent).toContain('/home/eric/architect')
  })

  it('renders neither context header when unfiltered', () => {
    const { container } = renderIndex()
    expect(container.textContent).not.toContain('In space')
    expect(container.textContent).not.toContain('Working directory')
  })
})
