import { act, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import EventFeed, { parseFeedEvent } from './EventFeed'

// jsdom has no EventSource — the landed guard renders the unavailable note
// unless a mock is installed. The mock records the subscribed URL and lets a
// test push frames through onmessage.
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

describe('EventFeed', () => {
  afterEach(() => {
    window.EventSource = OriginalEventSource
    MockEventSource.instances = []
    vi.restoreAllMocks()
  })

  it('renders the jsdom-unavailable note without an EventSource', () => {
    window.EventSource = undefined as unknown as typeof EventSource
    render(<EventFeed url="/alerts/stream" />)
    expect(screen.getByTestId('event-feed').textContent).toContain('unavailable')
  })

  it('subscribes to the url prop and renders typed event lines newest-first', async () => {
    ;(window as unknown as { EventSource: unknown }).EventSource = MockEventSource
    render(<EventFeed url="/quests/q1/stream" />)
    expect(MockEventSource.lastUrl).toBe('/quests/q1/stream')
    const source = MockEventSource.instances[0]
    act(() => {
      source.push('1-1', JSON.stringify({ type: 'quest.state', to_state: 'paused' }))
      source.push('1-2', JSON.stringify({ type: 'spend.tick', spend_usd: '1.24' }))
    })
    await waitFor(() => expect(screen.getByTestId('event-feed').textContent).toContain('spend_usd=1.24'))
    const feed = screen.getByTestId('event-feed')
    const text = feed.textContent
    expect(text).toContain('quest.state')
    expect(text).toContain('to_state=paused')
    expect(text).toContain('spend.tick')
    expect(text).toContain('spend_usd=1.24')
    expect(text!.indexOf('spend.tick')).toBeLessThan(text!.indexOf('quest.state'))
  })

  it('respects the limit (the newest frame survives, the oldest drops off)', () => {
    ;(window as unknown as { EventSource: unknown }).EventSource = MockEventSource
    render(<EventFeed url="/alerts/stream" limit={2} />)
    const source = MockEventSource.instances[0]
    act(() => {
      source.push('1-1', JSON.stringify({ type: 'a' }))
      source.push('1-2', JSON.stringify({ type: 'b' }))
      source.push('1-3', JSON.stringify({ type: 'c' }))
    })
    expect(screen.getByTestId('event-feed').textContent).not.toContain('a')
    expect(screen.getByTestId('event-feed').textContent).toContain('c')
  })

  it('unsubscribes on unmount', () => {
    ;(window as unknown as { EventSource: unknown }).EventSource = MockEventSource
    const { unmount } = render(<EventFeed url="/alerts/stream" />)
    const source = MockEventSource.instances[0]
    unmount()
    expect(source.closed).toBe(true)
  })

  it('parses the frozen envelope (type + payload) and degrades malformed frames', () => {
    expect(parseFeedEvent('{"type":"quest.state","to_state":"active"}', '9-1')).toEqual({
      id: '9-1', type: 'quest.state', payload: { to_state: 'active' },
    })
    expect(parseFeedEvent('not-json', '9-2').type).toBe('event')
  })
})
