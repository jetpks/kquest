import { Head, usePage } from '@inertiajs/react'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import AppLayout from '@/layouts/AppLayout'
import { csrfToken } from '@/lib/csrf'
import ShowingOf from '@/components/ShowingOf'
import { CappedListing, SharedProps } from '@/types'

// The REPORT VIEW (I08 §4 row 5 / I16 Part 7): the version chain (capped),
// the standing body's citation map, the binding-pass manifest (read-only),
// the STALENESS BANNER (pinned ≠ live fingerprint — DETECTED, not prevented),
// and the arc's stop markers in synthesis provenance. ONE read action: the
// body download through the uploader seam. The I17 addition (additive — the
// landed read render is byte-preserved): the draft/bind forms, the per-version
// standing flip, and the EXPLICIT import mark (never silent) — session-bearing
// through the LANDED tools and OperatorWrite (I17 Part 5); the URLs are
// constructed from the quest id (no placeholder stubs).
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
  const questId = location.pathname.split('/')[2] || ''

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
              {!v.standing && v.bound_at && (
                <form method="post"
                      action={`/quests/${questId}/report/versions/${v.version_seq}/flip`}
                      className="ml-2 inline">
                  <input type="hidden" name="_csrf_token" value={csrfToken()} />
                  <button type="submit" className="rounded border px-1 py-0.5 text-xs">
                    flip standing here
                  </button>
                </form>
              )}
            </p>
          ))}
          <ShowingOf listing={p.versions} />
          <form data-testid="draft-form" method="post" action={`/quests/${questId}/report/draft`}
                className="mt-2 space-y-2 rounded border p-3 text-sm">
            <div className="font-medium">Draft a section (the session's draft version)</div>
            <input type="hidden" name="_csrf_token" value={csrfToken()} />
            <input name="section" placeholder="the section key" className="rounded border px-2 py-1 text-sm" />
            <input name="version" placeholder="target version_seq (optional — the draft accumulates)"
                   className="w-80 rounded border px-2 py-1 text-sm" />
            <textarea name="body" rows={4} placeholder="the body — inline citation ordinals [^n] only"
                      className="w-full rounded border px-2 py-1 text-sm" />
            <button type="submit" className="rounded border px-2 py-1 text-sm">Draft</button>
          </form>
          <form data-testid="bind-form" method="post" action={`/quests/${questId}/report/bind`}
                className="mt-2 text-sm">
            <input type="hidden" name="_csrf_token" value={csrfToken()} />
            <button type="submit" className="rounded border px-2 py-1 text-sm">
              Bind (the deterministic pass: citations → ordinals → standing flip)
            </button>
          </form>
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
          <form data-testid="import-mark-form" method="post"
                action={`/quests/${questId}/report/versions/1/citations/1/import`}
                className="mt-2 space-y-2 rounded border p-3 text-sm text-foreground">
            <div className="font-medium">
              Mark an import explicitly (never silent — the same-user origin posture)
            </div>
            <input type="hidden" name="_csrf_token" value={csrfToken()} />
            <input name="version_seq" placeholder="version_seq" className="rounded border px-2 py-1 text-sm" />
            <input name="ordinal" placeholder="ordinal" className="rounded border px-2 py-1 text-sm" />
            <input name="source_urn" placeholder="the import source urn" className="w-80 rounded border px-2 py-1 text-sm" />
            <input name="origin_quest_id" placeholder="the origin quest id" className="w-80 rounded border px-2 py-1 text-sm" />
            <button type="submit" className="rounded border px-2 py-1 text-sm">Mark import</button>
          </form>
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
