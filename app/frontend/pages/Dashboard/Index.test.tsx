import { render } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { SharedProps } from '@/types'

// The Home page's test-mock pattern is the house pattern: usePage returns
// this object by reference, so the per-test shared props are written into it
// before each render; AppLayout is stubbed.
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

import Index from './Index'

function renderPage(shared: Partial<SharedProps> = {}, page: Record<string, unknown> = {}) {
  props.current_user = shared.current_user ?? null
  props.flash = shared.flash ?? {}
  Object.keys(pageProps).forEach((k) => delete pageProps[k])
  Object.assign(pageProps, page)
  return render(<Index />)
}

describe('Dashboard/Index', () => {
  it('renders the component through the inertia chassis (component Dashboard/Index)', () => {
    // The carried home assertion (Grounds §8): the ROOT action renders
    // Dashboard/Index — asserted backend-side in dashboard_index_test.rb; the
    // page side renders the anonymous prompt card.
    const { container } = renderPage()
    expect(container.textContent).toContain('kquest')
    expect(screen_text(container)).toContain('Sign in')
  })

  it('renders the pre-briefing create-quest form — the ONE dashboard write (I16 Part 3)', () => {
    // The operator-caught build miss (fixed inline 2026-11-24): the shipped
    // page had the route + server action but NO form. The standing lesson —
    // an affordance is pinned as a FORM (action + named fields), never just
    // a route.
    const { container } = renderPage(
      { current_user: { id: 1, username: 'rooty', avatar_url: null } },
      {
        quests: { rows: [], requested: 0, cap: 50, existed: 0 },
        blind_spots: [],
        overhang: [],
        workspaces: { workspaces: [], memberships: [], grants: [] },
      },
    )
    const form = container.querySelector('form[data-testid="create-quest-form"]')
    expect(form).not.toBeNull()
    expect(form!.getAttribute('method')).toBe('post')
    expect(form!.getAttribute('action')).toBe('/quests')
    for (const name of [
      'authenticity_token', 'topic', 'web_call_budget', 'token_budget',
      'spend_budget_usd', 'process_config', 'model_config',
    ]) {
      expect(form!.querySelector(`[name="${name}"]`), `field ${name}`).not.toBeNull()
    }
    expect(form!.querySelector('[name="topic"]')!.hasAttribute('required')).toBe(true)
    // The budget-semantics legend + the advanced-routing disclosure (the
    // operator's review: caps need their duration/behavior stated, and raw
    // JSON knobs belong behind an optional, honestly-hinted door).
    expect(screen_text(container)).toContain('whole-quest lifetime caps')
    expect(form!.querySelector('details[data-testid="advanced-routing"]')).not.toBeNull()
    expect(screen_text(container)).toContain('blank uses the engine')
    expect(screen_text(container)).toContain('No quests yet.')
  })

  it('keeps the create form off the anonymous card — login is the only anonymous door', () => {
    const { container } = renderPage({ current_user: null })
    expect(container.querySelector('form[action="/quests"]')).toBeNull()
  })

  it('carries the anonymous shared props as a 200 sign-in prompt card', () => {
    const { container } = renderPage({ current_user: null })
    expect(screen_text(container)).toContain('Sign in with the GitHub button above')
  })

  it('carries the signed-in shared props into the quest cards', () => {
    const { container } = renderPage(
      { current_user: { id: 1, username: 'rooty', avatar_url: null } },
      {
        quests: {
          rows: [{ id: 'q1', topic: 'the frozen topic', state: 'active', provenance_kind: 'fresh' }],
          requested: 1, cap: 50, existed: 1,
        },
        blind_spots: [],
        overhang: [],
        workspaces: { workspaces: [], memberships: [], grants: [] },
      },
    )
    expect(screen_text(container)).toContain('the frozen topic')
    expect(screen_text(container)).toContain('Blind spots')
    expect(screen_text(container)).toContain('ENFORCED')
    expect(screen_text(container)).not.toContain('Sign in with the GitHub button above')
  })

  it('surfaces the overhang join and the capped-listing "showing N of M"', () => {
    const { container } = renderPage(
      { current_user: { id: 1, username: 'rooty', avatar_url: null } },
      {
        quests: {
          rows: [{ id: 'q1', topic: 't', state: 'active', provenance_kind: 'fresh' }],
          requested: 80, cap: 50, existed: 80,
        },
        blind_spots: [],
        overhang: [{ surface: 'frontier', overhang: 40, capped_requests: 2 }],
        workspaces: { workspaces: [], memberships: [], grants: [] },
      },
    )
    expect(screen_text(container)).toContain('showing 1 of 80')
    expect(screen_text(container)).toContain('frontier: 40 over 2 capped request(s)')
  })

  function screen_text(container: HTMLElement) {
    return container.textContent ?? ''
  }
})
