import { render, fireEvent } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'

const { visit } = vi.hoisted(() => ({ visit: vi.fn() }))

vi.mock('@inertiajs/react', () => ({
  router: { visit },
}))

import Pagination from './Pagination'

describe('Pagination', () => {
  it('renders nothing on a lone page', () => {
    const { container } = render(<Pagination pagination={{ page: 1, has_more: false }} path="/jobs" />)
    expect(container.firstChild).toBeNull()
  })

  it('renders controls when there is a further page', () => {
    const { getByRole } = render(<Pagination pagination={{ page: 1, has_more: true }} path="/jobs" />)
    expect(getByRole('button', { name: 'Prev' })).not.toBeNull()
    expect(getByRole('button', { name: 'Next' })).not.toBeNull()
  })

  it('renders controls on a page past the first even without a further page', () => {
    const { getByRole } = render(<Pagination pagination={{ page: 2, has_more: false }} path="/jobs" />)
    expect(getByRole('button', { name: 'Prev' })).not.toBeNull()
  })

  it('disables Prev on page 1', () => {
    const { getByRole } = render(<Pagination pagination={{ page: 1, has_more: true }} path="/jobs" />)
    expect(getByRole('button', { name: 'Prev' })).toBeDisabled()
  })

  it('disables Next when there is no further page', () => {
    const { getByRole } = render(<Pagination pagination={{ page: 2, has_more: false }} path="/jobs" />)
    expect(getByRole('button', { name: 'Next' })).toBeDisabled()
  })

  it('navigates to the next page via router.visit', () => {
    const { getByRole } = render(<Pagination pagination={{ page: 2, has_more: true }} path="/conversations" />)
    fireEvent.click(getByRole('button', { name: 'Next' }))
    expect(visit).toHaveBeenCalledWith('/conversations?page=3')
  })

  it('navigates to the previous page via router.visit', () => {
    const { getByRole } = render(<Pagination pagination={{ page: 2, has_more: true }} path="/conversations" />)
    fireEvent.click(getByRole('button', { name: 'Prev' }))
    expect(visit).toHaveBeenCalledWith('/conversations?page=1')
  })

  it('carries active filter params onto page links', () => {
    const { getByRole } = render(
      <Pagination
        pagination={{ page: 1, has_more: true }}
        path="/conversations"
        params={{ cwd: '/home/eric/architect' }}
      />,
    )
    fireEvent.click(getByRole('button', { name: 'Next' }))
    expect(visit).toHaveBeenCalledWith('/conversations?cwd=%2Fhome%2Feric%2Farchitect&page=2')
  })

  it('carries the space filter param onto page links', () => {
    const { getByRole } = render(
      <Pagination
        pagination={{ page: 2, has_more: true }}
        path="/conversations"
        params={{ space_id: '3' }}
      />,
    )
    fireEvent.click(getByRole('button', { name: 'Prev' }))
    expect(visit).toHaveBeenCalledWith('/conversations?space_id=3&page=1')
  })
})
