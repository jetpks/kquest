import { render } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { BriefingProps, SharedProps } from '@/types'

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

import Briefing from './Briefing'

const base: BriefingProps = {
  quest: { id: 'q1', topic: 'the briefed quest', state: 'active' },
  agenda: { rows: [{ id: 's1', urn: 'kb:src:abc', title: 'the agenda doc', added_at: '' }],
            requested: 1, cap: 30, existed: 1 },
  agenda_staged: true,
  session: { id: 'sess-uuid-1234', model: 'operator', started_at: '', phase_id: 'p1' },
  binding_phase_id: 'p1',
  binding_phase: 'decompose(1/1)',
  topic_questions: ['what is the scope?'],
  topic: 'the original topic',
  console_url: '/quests/q1/console',
  view_url: '/quests/q1',
}

function renderPage(page: Partial<typeof base> = {}) {
  props.current_user = { id: 1, username: 'rooty', avatar_url: null }
  Object.keys(pageProps).forEach((k) => delete pageProps[k])
  Object.assign(pageProps, base, page)
  return render(<Briefing />)
}

describe('Quests/Briefing', () => {
  it('renders the live session, the binding phase, and the staged gate honestly', () => {
    const { container } = renderPage()
    const text = container.textContent ?? ''
    expect(text).toContain('the briefed quest')
    expect(text).toContain('binding phase decompose(1/1)')
    expect(container.querySelector('[data-testid="agenda-staged-state"]')!.textContent)
      .toContain('STAGED')
    expect(text).toContain('what is the scope?')
    expect(text).toContain('the agenda doc')
  })

  it('renders the day-one empty state: no session, nothing staged, the honest gate wording', () => {
    const { container } = renderPage({
      agenda: { rows: [], requested: 0, cap: 30, existed: 0 },
      agenda_staged: false,
      session: null,
      binding_phase_id: null,
      binding_phase: null,
      topic_questions: [],
    })
    expect(container.querySelector('[data-testid="session-absent"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="agenda-staged-state"]')!.textContent)
      .toContain('not staged')
    expect(container.textContent).toContain('awaiting_briefing')
  })

  it('opens through the landed launch gate and signs off through the console/session/end door', () => {
    const live = renderPage()
    const liveActions = Array.from(live.container.querySelectorAll('form')).map((f) =>
      f.getAttribute('action')
    )
    expect(liveActions).not.toContain('/quests/q1/briefing/session') // the open form is gone while live
    expect(liveActions).toContain('/quests/q1/briefing/agenda')
    expect(liveActions).toContain('/quests/q1/briefing/questions')
    expect(liveActions).toContain('/quests/q1/console/session/end')
    const signOff = Array.from(live.container.querySelectorAll('form')).find(
      (f) => f.getAttribute('action') === '/quests/q1/console/session/end'
    )!
    expect(signOff.querySelector('input[name="_csrf_token"]')).not.toBeNull()

    const sessionless = renderPage({ session: null })
    const sessionlessActions = Array.from(sessionless.container.querySelectorAll('form')).map((f) =>
      f.getAttribute('action')
    )
    expect(sessionlessActions).toContain('/quests/q1/briefing/session')
  })

  it('disables the staging and questions controls without a live session (sign-off stays off too)', () => {
    const { container } = renderPage({ session: null })
    container.querySelectorAll('form').forEach((form) => {
      const action = form.getAttribute('action')!
      const button = form.querySelector('button')
      if (action === '/quests/q1/briefing/agenda' || action === '/quests/q1/briefing/questions' ||
          action === '/quests/q1/console/session/end') {
        expect(button?.hasAttribute('disabled'), `${action} disabled without a session`).toBe(true)
      }
    })
    const openButton = Array.from(container.querySelectorAll('form')).find(
      (f) => f.getAttribute('action') === '/quests/q1/briefing/session'
    )?.querySelector('button')
    expect(openButton?.hasAttribute('disabled')).toBe(false)
  })
})
