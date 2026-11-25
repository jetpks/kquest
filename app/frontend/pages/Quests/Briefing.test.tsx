import { act, render } from '@testing-library/react'
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import type { ReactNode } from 'react'
import type { BriefingProps, SharedProps } from '@/types'

// The house page-test pattern (the Home page's mocks + AppLayout stub), plus
// the TWO live wires the chat page owns: a mocked router (the Inertia reload
// the SSE frames trigger) and a mocked EventSource (the EventFeed guard
// pattern — jsdom has none, the tests install one).
const props: SharedProps = { current_user: null, flash: {} }
const pageProps: Record<string, unknown> = {}
// vi.mock factories are HOISTED above imports — the router mock must come
// from vi.hoisted to exist when the factory runs.
const { reload } = vi.hoisted(() => ({ reload: vi.fn() }))

vi.mock('@inertiajs/react', () => ({
  Head: (_props: { title?: string }) => null,
  Link: ({ children }: { children?: ReactNode }) => <a>{children}</a>,
  usePage: () => ({ props: { ...props, ...pageProps } }),
  router: { reload },
}))

vi.mock('@/layouts/AppLayout', () => ({
  default: ({ children }: { children?: ReactNode }) => <div>{children}</div>,
}))

import Briefing from './Briefing'

// jsdom has no EventSource — the EventFeed test's mock: it records the
// subscribed URL and lets a test push frames through onmessage.
class MockEventSource {
  static instances: MockEventSource[] = []
  static lastUrl = ''
  url: string
  onmessage: ((e: MessageEvent<string>) => void) | null = null
  closed = false

  constructor(url: string) {
    this.url = url
    MockEventSource.lastUrl = url
    MockEventSource.instances.push(this)
  }

  close() {
    this.closed = true
  }

  push(id: string, data: string) {
    this.onmessage?.({ data, lastEventId: id } as MessageEvent<string>)
  }
}

const OriginalEventSource = window.EventSource

