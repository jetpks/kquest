import { Head, usePage } from '@inertiajs/react'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import AppLayout from '@/layouts/AppLayout'
import { ShowingOf } from '@/pages/Dashboard/Index'
import { CappedListing, SharedProps } from '@/types'

// The REPORT VIEW (I08 §4 row 5 / I16 Part 7): the version chain (capped),
// the standing body's citation map, the binding-pass manifest (read-only),
// the STALENESS BANNER (pinned ≠ live fingerprint — DETECTED, not prevented),
// and the arc's stop markers in synthesis provenance. ONE action: the body
// download through the uploader seam. Draft/bind/flip are I17's.
export type VersionRow = {
  id: string
  version_seq: number
  standing: boolean
  bound_at: string | null
  binding_pass: string | null
  model: string
  quest_fingerprint: string
  body_url: string
}

export type CitationRow = {
  id: string
  ordinal: number
  source_id: string | null
  imported_source_id: string | null
}

export type ReportProps = {
  versions: CappedListing<VersionRow>
  standing?: VersionRow | null
  citations: CitationRow[]
  binding_index: { id: string; urn: string; title: string; canonical_url: string }[]
  import_manifest: { ordinal: number; source_urn: string; from_quest: string }[]
  staleness: { stale: boolean; pinned_fingerprint: string | null; live_fingerprint: string | null }
  stop_markers: { rule_id: string; phase_no: number; phase_kind: string; reason: string; route: string }[]
}

export default function Show() {
  usePage<SharedProps>().props
  const p = usePage<ReportProps>().props

  return (
    <AppLayout>
      <Head title="Report" />
      <div className="mx-auto max-w-4xl space-y-4 p-6">
        <h1 className="text-xl font-semibold">Report</h1>

        {p.staleness.stale && (
          <Card data-testid="staleness-banner" className="border-destructive">
            <CardHeader>
              <CardTitle className="text-sm text-destructive">
                Stale: the report is pinned to an older graph fingerprint (DETECTED, not prevented)
              </CardTitle>
            </CardHeader>
            <CardContent className="font-mono text-xs text-muted-foreground">
              pinned {p.staleness.pinned_fingerprint} · live {p.staleness.live_fingerprint}
            </CardContent>
          </Card>
        )}

        <section data-testid="version-chain">
          <h2 className="text-lg font-semibold">Version chain</h2>
          {p.versions.rows.map((v) => (
            <p key={v.id} className="text-sm">
              v{v.version_seq} · {v.standing ? 'standing' : 'archived version'} · {v.model}
              {v.bound_at ? ` · bound (${v.binding_pass})` : ' · unbound'} ·{' '}
              <a href={v.body_url} className="underline">download body</a>
            </p>
          ))}
          <ShowingOf listing={p.versions} />
        </section>

        <section data-testid="citations">
          <h2 className="text-lg font-semibold">Citations</h2>
          {p.citations.length === 0 && <p className="text-sm text-muted-foreground">none</p>}
          {p.citations.map((c) => (
            <p key={c.id} className="text-sm">
              [^{c.ordinal}] → {c.source_id ?? `imported ${c.imported_source_id}`}
            </p>
          ))}
        </section>

        <section data-testid="binding-manifest" className="text-sm text-muted-foreground">
          binding index: {p.binding_index.length} corpus source(s) · imports:{' '}
          {p.import_manifest.map((m) => `[^${m.ordinal}] ${m.source_urn}`).join(' · ') || 'none'}
        </section>

        <section data-testid="stop-markers">
          <h2 className="text-lg font-semibold">Arc stop markers</h2>
          {p.stop_markers.length === 0 && (
            <p className="text-sm text-muted-foreground">no stop markers — a run-to-completion arc</p>
          )}
          {p.stop_markers.map((m, i) => (
            <p key={i} className="text-sm">
              {m.rule_id} at phase {m.phase_no} ({m.phase_kind}) — {m.reason} — route: {m.route}
            </p>
          ))}
        </section>
      </div>
    </AppLayout>
  )
}
