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

vi.mock('@/components/EventFeed', () => ({
  default: ({ url }: { url: string }) => <div data-testid="event-feed">{url}</div>,
}))

import Index from './Index'

const base = {
  panels: [
    { name: 'kquest_spend', help: 'token/cost sums', type: 'gauge', samples: [{ labels: { session_id: 's1' }, value: 1.24 }] },
    { name: 'kquest_cost_per_claim', help: 'cost per claim', type: 'gauge', samples: [{ labels: { quest_id: 'q1' }, value: 0.02 }] },
  ],
  ledger: {
    rows: [{ id: 'u1', created_at: '2026-11-24', kind: 'llm', model: 'test-model', input_tokens: 931000, output_tokens: 10, cost_usd: '1.2400', phase_id: 'p1', session_id: 's1' }],
    requested: 120, cap: 100, existed: 120,
  },
  budgets: { web_call_budget: 16, token_budget: 1000000, spend_budget_usd: '1.0' },
  stream_url: '/quests/q1/stream',
  filters: {},
}

function renderPage(page: Partial<typeof base> = {}) {
  Object.keys(pageProps).forEach((k) => delete pageProps[k])
  Object.assign(pageProps, base, page)
  return render(<Index />)
}

describe('Costs/Index', () => {
  it('renders the reused Metrics rollups', () => {
    const { container } = renderPage()
    const text = container.textContent ?? ''
    expect(text).toContain('kquest_spend')
    expect(text).toContain('kquest_cost_per_claim')
    expect(text).toContain('1.24')
  })

  it('echoes the budgets from the quest row and renders the capped ledger', () => {
    const { container } = renderPage()
    const text = container.textContent ?? ''
    expect(text).toContain('web 16')
    expect(text).toContain('test-model')
    expect(text).toContain('showing 1 of 120')
  })

  it('links the CSV export and mounts the live tail on the quest stream', () => {
    const { container } = renderPage()
    expect(container.querySelector('a')!.getAttribute('href')).toBe('/quests//costs.csv')
    expect(container.querySelector('[data-testid="event-feed"]')!.textContent).toBe('/quests/q1/stream')
  })

  it('renders no enforcement anywhere (reporting-only, I07 DR-08)', () => {
    const { container } = renderPage()
    const text = (container.textContent ?? '').toLowerCase()
    expect(text).not.toContain('throttle')
    expect(text).not.toContain('block')
  })
})
