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

import Browser from './Browser'

const base = {
  claims: { rows: [{ id: 'c1', quest_seq: 1, text: 'the claim text', terminal_type: null, urn: 'kb:claim:abc' }], requested: 1, cap: 50, existed: 1 },
  evidence: { rows: [], requested: 0, cap: 50, existed: 0 },
  edges: { rows: [], requested: 0, cap: 50, existed: 0 },
  derivations: { rows: [], requested: 0, cap: 50, existed: 0 },
  closure: { rows: [], requested: 0, cap: 50, existed: 0 },
  lineage: [],
  hub: {
    reused: { rows: [{ canonical_text: 'shared claim', terminal_type: null, quest_count: 2, type_divergent: false }], requested: 1, cap: 50, existed: 1 },
    type_divergent: { rows: [{ canonical_text: 'divergent claim', terminal_type: 'primary-empirical', quest_count: 3 }], requested: 1, cap: 50, existed: 1 },
  },
  conflicts: {
    conflicts: { rows: [{ id: 'cf1', claim_id: 'c1', divergence: 'the sources disagree', resolution_hypothesis: null }], requested: 1, cap: 50, existed: 1 },
    sources: [{ conflict_id: 'cf1', source_id: 'src1' }],
  },
}

function renderPage(page: Partial<typeof base> & { node?: unknown } = {}) {
  Object.keys(pageProps).forEach((k) => delete pageProps[k])
  Object.assign(pageProps, base, page)
  return render(<Browser />)
}

describe('Graph/Browser', () => {
  it('renders claims with traversal links and the hub tab', () => {
    const { container } = renderPage()
    const text = container.textContent ?? ''
    expect(text).toContain('the claim text')
    expect(text).toContain('Cross-quest hub')
    expect(text).toContain('divergent claim')
    const href = container.querySelector('a')!.getAttribute('href')
    expect(href).toContain('/graph?node=c1')
  })

  it('renders the read-only conflicts docket naming I17 for adjudication', () => {
    const { container } = renderPage()
    const text = container.textContent ?? ''
    expect(text).toContain('the sources disagree')
    expect(text).toContain('adjudication is I17')
  })

  it('renders the node traversal (neighborhood + derivation paths) when ?node= is present', () => {
    const { container } = renderPage({
      node: {
        claim: { id: 'c1', quest_seq: 1, text: 'the claim text', terminal_type: null, urn: 'kb:claim:abc' },
        neighborhood: [{ node_kind: 'evidence', node_id: 'ev1', depth: 1, preview: '…' }],
        derivation_paths: { terminals: [], max_depth: 2, truncated: false },
        near_dups: [{ claim_id: 'c9', quest_seq: 9, terminal_type: null }],
      },
    })
    const text = container.textContent ?? ''
    expect(text).toContain('Node K1')
    expect(text).toContain('neighborhood: 1 node(s)')
    expect(text).toContain('reach depth 2')
    expect(text).toContain('near-dup candidates: 1')
  })
})
