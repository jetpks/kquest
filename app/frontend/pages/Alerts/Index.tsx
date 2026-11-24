import { Head, usePage } from '@inertiajs/react'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { csrfToken } from '@/lib/csrf'
import AppLayout from '@/layouts/AppLayout'
import EventFeed from '@/components/EventFeed'
import { ShowingOf } from '@/pages/Dashboard/Index'
import { CappedListing, FireSet, MetricsFamily, QuestRow, SharedProps } from '@/types'

// The ALERTING SURFACE (I08 §4 row 8 / I16 Part 2): the 13 tw_* predicates'
// current fire sets (SELECT-only), the reused Metrics panels, per-quest
// stream links, the EventFeed on the user-level stream, and the ONE write —
// the flash-only acknowledge (a UI state, NEVER a system state). No
// enforcement: nothing here fires, mutes, or blocks on an alert. The mute
// control is I17's; the console pre-load link is NOT rendered (I17).
export type AlertRow = Record<string, unknown>

export type AlertsProps = {
  fire_sets: FireSet[]
  metrics_panels: MetricsFamily[]
  quests: CappedListing<QuestRow>
  stream_url: string
  mute_state: { key: string; text_value: string | null; provenance: string }[]
}

export default function Index() {
  usePage<SharedProps>().props
  const p = usePage<AlertsProps>().props

  return (
    <AppLayout>
      <Head title="Alerts" />
      <div className="mx-auto max-w-4xl space-y-4 p-6">
        <h1 className="text-xl font-semibold">Alerts</h1>
        <p className="text-sm text-muted-foreground">
          Signals are REVIEWABLE choices — nothing here acts on them (the
          no-enforcement law). Mute is I17&rsquo;s; the console link is not rendered.
        </p>

        <section data-testid="fire-sets" className="space-y-3">
          {p.fire_sets.map((fs) => (
            <Card key={fs.predicate}>
              <CardHeader>
                <CardTitle className="text-sm">
                  {fs.predicate}{' '}
                  <span className="text-muted-foreground">
                    ({fs.listing.rows.length} firing)
                  </span>
                </CardTitle>
              </CardHeader>
              <CardContent className="space-y-1 text-xs">
                {fs.listing.rows.length === 0 && (
                  <span className="text-muted-foreground">no fires</span>
                )}
                {fs.listing.rows.map((row, i) => (
                  <p key={i} className="font-mono">
                    {Object.entries(row)
                      .filter(([k]) => !['user_id'].includes(k))
                      .slice(0, 6)
                      .map(([k, v]) => `${k}=${String(v)}`)
                      .join(' ')}
                  </p>
                ))}
                {fs.listing.rows.length > 0 && (
                  <AckForm predicate={fs.predicate} />
                )}
                <ShowingOf listing={fs.listing} />
              </CardContent>
            </Card>
          ))}
        </section>

        <section data-testid="metrics-panels" className="grid gap-2 sm:grid-cols-2">
          {p.metrics_panels.map((family) => (
            <Card key={family.name}>
              <CardHeader>
                <CardTitle className="text-sm">{family.name}</CardTitle>
              </CardHeader>
              <CardContent className="text-sm">
                {family.samples.map((s) => (
                  <p key={family.name + JSON.stringify(s.labels)}>
                    {Object.entries(s.labels).map(([k, v]) => `${k}=${v}`).join(' ')} → {s.value}
                  </p>
                ))}
              </CardContent>
            </Card>
          ))}
        </section>

        <section data-testid="quest-stream-links" className="space-x-3 text-sm">
          {p.quests.rows.map((q) => (
            <a key={q.id} href={`/quests/${q.id}/stream`} className="underline">
              {q.topic} stream
            </a>
          ))}
          <ShowingOf listing={p.quests} />
        </section>

        {p.mute_state.length > 0 && (
          <section data-testid="mute-state" className="text-xs text-muted-foreground">
            mute state (read-only, written by I17&rsquo;s console):
            {p.mute_state.map((m) => (
              <p key={m.key}>{m.key} — {m.provenance}</p>
            ))}
          </section>
        )}

        <section data-testid="live-feed">
          <h2 className="text-lg font-semibold">Assurance feed</h2>
          <EventFeed url={p.stream_url} />
        </section>
      </div>
    </AppLayout>
  )
}

// The acknowledge write: flash/session ONLY — no DB handle exists on the
// server action (the map's law: "a UI state, never a system state").
function AckForm({ predicate }: { predicate: string }) {
  return (
    <form method="post" action="/alerts/acknowledge" className="inline">
      <input type="hidden" name="predicate" value={predicate} />
      <input type="hidden" name="authenticity_token" value={csrfToken()} />
      <button type="submit" className="rounded border px-2 py-0.5">acknowledge</button>
    </form>
  )
}
