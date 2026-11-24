import { Head, usePage } from '@inertiajs/react'
import { Card, CardContent } from '@/components/ui/card'
import AppLayout from '@/layouts/AppLayout'
import { ShowingOf } from '@/pages/Dashboard/Index'
import { CappedListing, OverhangRow, SharedProps } from '@/types'

// The FRONTIER INSPECTOR (I08 §4 row 3 / I16 Part 5): the open/total + mass
// fuse reading, closure classes, aging bands, the OVERHANG BADGE, server-side
// filter/sort (mass decile / age / state), ALL CAPPED with "showing N of M".
// The hand-add write is I17's (session-bearing) — read-only surface + the CSV
// snapshot link.
export type FrontierEntry = {
  entry_id: string
  claim_seq: number
  need: string
  uncertainty: number
  relevance: number
  mass: number
  opened_at: string
  closed_at?: string | null
  closure_type?: string | null
}

export type FrontierProps = {
  listing: CappedListing<FrontierEntry>
  mass: { open_entries: number; mass: number }
  closure_classes: { state: string; closure_type: string | null; n: number }[]
  aging_bands: Record<string, number>
  overhang?: OverhangRow
  filters: { sort?: string; state?: string; mass_decile?: string; age_days?: string }
}

export default function Index() {
  usePage<SharedProps>().props
  const p = usePage<FrontierProps>().props
  const questId = location.pathname.split('/')[2] || ''

  return (
    <AppLayout>
      <Head title="Frontier" />
      <div className="mx-auto max-w-4xl space-y-4 p-6">
        <h1 className="text-xl font-semibold">Frontier inspector</h1>

        <section data-testid="mass-fuse" className="text-sm text-muted-foreground">
          open {p.mass.open_entries} · mass {p.mass.mass}
          {p.overhang && (
            <span data-testid="overhang-badge" className="ml-2 rounded bg-muted px-2 py-0.5">
              overhang: {p.overhang.overhang} ({p.overhang.capped_requests} capped request(s))
            </span>
          )}
        </section>

        <section data-testid="filters" className="space-x-2 text-sm">
          <span className="text-muted-foreground">sort:</span>
          <FilterLink questId={questId} label="mass" params={{}} active={!p.filters.sort} />
          <FilterLink questId={questId} label="age" params={{ sort: 'age' }} active={p.filters.sort === 'age'} />
          <FilterLink questId={questId} label="uncertainty" params={{ sort: 'uncertainty' }} active={p.filters.sort === 'uncertainty'} />
          <FilterLink questId={questId} label="closed" params={{ state: 'closed' }} active={p.filters.state === 'closed'} />
          <a href={`/quests/${questId}/frontier.csv`} className="underline">CSV</a>
        </section>

        <section data-testid="aging-bands" className="text-sm text-muted-foreground">
          aging bands: {Object.entries(p.aging_bands).map(([band, n]) => `${band}=${n}`).join(' · ')}
        </section>

        <section data-testid="closure-classes" className="text-sm text-muted-foreground">
          closure: {p.closure_classes.map((c) => `${c.state}/${c.closure_type ?? 'open'}=${c.n}`).join(' · ')}
        </section>

        <div className="space-y-1">
          {p.listing.rows.map((e) => (
            <Card key={e.entry_id}>
              <CardContent className="flex items-baseline gap-3 pt-4 text-sm">
                <span className="font-mono text-muted-foreground">K{e.claim_seq}</span>
                <span>{e.need}</span>
                <span className="text-muted-foreground">u{e.uncertainty} r{e.relevance} · mass {e.mass}</span>
                {e.closed_at && <span className="text-muted-foreground">closed ({e.closure_type})</span>}
              </CardContent>
            </Card>
          ))}
          <ShowingOf listing={p.listing} />
        </div>
      </div>
    </AppLayout>
  )
}

function FilterLink({ questId, label, params, active }: {
  questId: string
  label: string
  params: Record<string, string>
  active?: boolean
}) {
  const qs = new URLSearchParams(params).toString()
  return (
    <a href={`/quests/${questId}/frontier${qs ? `?${qs}` : ''}`}
       className={active ? 'font-semibold underline' : 'underline'}>
      {label}
    </a>
  )
}
