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
import type { AlertsProps } from './Index'

const base: AlertsProps = {
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

  it('offers the flash-only acknowledge (UI state only) and the I17 mute control', () => {
    const { container } = renderPage()
    const ack = container.querySelector('form')!
    expect(ack.getAttribute('action')).toBe('/alerts/acknowledge')
    expect(ack.querySelector('input[name="predicate"]')!.getAttribute('value')).toBe('tw_wedge')
    expect(ack.querySelector('input[name="authenticity_token"]')).not.toBeNull()
    // the I17 additions: the mute/unmute control POSTs the console's mute
    // route (the ONE config-row write, per quest from the quests listing)
    const mute = container.querySelector('[data-testid="mute-control-q1"]')!
    expect(mute.getAttribute('action')).toBe('/quests/q1/console/mute')
    expect(mute.querySelector('input[name="authenticity_token"]')).not.toBeNull()
    expect(mute.querySelector('button[name="remove"][value="true"]')).not.toBeNull()
  })

  it('renders the alerting→console pre-load link per fire-set row with a quest', () => {
    const { container } = renderPage()
    const hrefs = Array.from(container.querySelectorAll('a')).map((a) => a.getAttribute('href'))
    expect(hrefs).toContain('/quests/q1/console?alert=tw_wedge')
  })

  it('renders the mute state panel who/why — never hidden, honest when empty', () => {
    const empty = renderPage({ mute_state: [] })
    expect(empty.container.querySelector('[data-testid="mute-state"]')!.textContent)
      .toContain('none — every signal renders.')
    const muted = renderPage({
      mute_state: [{ key: 'alerts.mute.q1.tw_wedge', text_value: 'slow local model',
                     provenance: 'operator u1 2026-11-25T00:00:00Z — slow local model' }],
    })
    const text = muted.container.querySelector('[data-testid="mute-state"]')!.textContent ?? ''
    expect(text).toContain('alerts.mute.q1.tw_wedge')
    expect(text).toContain('operator u1 2026-11-25T00:00:00Z — slow local model')
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
