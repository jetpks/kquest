import { Head, usePage } from '@inertiajs/react'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import AppLayout from '@/layouts/AppLayout'
import EventFeed from '@/components/EventFeed'
import { ShowingOf } from '@/pages/Dashboard/Index'
import { CappedListing, MetricsFamily, SharedProps } from '@/types'

// The COST VIEW (I08 §4 row 7 / I16 Part 8 — LAST per the sequencing law):
// the reused Metrics rollups (one rollup, no second validator), the capped
// usage-event ledger, the budget echo, the live tail (spend.tick) on the
// quest stream. REPORTING-ONLY (I07 DR-08 verbatim: "these should not bind
// the operator") — nothing here throttles, blocks, or links to any
// enforcement.
export type LedgerRow = {
  id: string
  created_at: string
  kind: string
  model: string
  input_tokens: number
  output_tokens: number
  cost_usd: string
  phase_id: string
  session_id: string
}

export type CostsProps = {
  panels: MetricsFamily[]
  ledger: CappedListing<LedgerRow>
  budgets: { web_call_budget: number; token_budget: number; spend_budget_usd: string }
  stream_url: string
  filters: { phase?: string; model?: string; window_hours?: string }
}

export default function Index() {
  usePage<SharedProps>().props
  const p = usePage<CostsProps>().props
  const questId = location.pathname.split('/')[2] || ''

  return (
    <AppLayout>
      <Head title="Costs" />
      <div className="mx-auto max-w-4xl space-y-4 p-6">
        <h1 className="text-xl font-semibold">Costs</h1>
        <p className="text-sm text-muted-foreground" data-testid="budgets">
          budgets (echoed from the quest row): web {p.budgets.web_call_budget} · tokens{' '}
          {p.budgets.token_budget} · spend ${p.budgets.spend_budget_usd}
        </p>

        <section data-testid="cost-panels" className="grid gap-2 sm:grid-cols-2">
          {p.panels.map((family) => (
            <Card key={family.name}>
              <CardHeader>
                <CardTitle className="text-sm">{family.name}</CardTitle>
              </CardHeader>
              <CardContent className="text-sm">
                {family.samples.length === 0 && <span className="text-muted-foreground">no samples</span>}
                {family.samples.map((s) => (
                  <p key={family.name + JSON.stringify(s.labels)}>
                    {Object.entries(s.labels).map(([k, v]) => `${k}=${v}`).join(' ')} → {s.value}
                  </p>
                ))}
              </CardContent>
            </Card>
          ))}
        </section>

        <section data-testid="filters" className="space-x-2 text-sm">
          <span className="text-muted-foreground">filters are server-side: ?phase= ?model= ?window_hours=</span>
          <a href={`/quests/${questId}/costs.csv`} className="underline">CSV export</a>
        </section>

        <section data-testid="ledger">
          <h2 className="text-lg font-semibold">Usage ledger</h2>
          {p.ledger.rows.map((r) => (
            <p key={r.id} className="text-sm">
              {r.created_at} · {r.kind} · {r.model} · in {r.input_tokens} out {r.output_tokens} · ${r.cost_usd}
            </p>
          ))}
          <ShowingOf listing={p.ledger} />
        </section>

        <section data-testid="live-feed">
          <h2 className="text-lg font-semibold">Live tail (spend.tick)</h2>
          <EventFeed url={p.stream_url} />
        </section>
      </div>
    </AppLayout>
  )
}
