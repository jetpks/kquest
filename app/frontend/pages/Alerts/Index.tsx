import { Head, usePage } from '@inertiajs/react'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { csrfToken } from '@/lib/csrf'
import AppLayout from '@/layouts/AppLayout'
import EventFeed from '@/components/EventFeed'
import ShowingOf from '@/components/ShowingOf'
import { CappedListing, FireSet, MetricsFamily, QuestRow, SharedProps } from '@/types'

// The ALERTING SURFACE (I08 §4 row 8 / I16 Part 2): the 13 tw_* predicates'
// current fire sets (SELECT-only, the I17 mute applied as a DISPLAY filter
// server-side), the reused Metrics panels, per-quest stream links, the
// EventFeed on the user-level stream, and the TWO UI writes: the
// flash-only acknowledge (a UI state, NEVER a system state) and the I17
// additions (additive — the landed render is byte-preserved): the
// mute/unmute CONTROL (POSTing the console's mute route — the ONE
// config-row write) and the alerting→console pre-load link
// (/quests/:quest_id/console?alert=<predicate>) per fire-set row with a
// quest. No enforcement: nothing here fires, mutes, or blocks on an alert —
// the mute is a display filter recorded with who/why; tw_hub_divergence
// rows carry no quest_id and link the adjudication workflow instead.
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
          no-enforcement law). The mute is a per-quest DISPLAY filter recorded
          with who/why (the console&rsquo;s one config-row write);
          tw_hub_divergence is not muteable — it links the adjudication
          workflow.
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
                <div className="flex flex-wrap gap-2 pt-1">
                  {fs.listing.rows
                    .map((row) => ({ predicate: fs.predicate, questId: row.quest_id as string | undefined }))
                    .filter((r): r is { predicate: string; questId: string } => !!r.questId)
                    .map(({ predicate, questId }) => (
                      <a key={`${predicate}-${questId}`}
                         href={`/quests/${questId}/console?alert=${predicate}`}
                         className="underline">
                        console ({questId.slice(0, 8)})
                      </a>
                    ))}
                </div>
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

        <section data-testid="quest-stream-links" className="space-y-2 text-sm">
          <div className="space-x-3">
            {p.quests.rows.map((q) => (
              <a key={q.id} href={`/quests/${q.id}/stream`} className="underline">
                {q.topic} stream
              </a>
            ))}
          </div>
          {p.quests.rows.map((q) => (
            <MuteControl key={q.id} questId={q.id} topic={q.topic} />
          ))}
          <ShowingOf listing={p.quests} />
        </section>

        <section data-testid="mute-state" className="text-xs text-muted-foreground">
          mute state (who/why — never hidden):
          {p.mute_state.length === 0 && <p>none — every signal renders.</p>}
          {p.mute_state.map((m) => (
            <p key={m.key}>{m.key} — {m.text_value} — {m.provenance}</p>
          ))}
        </section>

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

// The I17 mute control (Part 6): POSTs the console's mute route — the ONE
// config-row write, per (quest, predicate) — upsert-shaped; `remove` unmutes.
// tw_hub_divergence is NOT muteable server-side (it routes to adjudication).
// The quest id comes from the landed quests listing (constructed URLs, no
// placeholder stubs); the mute rows render who/why in the mute-state panel.
function MuteControl({ questId, topic }: { questId: string; topic: string }) {
  const predicates = ['tw_wedge', 'tw_cache_wall', 'tw_churn', 'tw_context_blowout',
    'tw_empty_storm', 'tw_fingerprint_drift', 'tw_missing_spend', 'tw_repetition',
    'tw_rotation', 'tw_shape_storm', 'tw_size_ceiling', 'tw_slowstall']
  return (
    <form data-testid={`mute-control-${questId.slice(0, 8)}`} method="post"
          action={`/quests/${questId}/console/mute`}
          className="flex flex-wrap items-center gap-1 text-xs">
      <span className="font-mono">{topic.slice(0, 24)}</span>
      <input type="hidden" name="authenticity_token" value={csrfToken()} />
      <select name="predicate" className="rounded border px-1 py-0.5 text-xs">
        <option value="">predicate…</option>
        {predicates.map((predicate) => (
          <option key={predicate} value={predicate}>{predicate}</option>
        ))}
      </select>
      <input name="reason" placeholder="why (required)" className="w-48 rounded border px-1 py-0.5 text-xs" />
      <button type="submit" className="rounded border px-2 py-0.5 text-xs">mute</button>
      <button type="submit" name="remove" value="true" className="rounded border px-2 py-0.5 text-xs">
        unmute
      </button>
    </form>
  )
}
