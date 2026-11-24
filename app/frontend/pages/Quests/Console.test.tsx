import { render } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { ConsoleProps, SharedProps } from '@/types'

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

import Console from './Console'

const menu = {
  id: 'transcript-ceiling',
  trigger: { rule_ids: ['SR-16'], note: 'PROCESS_STOP: SR-16 …' },
  options: [
    { id: 'swap-at-the-wall', label: 'swap at the wall' },
    { id: 'compact-and-continue', label: 'compact-and-continue' },
    { id: 'refuse-and-report', label: 'refuse-and-report' },
  ],
  evidence: { stop_rule: { rule_id: 'SR-16', config_key: 'engine.transcript_ceiling_hard_bytes' } },
}

const base: ConsoleProps = {
  quest: {
    id: 'q1', topic: 'the steered quest', state: 'paused',
    web_call_budget: 16, token_budget: 1000000, spend_budget_usd: '1.00',
    process_config: { keep: 1 }, model_config: { decompose: 'planner-x' },
  },
  parity_line:
    'quest_status: quest=paused phase=- writer=- web_calls=3/16 tokens=12k/1.0M spend_usd=0.10/1.00',
  menus: [menu],
  alert_param: null,
  ladder_passes: {
    rows: [{ id: 'l1', model: 'planner-x', rung: 'full', serving_stack: 's', passed_at: 't',
             evidence_ref: 'rung=full', passed_by: 'the rig' }],
    requested: 1, cap: 50, existed: 1,
  },
  stop_rules: [{ rule_id: 'SR-16', scope: 'quest', metric: 'transcript', default: '450000.0',
                 operator: '>=', action: 'pause-and-present',
                 config_key: 'engine.transcript_ceiling_hard_bytes' }],
  lifecycle: {
    rows: [{ id: 'e1', from_state: 'active', to_state: 'paused', actor: 'orchestrator',
             occurred_at: '', note: 'PROCESS_STOP: SR-16 …' }],
    requested: 1, cap: 50, existed: 1,
  },
  mutes: { rows: [], requested: 0, cap: 50, existed: 0 },
  session: null,
  stream_url: '/quests/q1/stream',
  view_url: '/quests/q1',
  briefing_url: '/quests/q1/briefing',
}

function renderPage(page: Partial<typeof base> = {}) {
  props.current_user = { id: 1, username: 'rooty', avatar_url: null }
  Object.keys(pageProps).forEach((k) => delete pageProps[k])
  Object.assign(pageProps, base, page)
  return render(<Console />)
}

describe('Quests/Console', () => {
  it('renders the state banner, the shared parity line, and the live view on the frozen stream URL', () => {
    const { container } = renderPage()
    const text = container.textContent ?? ''
    expect(text).toContain('the steered quest')
    expect(text).toContain('state paused')
    expect(text).toContain(base.parity_line)
    expect(container.querySelector('[data-testid="event-feed"]')!.textContent).toBe('/quests/q1/stream')
  })

  it('renders the presented menus with their evidence and option labels — never a picker default', () => {
    const { container } = renderPage()
    expect(container.querySelector('[data-testid="menu-transcript-ceiling"]')).not.toBeNull()
    const text = container.textContent ?? ''
    expect(text).toContain('swap at the wall')
    expect(text).toContain('engine.transcript_ceiling_hard_bytes')
    // the evidence echoes the crossed config row, not a hardcoded literal
    expect(text).toContain('SR-16')
    // the mute select renders a blank lead option and no default value anywhere
    const select = container.querySelector('select[name="predicate"]') as HTMLSelectElement
    expect(select.options[0].value).toBe('')
    expect(select.value).toBe('')
    Array.from(container.querySelectorAll('input, select, textarea')).forEach((el) => {
      const v = (el as HTMLInputElement).defaultValue
      expect(v === undefined || v === '').toBe(true)
    })
  })

  it('disables every steering control while active, rendering the pause door only', () => {
    const { container } = renderPage({ quest: { ...base.quest, state: 'active' }, menus: [] })
    const forms = Array.from(container.querySelectorAll('form')).map((f) => f.getAttribute('action'))
    expect(forms).toContain('/quests/q1/pause')
    const doorForms = forms.filter((a) => a !== '/quests/q1/pause')
    expect(doorForms.length).toBeGreaterThan(0)
    container.querySelectorAll('form button').forEach((b) => {
      const action = b.closest('form')!.getAttribute('action')!
      if (action !== '/quests/q1/pause') {
        expect(b.hasAttribute('disabled'), `${action} must be disabled while active`).toBe(true)
      }
    })
  })

  it('renders the doors enabled per state when paused (resume open, stop open, restart closed)', () => {
    const { container } = renderPage()
    const resumeButton = container.querySelector('[data-testid="resume-form"] button') as HTMLButtonElement
    const stopButton = container.querySelector('[data-testid="stop-form"] button') as HTMLButtonElement
    const restartButton = container.querySelector('[data-testid="restart-form"] button') as HTMLButtonElement
    const endButton = container.querySelector('[data-testid="session-end-form"] button') as HTMLButtonElement
    expect(resumeButton.disabled).toBe(false)
    expect(stopButton.disabled).toBe(false)
    expect(restartButton.disabled).toBe(true)
    expect(endButton.disabled).toBe(true) // no open operator session
  })

  it('renders the ladder evidence beside the routing map with showing-of on truncated listings', () => {
    const { container } = renderPage({
      lifecycle: { rows: [], requested: 80, cap: 50, existed: 80 },
      ladder_passes: { ...base.ladder_passes, rows: [], requested: 60, cap: 50 },
    })
    const text = container.textContent ?? ''
    expect(text).toContain('showing 0 of 80')
    expect(text).toContain('showing 0 of 60')
  })

  it('renders the stop_rules echo, the mute rows with provenance, and the steering history', () => {
    const { container } = renderPage({
      mutes: {
        rows: [{ key: 'alerts.mute.q1.tw_churn', text_value: 'slow local model',
                 provenance: 'operator u1 2026-11-25T00:00:00Z — slow local model' }],
        requested: 1, cap: 50, existed: 1,
      },
    })
    const text = container.textContent ?? ''
    expect(text).toContain('engine.transcript_ceiling_hard_bytes')
    expect(text).toContain('alerts.mute.q1.tw_churn')
    expect(text).toContain('operator u1 2026-11-25T00:00:00Z')
    expect(text).toContain('PROCESS_STOP: SR-16')
  })

  it('renders the adjudication menu with the docket link and the not-muteable posture', () => {
    const { container } = renderPage({
      menus: [{
        id: 'adjudication',
        trigger: { alert: 'tw_hub_divergence' },
        options: [{ id: 'open-the-docket', label: 'open the courtroom docket' }],
        evidence: { alert: 'tw_hub_divergence', browser_url: '/quests/q1/graph', muteable: false },
      }],
    })
    const hrefs = Array.from(container.querySelectorAll('a')).map((a) => a.getAttribute('href'))
    expect(hrefs).toContain('/quests/q1/graph')
  })
})
