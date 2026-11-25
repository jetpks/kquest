import { Head, usePage } from '@inertiajs/react'
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import AppLayout from '@/layouts/AppLayout'
import EventFeed from '@/components/EventFeed'
import ShowingOf from '@/components/ShowingOf'
import { csrfToken } from '@/lib/csrf'
import { CappedListing, MetricsFamily, OverhangRow, QuestRow, SharedProps } from '@/types'

// The DASHBOARD (I08 §4 row 1 / I16 Part 3) — the root landing surface.
// Anonymous: the 200 sign-in prompt card (the Nav's GitHub button is the only
// auth door — a redirect here would loop). Signed-in: the ONE write — the
// pre-briefing create-quest form (topic + budgets + routing map; the ROW
// ONLY) — then quest cards (capped), the blind-spot panel (Metrics families
// + the overhang join), the honesty-bounds ladder (static text, I07 §1's
// guarantee map), and workspace-admin reads (render-only; the grant UI is
// I17's).
export type DashboardProps = {
  quests?: CappedListing<QuestRow>
  blind_spots?: MetricsFamily[]
  overhang?: OverhangRow[]
  workspaces?: {
    workspaces: { id: string; name: string }[]
    memberships: { workspace_id: string; user_id: string }[]
    grants: { id: string; source_id: string; is_public: boolean }[]
  }
  stream_url?: string
}

// The honesty-bounds ladder (I07 §1): static text — the guarantee map's
// ENFORCED/REDUCED/UNTOUCHED bands, rendered as the deck's standing honesty
// frame. Nothing here computes anything.
const HONESTY_LADDER: { band: string; text: string }[] = [
  { band: 'ENFORCED', text: 'the budgets and caps the engine refuses at (hard-mode lines, the ledgered transitions)' },
  { band: 'REDUCED', text: 'the guarantees bounded by honest measurement (mass floors, spot-check sampling, the derivation caps)' },
  { band: 'UNTOUCHED', text: 'what stays outside the system\u2019s reach (operator judgement, provider-side behavior, the world)' },
]

