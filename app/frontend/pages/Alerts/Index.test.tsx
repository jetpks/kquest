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
  fire_sets: [
    {
      predicate: 'tw_wedge',
      listing: {
        rows: [{ session_id: 's1', quest_id: 'q1', last_event_age_s: 4800, last_tool: 'web_search' }],
        requested: 1, cap: 20, existed: 1,
      },
    },
    { predicate: 'tw_churn', listing: { rows: [], requested: 0, cap: 20, existed: 0 } },
  ],
  metrics_panels: [
    { name: 'kquest_tripwire_fires', help: 'fires', type: 'counter', samples: [{ labels: { predicate: 'tw_wedge' }, value: 1 }] },
  ],
  quests: { rows: [{ id: 'q1', topic: 'the topic', state: 'active' }], requested: 1, cap: 20, existed: 1 },
  stream_url: '/alerts/stream',
  mute_state: [],
}

function renderPage(page: Partial<typeof base> = {}) {
  Object.keys(pageProps).forEach((k) => delete pageProps[k])
  Object.assign(pageProps, base, page)
  return render(<Index />)
}

describe('Alerts/Index', () => {
  it('renders the fire sets with their fire counts', () => {
    const { container } = renderPage()
    const text = container.textContent ?? ''
    expect(text).toContain('tw_wedge')
    expect(text).toContain('(1 firing)')
    expect(text).toContain('no fires')
  })

  it('offers the flash-only acknowledge (UI state only) and no mute control', () => {
    const { container } = renderPage()
    const form = container.querySelector('form')!
    expect(form.getAttribute('action')).toBe('/alerts/acknowledge')
    expect(form.querySelector('input[name="predicate"]')!.getAttribute('value')).toBe('tw_wedge')
    expect(form.querySelector('input[name="authenticity_token"]')).not.toBeNull()
    expect(container.textContent).not.toContain('mute')
    expect(container.textContent!.toLowerCase()).not.toContain('/console')
  })

  it('renders the reused Metrics panels and the per-quest stream links', () => {
    const { container } = renderPage()
    const text = container.textContent ?? ''
    expect(text).toContain('kquest_tripwire_fires')
    expect(text).toContain('the topic stream')
    const hrefs = Array.from(container.querySelectorAll('a')).map((a) => a.getAttribute('href'))
    expect(hrefs).toContain('/quests/q1/stream')
  })

  it('mounts the EventFeed on the user-level stream', () => {
    const { container } = renderPage()
    expect(container.querySelector('[data-testid="event-feed"]')!.textContent).toBe('/alerts/stream')
  })
})
