import { Head, usePage } from '@inertiajs/react'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import AppLayout from '@/layouts/AppLayout'
import { csrfToken } from '@/lib/csrf'
import ShowingOf from '@/components/ShowingOf'
import { CappedListing, SharedProps } from '@/types'

// The GRAPH BROWSER (I08 §4 row 4 / I16 Part 6): claims/evidence/edges/
// derivations capped; closure status per claim; lineage; the CROSS-QUEST HUB
// tab (reuse + type-divergence rows over v_canonical_claims); the
// conflicts-ledger docket with the I17 courtroom write forms (additive — the
// landed read render is byte-preserved): ledger a conflict (the docket's
// first act) + hypothesize/adjudicate per conflict — session-bearing
// (I17 Part 4), the teaching refusals ride the server action. Traversal is
// Inertia-native: ?node=<claim_id> adds the node's neighborhood + derivation
// paths through the canonical query services.
export type ClaimRow = {
  id: string
  quest_seq: number
  text: string
  terminal_type: string | null
  urn: string
}

export type EvidenceRow = {
  id: string
  source_id: string
  span_start: number
  span_end: number
  reading: string
}

export type BrowserProps = {
  claims: CappedListing<ClaimRow>
  evidence: CappedListing<EvidenceRow>
  edges: CappedListing<{ id: string; evidence_id: string; claim_id: string; relation: string; position: number }>
  derivations: CappedListing<{ id: string; claim_id: string; parent_claim_id: string; position: number }>
  closure: CappedListing<{ claim_id: string; quest_seq: number; canonical_text: string; has_terminal: boolean; derives_from_count: number; evidence_count: number; open_frontier_count: number; bare: boolean }>
  lineage: { quest_id: string; topic: string; ancestor_quest_id: string; ancestor_topic: string; via_provenance_kind: string; depth: number }[]
  hub: {
    reused: CappedListing<{ canonical_text: string; terminal_type: string | null; quest_count: number; type_divergent: boolean }>
    type_divergent: CappedListing<{ canonical_text: string; terminal_type: string | null; quest_count: number }>
  }
  conflicts: {
    conflicts: CappedListing<{ id: string; claim_id: string; divergence: string; resolution_hypothesis: string | null }>
    sources: { conflict_id: string; source_id: string }[]
  }
  node?: {
    claim: ClaimRow
    neighborhood: { node_kind: string; node_id: string; depth: number; preview: string }[]
    derivation_paths: { terminals: { depth: number; terminal_type: string | null; node_id: string }[]; max_depth: number; truncated: boolean }
    near_dups: { claim_id: string; quest_seq: number; terminal_type: string | null }[]
  }
}

export default function Browser() {
  usePage<SharedProps>().props
  const p = usePage<BrowserProps>().props
  const questId = location.pathname.split('/')[2] || ''

  return (
    <AppLayout>
      <Head title="Graph" />
      <div className="mx-auto max-w-4xl space-y-4 p-6">
        <h1 className="text-xl font-semibold">Graph browser</h1>

        <section data-testid="claims">
          <h2 className="text-lg font-semibold">Claims</h2>
          {p.claims.rows.map((c) => (
            <p key={c.id} className="text-sm">
              <a href={`/quests/${questId}/graph?node=${c.id}`} className="underline">K{c.quest_seq}</a>{' '}
              {c.text}
              {c.terminal_type && <span className="text-muted-foreground"> · {c.terminal_type}</span>}
            </p>
          ))}
          <ShowingOf listing={p.claims} />
        </section>

        {p.node && (
          <section data-testid="node-traversal" className="space-y-1">
            <h2 className="text-lg font-semibold">Node K{p.node.claim.quest_seq}</h2>
            <p className="text-sm text-muted-foreground">
              neighborhood: {p.node.neighborhood.length} node(s) · derivation paths reach depth{' '}
              {p.node.derivation_paths.max_depth}
              {p.node.derivation_paths.truncated ? ' (truncated at the config cap)' : ''}
            </p>
            {p.node.near_dups.length > 0 && (
              <p className="text-sm">near-dup candidates: {p.node.near_dups.length}</p>
            )}
          </section>
        )}

        <section data-testid="hub">
          <h2 className="text-lg font-semibold">Cross-quest hub</h2>
          <p className="text-sm text-muted-foreground">
            reused: {p.hub.reused.rows.length} (of {p.hub.reused.requested}) · type-divergent:{' '}
            {p.hub.type_divergent.rows.length}
          </p>
          {p.hub.type_divergent.rows.map((r) => (
            <p key={r.canonical_text + (r.terminal_type ?? '')} className="text-sm">
              {r.canonical_text} · {r.terminal_type} · across {r.quest_count} quest(s)
            </p>
          ))}
          <ShowingOf listing={p.hub.reused} />
        </section>

        <section data-testid="conflicts-docket">
          <h2 className="text-lg font-semibold">Conflicts docket</h2>
          {p.conflicts.conflicts.rows.map((c) => (
            <Card key={c.id}>
              <CardHeader>
                <CardTitle className="text-sm">{c.divergence}</CardTitle>
              </CardHeader>
              <CardContent className="space-y-2 text-sm text-muted-foreground">
                {c.resolution_hypothesis ?? 'no hypothesis yet — hypothesize to adjudicate'}
                <form method="post"
                      action={`/quests/${questId}/graph/conflicts/${c.id}/hypothesis`}
                      className="flex gap-2">
                  <input type="hidden" name="_csrf_token" value={csrfToken()} />
                  <input name="hypothesis" placeholder="the resolution hypothesis (non-empty)"
                         className="w-80 rounded border px-2 py-1 text-sm" />
                  <button type="submit" className="rounded border px-2 py-1 text-sm">
                    Hypothesize
                  </button>
                </form>
              </CardContent>
            </Card>
          ))}
          <ShowingOf listing={p.conflicts.conflicts} />
          <form data-testid="conflict-ledger-form" method="post"
                action={`/quests/${questId}/graph/conflicts`}
                className="mt-2 space-y-2 rounded border p-3 text-sm">
            <div className="font-medium">Ledger a conflict (the courtroom's first act)</div>
            <input type="hidden" name="_csrf_token" value={csrfToken()} />
            <input name="claim_id" placeholder="the claim id"
                   className="w-80 rounded border px-2 py-1 text-sm" />
            <input name="divergence" placeholder="the divergence (non-empty)"
                   className="w-96 rounded border px-2 py-1 text-sm" />
            <input name="hypothesis" placeholder="hypothesis (optional)"
                   className="w-96 rounded border px-2 py-1 text-sm" />
            <input name="source_urns[]" placeholder="exhibit source urn (repeatable)"
                   className="w-96 rounded border px-2 py-1 text-sm" />
            <button type="submit" className="rounded border px-2 py-1 text-sm">Ledger</button>
          </form>
        </section>

        <section data-testid="lineage" className="text-sm text-muted-foreground">
          lineage: {p.lineage.map((l) => `${l.ancestor_topic} (${l.via_provenance_kind}, d${l.depth})`).join(' · ') || 'none'}
        </section>
      </div>
    </AppLayout>
  )
}
