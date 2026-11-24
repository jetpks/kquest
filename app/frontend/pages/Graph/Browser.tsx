import { Head, usePage } from '@inertiajs/react'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import AppLayout from '@/layouts/AppLayout'
import { ShowingOf } from '@/pages/Dashboard/Index'
import { CappedListing, SharedProps } from '@/types'

// The GRAPH BROWSER (I08 §4 row 4 / I16 Part 6): claims/evidence/edges/
// derivations capped; closure status per claim; lineage; the CROSS-QUEST HUB
// tab (reuse + type-divergence rows over v_canonical_claims); the
// conflicts-ledger docket READ-ONLY (adjudication is I17's). Traversal is
// Inertia-native: ?node=<claim_id> adds the node's neighborhood + derivation
// paths through the canonical query services. All writes here are I17's.
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
          <h2 className="text-lg font-semibold">Conflicts docket (read-only)</h2>
          {p.conflicts.conflicts.rows.map((c) => (
            <Card key={c.id}>
              <CardHeader>
                <CardTitle className="text-sm">{c.divergence}</CardTitle>
              </CardHeader>
              <CardContent className="text-sm text-muted-foreground">
                {c.resolution_hypothesis ?? 'no hypothesis yet — adjudication is I17\u2019s'}
              </CardContent>
            </Card>
          ))}
          <ShowingOf listing={p.conflicts.conflicts} />
        </section>

        <section data-testid="lineage" className="text-sm text-muted-foreground">
          lineage: {p.lineage.map((l) => `${l.ancestor_topic} (${l.via_provenance_kind}, d${l.depth})`).join(' · ') || 'none'}
        </section>
      </div>
    </AppLayout>
  )
}
