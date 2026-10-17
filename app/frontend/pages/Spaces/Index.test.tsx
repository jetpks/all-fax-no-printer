import { render } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { SpaceListItem, UnspacedBucket } from '@/types'

vi.mock('@inertiajs/react', () => ({
  Link: ({ href, children }: { href: string; children?: ReactNode }) => (
    <a href={href}>{children}</a>
  ),
  Head: (_props: { title?: string }) => null,
}))

vi.mock('@/layouts/AppLayout', () => ({
  default: ({ children }: { children?: ReactNode }) => <div>{children}</div>,
}))

import Index from './Index'

const SPACE: SpaceListItem = {
  id: 1,
  slug: 'test-space',
  title: 'Test Space',
  status: 'active',
  iterations_count: 2,
  conversations_count: 3,
  last_activity_at: '2026-06-28T21:32:12.278Z',
}

const BUCKET: UnspacedBucket = {
  cwd: '/home/eric/architect',
  conversations_count: 2,
  last_activity_at: '2026-06-28T21:32:12.278Z',
}

describe('Spaces/Index', () => {
  it('renders a link to each space', () => {
    const { container } = render(<Index spaces={[SPACE]} unspaced={[]} />)
    expect(container.querySelector('a[href="/spaces/1"]')).not.toBeNull()
  })

  it('renders empty state when no spaces', () => {
    const { container } = render(<Index spaces={[]} unspaced={[]} />)
    expect(container.textContent).toContain('No spaces yet')
  })

  it('renders the conversations count beside the iterations count', () => {
    const { container } = render(<Index spaces={[SPACE]} unspaced={[]} />)
    expect(container.textContent).toContain('2i')
    expect(container.textContent).toContain('3c')
  })

  it('renders the last activity timestamp for the space', () => {
    const { container } = render(<Index spaces={[SPACE]} unspaced={[]} />)
    expect(container.textContent).toContain('2026-06-28T21:32:12.278Z')
  })

  it('labels a space with no activity nil-safely', () => {
    const space: SpaceListItem = { ...SPACE, last_activity_at: null }
    const { container } = render(<Index spaces={[space]} unspaced={[]} />)
    expect(container.textContent).toContain('no activity yet')
  })

  it('renders the Unspaced section when the viewer has space-less buckets', () => {
    const { container } = render(<Index spaces={[SPACE]} unspaced={[BUCKET]} />)
    expect(container.textContent).toContain('Unspaced')
    expect(container.textContent).toContain('/home/eric/architect')
    expect(container.textContent).toContain('2c')
  })

  it('links each unspaced bucket to the conversations index filtered by cwd', () => {
    const { container } = render(<Index spaces={[SPACE]} unspaced={[BUCKET]} />)
    expect(container.querySelector('a[href="/conversations?cwd=%2Fhome%2Feric%2Farchitect"]')).not.toBeNull()
  })

  it('omits the Unspaced section when there are no buckets', () => {
    const { container } = render(<Index spaces={[SPACE]} unspaced={[]} />)
    expect(container.textContent).not.toContain('Unspaced')
  })
})
