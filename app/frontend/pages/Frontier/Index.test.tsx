import { render } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { SharedProps } from '@/types'

const props: SharedProps = { current_user: { id: 1, username: 'rooty', avatar_url: null }, flash: {} }
const pageProps: Record<string, unknown> = {}

vi.mock('@inertiajs/react', () => ({
  Head: (_props: { title?: string }) => null,
  Link: ({ children }: { children?: ReactNode }) => <a>{children}</a>,
  usePage: () => ({ props: { ...props, ...pageProps } }),
}))

vi.mock('@/layouts/AppLayout', () => ({
  default: ({ children }: { children?: ReactNode }) => <div>{children}</div>,
}))

import Index from './Index'

const base = {
  listing: {
    rows: [{ entry_id: 'e1', claim_seq: 1, need: 'a primary on X', uncertainty: 4, relevance: 5, mass: 20, opened_at: '' }],
    requested: 80, cap: 50, existed: 80,
  },
  mass: { open_entries: 7, mass: 21 },
  closure_classes: [{ state: 'closed', closure_type: 'fetch', n: 3 }],
  aging_bands: { under_1d: 1, '1d_to_7d': 2, '7d_to_30d': 3, over_30d: 1 },
  overhang: { surface: 'frontier', overhang: 40, capped_requests: 2 },
  filters: {},
}

function renderPage(page: Partial<typeof base> = {}) {
  Object.keys(pageProps).forEach((k) => delete pageProps[k])
  Object.assign(pageProps, base, page)
  return render(<Index />)
}

describe('Frontier/Index', () => {
  it('renders the mass fuse, the overhang badge, and the entries', () => {
    const { container } = renderPage()
    const text = container.textContent ?? ''
    expect(text).toContain('open 7 · mass 21')
    expect(text).toContain('overhang: 40')
    expect(text).toContain('K1')
    expect(text).toContain('a primary on X')
  })

  it('surfaces "showing N of M" (never silent truncation)', () => {
    const { container } = renderPage()
    expect(container.textContent).toContain('showing 1 of 80')
  })

  it('links the CSV export and the server-side filters', () => {
    const { container } = renderPage()
    const hrefs = Array.from(container.querySelectorAll('a')).map((a) => a.getAttribute('href'))
    expect(hrefs).toContain('/quests//frontier.csv')
    expect(hrefs.some((h) => h?.includes('sort=age'))).toBe(true)
  })
})
