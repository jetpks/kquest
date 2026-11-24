import { render } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import ShowingOf from './ShowingOf'
import type { CappedListing } from '@/types'

function listing(rows: number, requested: number, cap: number): CappedListing<unknown> {
  return { rows: Array.from({ length: rows }), requested, cap, existed: requested }
}

describe('ShowingOf', () => {
  it('renders "showing N of M" only when the listing was truncated', () => {
    const truncated = render(<ShowingOf listing={listing(10, 80, 50)} />)
    expect(truncated.getByTestId('showing-of').textContent).toBe('showing 10 of 80')

    const withinCap = render(<ShowingOf listing={listing(3, 3, 50)} />)
    expect(withinCap.container.querySelector('[data-testid="showing-of"]')).toBeNull()
  })

  it('renders nothing without a listing (the honest empty)', () => {
    const empty = render(<ShowingOf />)
    expect(empty.container.querySelector('[data-testid="showing-of"]')).toBeNull()
  })
})
