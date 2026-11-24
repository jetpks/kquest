import { render } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { SharedProps } from '@/types'

// The house page-test pattern (the Home page's mocks + AppLayout stub).
const props: SharedProps = { current_user: null, flash: {} }
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

import Show from './Show'

const base = {
  quest: {
    id: 'q1', topic: 'the frozen topic', state: 'active', provenance_kind: 'fresh',
    process_config: { a: 1 }, model_config: { planner: 'x' },
  },
  parity_line:
    'quest_status: quest=active phase=descent(3/1) writer=session/8f3a web_calls=42/1400 ' +
    'tokens=931k/2.0M spend_usd=1.24/5.00',
  lifecycle: { rows: [{ id: 'e1', from_state: 'active', to_state: 'paused', actor: 'operator', occurred_at: '', note: 'ui pause door' }], requested: 1, cap: 50, existed: 1 },
  sessions: { rows: [{ id: 's1', mode: 'autonomous', driver: 'orchestrator', model: 'm', started_at: '', ended_at: null }], requested: 1, cap: 50, existed: 1 },
  phases: { rows: [{ id: 'p1', kind: 'descent', round_no: 3, attempt_no: 1, state: 'complete', started_at: '', ended_at: '' }], requested: 1, cap: 50, existed: 1 },
  counters: { unmined_citable: 2, frontier_open: 7, frontier_mass: 21 },
  fingerprint: 'a'.repeat(64),
  stream_url: '/quests/q1/stream',
  frontier_url: '/quests/q1/frontier',
  graph_url: '/quests/q1/graph',
  report_url: '/quests/q1/report',
}

function renderPage(page: Partial<typeof base> = {}) {
  props.current_user = { id: 1, username: 'rooty', avatar_url: null }
  Object.keys(pageProps).forEach((k) => delete pageProps[k])
  Object.assign(pageProps, base, page)
  return render(<Show />)
}

describe('Quests/Show', () => {
  it('echoes the parity block byte-faithfully (composed through the shared formatter server-side)', () => {
    const { container } = renderPage()
    expect(container.textContent).toContain(base.parity_line)
  })

  it('renders the capped lists with their "showing N of M" when truncated', () => {
    const { container } = renderPage({
      lifecycle: { ...base.lifecycle, rows: [], requested: 80, cap: 50 },
    })
    expect(container.textContent).toContain('showing 0 of 80')
  })

  it('renders the counters, fingerprint, config read-only, and the surface links', () => {
    const { container } = renderPage()
    const text = container.textContent ?? ''
    expect(text).toContain('unmined citable: 2')
    expect(text).toContain('frontier mass: 21')
    expect(text).toContain('a'.repeat(64))
    expect(text).toContain('read-only')
    const hrefs = Array.from(container.querySelectorAll('a')).map((a) => a.getAttribute('href'))
    expect(hrefs).toContain('/quests/q1/frontier')
    expect(hrefs).toContain('/quests/q1/graph')
    expect(hrefs).toContain('/quests/q1/report')
  })

  it('posts the lifecycle door through the csrf idiom and never renders console/briefing stubs', () => {
    const { container } = renderPage()
    const forms = Array.from(container.querySelectorAll('form'))
    expect(forms.map((f) => f.getAttribute('action'))).toEqual([
      '/quests/q1/pause', '/quests/q1/resume', '/quests/q1/archive',
    ])
    expect(forms[0].querySelector('input[name="authenticity_token"]')).not.toBeNull()
    expect(container.textContent).not.toContain('/console')
    expect(container.textContent).not.toContain('/briefing')
  })

  it('mounts the EventFeed on the I15 frozen stream URL', () => {
    const { container } = renderPage()
    expect(container.querySelector('[data-testid="event-feed"]')!.textContent).toBe('/quests/q1/stream')
  })
})
