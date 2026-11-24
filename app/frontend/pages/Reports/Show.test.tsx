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

import Show from './Show'

const pinned = 'a'.repeat(64)
const live = 'b'.repeat(64)

const base = {
  versions: {
    rows: [{
      id: 'v1', version_seq: 2, standing: true, bound_at: '2026-11-24', binding_pass: 'pass-1',
      model: 'test-model', quest_fingerprint: pinned,
      body_url: '/quests/q1/report/versions/2/body',
    }],
    requested: 1, cap: 50, existed: 1,
  },
  standing: null as unknown,
  citations: [{ id: 'c1', ordinal: 1, source_id: 'src1', imported_source_id: null }],
  binding_index: [{ id: 'src1', urn: 'kb:src:abc', title: 'A primary', canonical_url: 'https://example.test' }],
  import_manifest: [],
  staleness: { stale: false, pinned_fingerprint: null, live_fingerprint: live },
  stop_markers: [],
}

function renderPage(page: Record<string, unknown> = {}) {
  Object.keys(pageProps).forEach((k) => delete pageProps[k])
  const merged = { ...base, ...page }
  merged.standing = merged.versions.rows[0]
  Object.assign(pageProps, merged)
  return render(<Show />)
}

describe('Reports/Show', () => {
  it('renders the version chain with body download links', () => {
    const { container } = renderPage()
    const text = container.textContent ?? ''
    expect(text).toContain('v2')
    expect(text).toContain('standing')
    expect(container.textContent).toContain('download body')
    const hrefs = Array.from(container.querySelectorAll('a')).map((a) => a.getAttribute('href'))
    expect(hrefs).toContain('/quests/q1/report/versions/2/body')
  })

  it('shows the staleness banner only when pinned ≠ live (DETECTED, not prevented)', () => {
    const clean = renderPage({ staleness: { stale: false, pinned_fingerprint: pinned, live_fingerprint: pinned } })
    expect(clean.container.textContent).not.toContain('Stale')
    clean.unmount()
    const stale = renderPage({ staleness: { stale: true, pinned_fingerprint: pinned, live_fingerprint: live } })
    expect(stale.container.textContent).toContain('Stale')
    expect(stale.container.textContent).toContain('DETECTED, not prevented')
  })

  it('renders the citation ordinals and the binding manifest', () => {
    const { container } = renderPage()
    const text = container.textContent ?? ''
    expect(text).toContain('[^1]')
    expect(text).toContain('1 corpus source(s)')
  })

  it('renders the arc stop markers (CUT AT MASS / DRAINED / STOPPED-LOUD distinguished forever)', () => {
    const { container } = renderPage({
      stop_markers: [{ rule_id: 'SR-02', phase_no: 3, phase_kind: 'descent', reason: 'web budget exhausted', route: 'route-to-synthesis' }],
    })
    expect(container.textContent).toContain('SR-02 at phase 3 (descent)')
    expect(container.textContent).toContain('route: route-to-synthesis')
  })
})