export default function Index() {
  const { current_user } = usePage<SharedProps>().props
  const props = usePage<DashboardProps>().props

  return (
    <AppLayout>
      <Head title="Dashboard" />
      <div className="mx-auto max-w-4xl space-y-4 p-6">
        {!current_user ? (
          <Card className="max-w-md">
            <CardHeader>
              <CardTitle>kquest</CardTitle>
              <CardDescription>A claim-graph knowledge factory.</CardDescription>
            </CardHeader>
            <CardContent className="text-sm text-muted-foreground">
              Sign in with the GitHub button above to see your quests. The
              dashboard shows your arcs, their blind spots, and the live
              event feed once you are signed in.
            </CardContent>
          </Card>
        ) : (
          <>
            <section data-testid="create-quest" className="space-y-2">
              <h2 className="text-lg font-semibold">New quest</h2>
              <Card>
                <CardHeader>
                  <CardTitle className="text-sm">the pre-briefing form</CardTitle>
                  <CardDescription className="text-xs">
                    creates the row only — no session, no worker; the
                    interactive briefing is the next door after create
                  </CardDescription>
                </CardHeader>
                <CardContent>
                  {/* I16 Part 3's ONE dashboard write — the form the shipped
                      page omitted (operator-caught build miss, fixed inline
                      2026-11-24): topic + budgets + the routing map, exactly
                      the server action's own vocabulary. */}
                  <form data-testid="create-quest-form" method="post" action="/quests" className="space-y-2">
                    <input type="hidden" name="authenticity_token" value={csrfToken()} />
                    <input name="topic" required placeholder="topic — what this quest is after"
                           className="w-full rounded border px-2 py-1 text-sm" />
                    <div className="grid gap-2 sm:grid-cols-3">
                      <input name="web_call_budget" type="number" min="0" placeholder="web_call_budget (int)"
                             className="rounded border px-2 py-1 text-sm" />
                      <input name="token_budget" type="number" min="0" placeholder="token_budget (int)"
                             className="rounded border px-2 py-1 text-sm" />
                      <input name="spend_budget_usd" placeholder="spend_budget_usd (e.g. 5.00)"
                             className="rounded border px-2 py-1 text-sm" />
                    </div>
                    <input name="process_config" placeholder='process_config JSON object (optional), e.g. {"modes":{…}}'
                           className="w-full rounded border px-2 py-1 text-sm" />
                    <input name="model_config" placeholder='model_config JSON object (optional), e.g. {"decompose":"…"}'
                           className="w-full rounded border px-2 py-1 text-sm" />
                    <button type="submit" className="rounded border px-2 py-1 text-sm">Create quest</button>
                  </form>
                </CardContent>
              </Card>
            </section>

            <section data-testid="quest-cards" className="space-y-2">
              <h2 className="text-lg font-semibold">Quests</h2>
              {props.quests && props.quests.rows.length === 0 && (
                <p className="text-sm text-muted-foreground">No quests yet.</p>
              )}
              <div className="grid gap-2">
                {props.quests?.rows.map((q) => (
                  <Card key={q.id} data-testid="quest-card">
                    <CardHeader>
                      <CardTitle className="text-base">
                        <a href={`/quests/${q.id}`} className="hover:underline">{q.topic}</a>
                      </CardTitle>
                      <CardDescription>
                        {q.state} · {q.provenance_kind}
                        {q.web_call_budget !== undefined &&
                          ` · web ${q.web_call_budget} · tokens ${q.token_budget} · $${q.spend_budget_usd}`}
                      </CardDescription>
                    </CardHeader>
                  </Card>
                ))}
              </div>
              <ShowingOf listing={props.quests} />
            </section>

            <section data-testid="blind-spot-panel" className="space-y-2">
              <h2 className="text-lg font-semibold">Blind spots</h2>
              <div className="grid gap-2 sm:grid-cols-2">
                {props.blind_spots?.map((family) => (
                  <Card key={family.name}>
                    <CardHeader>
                      <CardTitle className="text-sm">{family.name}</CardTitle>
                      <CardDescription className="text-xs">{family.help}</CardDescription>
                    </CardHeader>
                    <CardContent className="text-sm">
                      {family.samples.length === 0 && <span className="text-muted-foreground">none</span>}
                      {family.samples.map((s) => (
                        <p key={family.name + JSON.stringify(s.labels)}>
                          {Object.entries(s.labels).map(([k, v]) => `${k}=${v}`).join(' ')} → {s.value}
                        </p>
                      ))}
                    </CardContent>
                  </Card>
                ))}
                <Card data-testid="overhang-panel">
                  <CardHeader>
                    <CardTitle className="text-sm">capped_listing_overhang</CardTitle>
                    <CardDescription className="text-xs">
                      rows the capped listings never showed (per surface)
                    </CardDescription>
                  </CardHeader>
                  <CardContent className="text-sm">
                    {(props.overhang?.length ?? 0) === 0 && (
                      <span className="text-muted-foreground">no overhang</span>
                    )}
                    {props.overhang?.map((r) => (
                      <p key={r.surface}>
                        {r.surface}: {r.overhang} over {r.capped_requests} capped request(s)
                      </p>
                    ))}
                  </CardContent>
                </Card>
              </div>
            </section>

            <section data-testid="honesty-ladder" className="space-y-1">
              <h2 className="text-lg font-semibold">Honesty bounds</h2>
              {HONESTY_LADDER.map((rung) => (
                <p key={rung.band} className="text-sm text-muted-foreground">
                  <span className="font-medium text-foreground">{rung.band}</span> — {rung.text}
                </p>
              ))}
            </section>

            <section data-testid="workspaces" className="space-y-1">
              <h2 className="text-lg font-semibold">Workspaces</h2>
              {props.workspaces && props.workspaces.workspaces.length === 0 && (
                <p className="text-sm text-muted-foreground">No workspaces yet (admin UI is I17&rsquo;s).</p>
              )}
              {props.workspaces?.workspaces.map((w) => (
                <p key={w.id} className="text-sm">{w.name}</p>
              ))}
            </section>

            {props.stream_url && (
              <section data-testid="live-feed">
                <h2 className="text-lg font-semibold">Live</h2>
                <EventFeed url={props.stream_url} />
              </section>
            )}
          </>
        )}
      </div>
    </AppLayout>
  )
}

// The F10 move (I17): the shared "showing N of M" caption lives in
// components/ShowingOf.tsx — the definition above is gone; Dashboard imports
// it from there. The re-export is a compat shim for the ONE legacy consumer
// outside the I17 touch set (pages/Costs/Index.tsx); new surfaces import the
// component directly.
export { default as ShowingOf } from '@/components/ShowingOf'
