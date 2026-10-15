import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { ApiToken } from '@/types'

const { post } = vi.hoisted(() => ({ post: vi.fn() }))

vi.mock('@inertiajs/react', () => ({
  Link: ({ href, children }: { href: string; children?: ReactNode }) => (
    <a href={href}>{children}</a>
  ),
  Head: (_props: { title?: string }) => null,
  router: { post },
}))

vi.mock('@/layouts/AppLayout', () => ({
  default: ({ children }: { children?: ReactNode }) => <div>{children}</div>,
}))

import Index from './Index'

const TOKEN: ApiToken = {
  id: 1,
  name: 'laptop CLI',
  created_at: '2026-07-22T10:00:00Z',
  last_used_at: '2026-07-22T12:00:00Z',
  revoked_at: null,
}

const REVOKED: ApiToken = { ...TOKEN, id: 2, name: 'old CI', revoked_at: '2026-07-23T09:00:00Z' }

describe('ApiTokens/Index', () => {
  it('renders each token with name, created, and last-used labels', () => {
    const { container } = render(<Index tokens={[TOKEN]} />)
    expect(container.textContent).toContain('laptop CLI')
    expect(container.textContent).toContain('Created')
    expect(container.textContent).toContain('Last used')
  })

  it('renders a Revoked badge instead of a revoke button for revoked tokens', () => {
    render(<Index tokens={[REVOKED]} />)
    expect(screen.getByText('Revoked')).not.toBeNull()
    expect(screen.queryByRole('button', { name: 'Revoke' })).toBeNull()
  })

  it('renders a "New token" link to /api_tokens/new', () => {
    const { container } = render(<Index tokens={[]} />)
    expect(container.querySelector('a[href="/api_tokens/new"]')).not.toBeNull()
  })

  it('renders empty state when no tokens', () => {
    const { container } = render(<Index tokens={[]} />)
    expect(container.textContent).toContain('No API tokens yet')
  })

  it('revokes a token via POST /api_tokens/:id/delete after confirming', () => {
    render(<Index tokens={[TOKEN]} />)
    fireEvent.click(screen.getByRole('button', { name: 'Revoke' }))
    fireEvent.click(screen.getByRole('button', { name: 'Revoke' }))
    expect(post).toHaveBeenCalledWith('/api_tokens/1/delete')
  })
})