const base: BriefingProps = {
  quest: { id: 'q1', topic: 'the briefed quest', state: 'active' },
  session: { id: 'sess-uuid-1234', model: 'operator', started_at: '', phase_id: 'p1' },
  agenda: { rows: [{ id: 's1', urn: 'kb:src:abc', title: 'the agenda doc', added_at: '' }],
            requested: 1, cap: 30, existed: 1 },
  agenda_staged: true,
  topic_questions: ['what is the scope?', 'how fast does it decay?'],
  topic: 'momentum decay',
  transcript: {
    lines: [
      { kind: 'operator', body: 'scope the decay question' },
      { kind: 'tool_call', tool: 'web_search', excerpt: '{"query":"decay"}' },
      { kind: 'tool_result', tool: 'web_search', excerpt: '3 results', is_error: false },
      { kind: 'final', body: 'Staged the primer — refine anything?' },
    ],
    omitted: 2,
  },
  queued: [{ id: 't9', seq: 1, body: 'and the second half?', created_at: '' }],
  binding_phase_id: 'p1',
  binding_phase: 'decompose(1/1)',
  stream_url: '/quests/q1/stream',
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
  beforeEach(() => {
    ;(window as unknown as { EventSource: unknown }).EventSource = MockEventSource
  })
  afterEach(() => {
    window.EventSource = OriginalEventSource
    MockEventSource.instances = []
    reload.mockClear()
    vi.restoreAllMocks()
  })

  it('renders the transcript lines from the fixture props (operator right, agent left, tools between)', () => {
    const { container } = renderPage()
    const chat = container.querySelector('[data-testid="chat-transcript"]')!
    expect(chat.textContent).toContain('scope the decay question')
    expect(chat.textContent).toContain('Staged the primer — refine anything?')
    expect(chat.textContent).toContain('web_search')
    expect(chat.textContent).toContain('3 results')
    // the honest omitted count (L15 — never silent truncation)
    expect(chat.textContent).toContain('showing the last 4 of 6 lines')
    // the operator turns are visually distinct (the right-aligned primary bubble)
    expect(chat.querySelectorAll('.justify-end')).not.toHaveLength(0)
    expect(chat.querySelectorAll('.justify-start')).not.toHaveLength(0)
  })

  it('pins the send form: it posts the body to the turns door carrying _csrf_token', () => {
    const { container } = renderPage()
    const form = Array.from(container.querySelectorAll('form')).find(
      (f) => f.getAttribute('action') === '/quests/q1/briefing/turns'
    )
    expect(form, 'the send form is the affordance — never route + action alone').not.toBeNull()
    expect(form!.getAttribute('method')).toBe('post')
    expect(form!.querySelector('input[name="_csrf_token"]')).not.toBeNull()
    expect(form!.querySelector('textarea[name="body"]')).not.toBeNull()
  })

  it('renders a still-enqueued turn as queued', () => {
    const { container } = renderPage()
    const queued = container.querySelector('[data-testid="queued-turns"]')!
    expect(queued.textContent).toContain('#1')
    expect(queued.textContent).toContain('and the second half?')
  })

  it('renders the context strip: agenda list, gate state, topic questions, topic — NOT forms', () => {
    const { container } = renderPage()
    const strip = container.querySelector('[data-testid="context-strip"]')!
    expect(strip.textContent).toContain('the agenda doc')
    expect(strip.textContent).toContain('kb:src:abc')
    expect(strip.textContent).toContain('what is the scope?')
    expect(strip.textContent).toContain('momentum decay')
    // context, never forms: NO input/textarea/select anywhere in the strip
    expect(strip.querySelectorAll('input, textarea, select')).toHaveLength(0)
    expect(container.querySelector('[data-testid="agenda-staged-state"]')!.textContent)
      .toContain('STAGED')
  })

  it('renders the gate honestly both ways', () => {
    const staged = renderPage()
    expect(staged.container.querySelector('[data-testid="agenda-staged-state"]')!.textContent)
      .toContain('STAGED')
    expect(staged.container.querySelector('[data-testid="gate-honesty"]')!.textContent)
      .toContain('the orchestrator resumes')

    const unstaged = renderPage({
      agenda: { rows: [], requested: 0, cap: 30, existed: 0 },
      agenda_staged: false,
    })
    expect(unstaged.container.querySelector('[data-testid="agenda-staged-state"]')!.textContent)
      .toContain('not staged')
    expect(unstaged.container.textContent).toContain('awaiting_briefing')
    expect(unstaged.container.querySelector('[data-testid="gate-honesty"]')!.textContent)
      .toContain('awaiting_briefing')
  })

  it('opens through the launch gate and signs off through the console door, disabled without a session', () => {
    const { container } = renderPage()
    const actions = Array.from(container.querySelectorAll('form')).map((f) => f.getAttribute('action'))
    // live: the open-session form is gone (the session IS open), the sign-off form is present + enabled
    expect(actions).not.toContain('/quests/q1/briefing/session')
    const signOff = Array.from(container.querySelectorAll('form')).find(
      (f) => f.getAttribute('action') === '/quests/q1/console/session/end'
    )
    expect(signOff).not.toBeNull()
    expect(signOff!.querySelector('input[name="_csrf_token"]')).not.toBeNull()
    expect(signOff!.querySelector('button')!.hasAttribute('disabled')).toBe(false)

    const sessionless = renderPage({ session: null })
    const sActions = Array.from(sessionless.container.querySelectorAll('form')).map((f) =>
      f.getAttribute('action')
    )
    expect(sActions).toContain('/quests/q1/briefing/session')
    const sSignOff = Array.from(sessionless.container.querySelectorAll('form')).find(
      (f) => f.getAttribute('action') === '/quests/q1/console/session/end'
    )!
    expect(sSignOff.querySelector('button')!.hasAttribute('disabled')).toBe(true)
    expect(sessionless.container.querySelector('[data-testid="session-absent"]')).not.toBeNull()
  })

  it('the staging forms are GONE: no staging vocabulary anywhere in the tree', () => {
    const { container } = renderPage()
    const actions = Array.from(container.querySelectorAll('form')).map((f) => f.getAttribute('action'))
    expect(actions).not.toContain('/quests/q1/briefing/agenda')
    expect(actions).not.toContain('/quests/q1/briefing/questions')
    const html = container.innerHTML
    expect(html).not.toContain('briefing/agenda')
    expect(html).not.toContain('briefing/questions')
    // no url/title/document-text inputs, no questions[] inputs, no topic-freeze box
    expect(container.querySelector('input[name="url"]')).toBeNull()
    expect(container.querySelector('input[name="title"]')).toBeNull()
    expect(container.querySelector('textarea[name="text"]')).toBeNull()
    expect(container.querySelector('input[name="questions[]"]')).toBeNull()
    expect(container.querySelector('input[name="topic"]')).toBeNull()
    // live: the sign-off + send forms only (the open-session form is gone while live)
    expect(container.querySelectorAll('form')).toHaveLength(2)
    // sessionless: the open-session + sign-off + send forms
    const sessionlessForms = renderPage({ session: null }).container.querySelectorAll('form')
    expect(sessionlessForms).toHaveLength(3)
  })

  it('subscribes ONE EventSource to the frozen stream URL and reloads the props on EVERY event', () => {
    const { unmount } = renderPage()
    expect(MockEventSource.instances).toHaveLength(1)
    expect(MockEventSource.lastUrl).toBe('/quests/q1/stream')
    const source = MockEventSource.instances[0]
    act(() => { source.push('1-1', JSON.stringify({ type: 'tool.event' })) })
    expect(reload).toHaveBeenCalledTimes(1)
    act(() => { source.push('1-2', JSON.stringify({ type: 'session.state' })) })
    expect(reload).toHaveBeenCalledTimes(2)
    unmount()
    expect(source.closed).toBe(true)
  })
})
