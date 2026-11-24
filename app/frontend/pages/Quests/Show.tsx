import { Head, usePage } from '@inertiajs/react'
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { csrfToken } from '@/lib/csrf'
import AppLayout from '@/layouts/AppLayout'
import EventFeed from '@/components/EventFeed'
import { ShowingOf } from '@/pages/Dashboard/Index'
import {
  CappedListing,
  LifecycleEvent,
  PhaseRow,
  QuestRow,
  SessionRow,
  SharedProps,
} from '@/types'

// The QUEST VIEW (I08 §4 row 2 / I16 Part 1): the parity block (composed
// through the shared formatter server-side — the line arrives ready), the
// capped lifecycle ledger / sessions / phases, the counters, the read-only
// config, the fingerprint, and the live feed on the I15 FROZEN stream URL.
// The lifecycle door: pause (the ONLY door while running, D5), resume,
// archive — native form POSTs riding the landed csrf.ts idiom. The
// console/briefing links are I17's and are NOT rendered.
export type QuestShowProps = {
  quest: QuestRow
  parity_line: string
  lifecycle: CappedListing<LifecycleEvent>
  sessions: CappedListing<SessionRow>
  phases: CappedListing<PhaseRow>
  counters: { unmined_citable: number; frontier_open: number; frontier_mass: number }
  fingerprint: string | null
  stream_url: string
  frontier_url: string
  graph_url: string
  report_url: string
}

export default function Show() {
  const { current_user } = usePage<SharedProps>().props
  const p = usePage<QuestShowProps>().props

  return (
    <AppLayout>
      <Head title={`Quest — ${p.quest.topic}`} />
      <div className="mx-auto max-w-4xl space-y-4 p-6">
        <section data-testid="quest-header">
          <h1 className="text-xl font-semibold">{p.quest.topic}</h1>
          <p className="text-sm text-muted-foreground">
            {p.quest.state} · {p.quest.provenance_kind} · fingerprint{' '}
            <span className="font-mono">{p.fingerprint ?? '—'}</span>
          </p>
        </section>

        <Card data-testid="parity-block">
          <CardHeader>
            <CardTitle className="text-sm">Parity block</CardTitle>
            <CardDescription className="text-xs">
              the shared quest_status line (I05 §5 — byte-faithful by composition)
            </CardDescription>
          </CardHeader>
          <CardContent>
            <pre className="overflow-x-auto rounded bg-muted p-2 font-mono text-xs">{p.parity_line}</pre>
          </CardContent>
        </Card>

        <section data-testid="counters" className="grid grid-cols-3 gap-2 text-sm">
          <Card>
            <CardContent className="pt-4">
              unmined citable: <span className="font-medium">{p.counters.unmined_citable}</span>
            </CardContent>
          </Card>
          <Card>
            <CardContent className="pt-4">
              frontier open: <span className="font-medium">{p.counters.frontier_open}</span>
            </CardContent>
          </Card>
          <Card>
            <CardContent className="pt-4">
              frontier mass: <span className="font-medium">{p.counters.frontier_mass}</span>
            </CardContent>
          </Card>
        </section>

        <section data-testid="lifecycle-door" className="space-x-2">
          <LifecycleButton questId={p.quest.id} action="pause" label="Pause" disabled={p.quest.state !== 'active'} />
          <LifecycleButton questId={p.quest.id} action="resume" label="Resume" disabled={p.quest.state !== 'paused'} />
          <LifecycleButton
            questId={p.quest.id}
            action="archive"
            label="Archive"
            disabled={!(p.quest.state === 'complete' || p.quest.state === 'stopped')}
          />
        </section>

        <section data-testid="lifecycle-ledger">
          <h2 className="text-lg font-semibold">Lifecycle ledger</h2>
          {p.lifecycle.rows.map((e) => (
            <p key={e.id} className="text-sm">
              {e.from_state} → {e.to_state} · {e.actor} · {e.note}
            </p>
          ))}
          <ShowingOf listing={p.lifecycle} />
        </section>

        <section data-testid="sessions">
          <h2 className="text-lg font-semibold">Sessions</h2>
          {p.sessions.rows.map((s) => (
            <p key={s.id} className="text-sm">
              {s.driver}/{s.mode} · {s.model} · {s.ended_at ? 'banked' : 'live'}
            </p>
          ))}
          <ShowingOf listing={p.sessions} />
        </section>

        <section data-testid="phases">
          <h2 className="text-lg font-semibold">Phase history</h2>
          {p.phases.rows.map((ph) => (
            <p key={ph.id} className="text-sm">
              {ph.kind} (r{ph.round_no}/a{ph.attempt_no}) · {ph.state}
            </p>
          ))}
          <ShowingOf listing={p.phases} />
        </section>

        <section data-testid="config-readonly" className="grid gap-2 sm:grid-cols-2">
          <Card>
            <CardHeader>
              <CardTitle className="text-sm">process_config (read-only)</CardTitle>
              <CardDescription className="text-xs">the editor is I17&rsquo;s</CardDescription>
            </CardHeader>
            <CardContent>
              <pre className="overflow-x-auto font-mono text-xs">{JSON.stringify(p.quest.process_config, null, 2)}</pre>
            </CardContent>
          </Card>
          <Card>
            <CardHeader>
              <CardTitle className="text-sm">model_config (read-only)</CardTitle>
              <CardDescription className="text-xs">the editor is I17&rsquo;s</CardDescription>
            </CardHeader>
            <CardContent>
              <pre className="overflow-x-auto font-mono text-xs">{JSON.stringify(p.quest.model_config, null, 2)}</pre>
            </CardContent>
          </Card>
        </section>

        <section data-testid="surface-links" className="space-x-4 text-sm">
          <a href={p.frontier_url} className="underline">Frontier inspector</a>
          <a href={p.graph_url} className="underline">Graph browser</a>
          <a href={p.report_url} className="underline">Report view</a>
          {current_user && <span className="text-muted-foreground">signed in as {current_user.username}</span>}
        </section>

        <section data-testid="live-feed">
          <h2 className="text-lg font-semibold">Live feed</h2>
          <EventFeed url={p.stream_url} />
        </section>
      </div>
    </AppLayout>
  )
}

// The lifecycle door: native form POSTs with the landed csrf.ts idiom (the
// Nav pattern). Disabled buttons encode the legal transitions client-side;
// the server's refusals (422, no ledger row) are the law regardless.
function LifecycleButton({ questId, action, label, disabled }: {
  questId: string
  action: 'pause' | 'resume' | 'archive'
  label: string
  disabled?: boolean
}) {
  return (
    <form method="post" action={`/quests/${questId}/${action}`} className="inline">
      <input type="hidden" name="authenticity_token" value={csrfToken()} />
      <button type="submit" disabled={disabled}
              className="rounded border px-2 py-1 text-sm disabled:opacity-40">
        {label}
      </button>
    </form>
  )
}
