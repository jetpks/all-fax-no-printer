import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi, beforeEach } from 'vitest'

let formData: Record<string, unknown>
let formErrors: Record<string, string>
const setData = vi.fn((key: string, value: unknown) => {
  formData = { ...formData, [key]: value }
})
const post = vi.fn()

vi.mock('@inertiajs/react', () => ({
  Head: (_props: { title?: string }) => null,
  useForm: () => ({
    data: formData,
    errors: formErrors,
    processing: false,
    setData,
    post,
  }),
}))

vi.mock('@/layouts/AppLayout', () => ({
  default: ({ children }: { children?: ReactNode }) => <div>{children}</div>,
}))

import type { ReactNode } from 'react'
import New from './New'

beforeEach(() => {
  formData = { name: '' }
  formErrors = {}
  setData.mockClear()
  post.mockClear()
})

describe('ApiTokens/New', () => {
  it('renders the name field', () => {
    render(<New />)
    expect(screen.getByText('Name')).not.toBeNull()
  })

  it('typing a name sets it via setData', () => {
    render(<New />)
    fireEvent.change(screen.getByPlaceholderText('laptop CLI'), { target: { value: 'ci box' } })
    expect(setData).toHaveBeenCalledWith('name', 'ci box')
  })

  it('submits by posting the name to /api_tokens', () => {
    formData = { name: 'ci box' }
    render(<New />)
    fireEvent.submit(screen.getByRole('button', { name: 'Create token' }).closest('form')!)
    expect(post).toHaveBeenCalledWith('/api_tokens')
  })

  it('renders a field error when present', () => {
    formErrors = { name: 'must be filled' }
    render(<New />)
    expect(screen.getByText('must be filled')).not.toBeNull()
  })

  it('renders the minted secret exactly once with a store-it-now warning', () => {
    const { container } = render(
      <New minted={{ name: 'ci box', secret: 'sat_abc123' }} />,
    )
    expect(container.textContent).toContain('sat_abc123')
    expect(container.textContent).toContain('only once')
    expect(container.textContent.match(/sat_abc123/g)).toHaveLength(1)
  })

  it('hides the form once a token is minted', () => {
    render(<New minted={{ name: 'ci box', secret: 'sat_abc123' }} />)
    expect(screen.queryByText('Name')).toBeNull()
    expect(screen.queryByRole('button', { name: 'Create token' })).toBeNull()
  })
})
