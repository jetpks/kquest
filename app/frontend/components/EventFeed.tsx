import { useEffect, useState } from 'react'

// The shared event feed (I16 Part 9): one EventSource consumer rendering
// typed event lines. The wire frame is `id: <entry-id>\ndata: <envelope-json>`
// — the envelope is exactly `type` + payload (the I15 EventPublisher's frozen
// two-field shape). The browser EventSource reconnects with Last-Event-ID
// natively — the adopted resume semantics — so the feed renders the
// backlog-then-live stream with no extra code. Guarded for jsdom: node's
// jsdom has no EventSource, so the component renders a plain "unavailable"
// note instead of crashing (the tests install a mock).
export type FeedEvent = {
  id: string
  type: string
  payload: Record<string, unknown>
}

export function parseFeedEvent(raw: string, id: string): FeedEvent {
  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>
    const { type, ...payload } = parsed
    return { id, type: typeof type === 'string' ? type : 'event', payload }
  } catch {
    return { id, type: 'event', payload: { raw } }
  }
}

export default function EventFeed({ url, limit = 30 }: { url: string; limit?: number }) {
  const [events, setEvents] = useState<FeedEvent[]>([])

  useEffect(() => {
    if (typeof window.EventSource === 'undefined') return
    const source = new window.EventSource(url)
    source.onmessage = (e: MessageEvent<string>) => {
      const event = parseFeedEvent(e.data, e.lastEventId)
      setEvents((prev) => [event, ...prev].slice(0, limit))
    }
    return () => source.close()
  }, [url, limit])

  if (typeof window.EventSource === 'undefined') {
    return (
      <div data-testid="event-feed" className="text-xs text-muted-foreground">
        live feed unavailable in this environment
      </div>
    )
  }

  return (
    <div data-testid="event-feed" className="space-y-1 font-mono text-xs">
      {events.length === 0 && (
        <p className="text-muted-foreground">waiting for events…</p>
      )}
      {events.map((event) => (
        <div key={event.id || `${event.type}-${events.indexOf(event)}`} className="flex gap-2">
          <span className="text-primary">{event.type}</span>
          <span className="text-muted-foreground">
            {summary(event.type, event.payload)}
          </span>
        </div>
      ))}
    </div>
  )
}

// The typed line's key payload fields (quest.state / phase.state /
// frontier.mass / spend.tick / assurance_alert — the quest view's feed law).
function summary(type: string, payload: Record<string, unknown>): string {
  const parts: string[] = []
  const add = (key: string) => {
    if (payload[key] !== undefined) parts.push(`${key}=${String(payload[key])}`)
  }
  switch (type) {
    case 'quest.state':
      add('from_state')
      add('to_state')
      break
    case 'phase.state':
      add('kind')
      add('state')
      break
    case 'frontier.mass':
      add('open_entries')
      add('mass')
      break
    case 'spend.tick':
      add('spend_usd')
      add('tokens')
      break
    case 'assurance_alert':
      add('predicate')
      add('quest_id')
      break
    default:
      add('to_state')
      add('predicate')
      add('mass')
  }
  return parts.join(' ')
}
