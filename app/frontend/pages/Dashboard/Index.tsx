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
// auth door — a redirect here would loop). Signed-in: the pre-briefing
// create-quest form (topic + budgets + routing map), then quest cards
// (capped), the blind-spot panel (Metrics families + the overhang join), the
// honesty-bounds ladder (static text, I07 §1's guarantee map), and the
// workspace-admin section (I19): the WRITE half of the I02 workspace/sharing
// model — create/rename workspaces, add/remove members, grant
// public/workspace scope, revoke — seven forms over the four capped lists.
export type OwnedWorkspaceRow = { id: string; name: string; created_at: string }
export type MemberRow = {
  workspace_id: string
  workspace_name: string
  user_id: string
  handle: string
  joined_at: string
}
export type MembershipRow = { workspace_id: string; workspace_name: string; joined_at: string }
export type GrantRow = {
  id: string
  source_id: string
  source_urn: string
  source_title: string | null
  grantee_user_id: string | null
  grantee_handle: string | null
  grantee_workspace_id: string | null
  workspace_name: string | null
  is_public: boolean
  note: string | null
  granted_at: string
}
export type DashboardProps = {
  quests?: CappedListing<QuestRow>
  blind_spots?: MetricsFamily[]
  overhang?: OverhangRow[]
  workspaces?: {
    owned: CappedListing<OwnedWorkspaceRow>
    members: CappedListing<MemberRow>
    memberships: CappedListing<MembershipRow>
    grants: CappedListing<GrantRow>
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
                    <input type="hidden" name="_csrf_token" value={csrfToken()} />
                    <input name="topic" required placeholder="topic — what this quest is after"
                           className="w-full rounded border px-2 py-1 text-sm" />
                    <fieldset className="space-y-1">
                      <legend data-testid="budget-semantics" className="text-xs text-muted-foreground">
                        whole-quest lifetime caps — when one is hit the quest pauses;
                        the console&rsquo;s resume door can only raise them, never lower
                      </legend>
                      <div className="grid gap-2 sm:grid-cols-3">
                        <input name="web_call_budget" type="number" min="0" placeholder="web calls, e.g. 40"
                               className="rounded border px-2 py-1 text-sm" />
                        <input name="token_budget" type="number" min="0" placeholder="tokens, e.g. 200000"
                               className="rounded border px-2 py-1 text-sm" />
                        <input name="spend_budget_usd" placeholder="US$ e.g. 2.50"
                               className="rounded border px-2 py-1 text-sm" />
                      </div>
                    </fieldset>
                    <details data-testid="advanced-routing" className="space-y-2 rounded border p-2">
                      <summary className="cursor-pointer text-sm text-muted-foreground">
                        Advanced routing — optional; blank uses the engine&rsquo;s configured defaults
                      </summary>
                      <p className="text-xs text-muted-foreground">
                        model_config routes a phase kind to a configured model — keys:
                        decompose · frontier-build · descent · synthesis · verification
                      </p>
                      <input name="model_config" placeholder='e.g. {"synthesis": "<a configured model id>"}'
                             className="w-full rounded border px-2 py-1 text-sm" />
                      <p className="text-xs text-muted-foreground">
                        {'process_config sets process knobs — e.g. {"modes": {…}} advisory toggles, {"overlays": "quest-local law text"}'}
                      </p>
                      <input name="process_config" placeholder='e.g. {"modes": {"verification": true}}'
                             className="w-full rounded border px-2 py-1 text-sm" />
                    </details>
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

            <section data-testid="workspaces" className="space-y-2">
              <h2 className="text-lg font-semibold">Workspaces</h2>

              {/* I19: the WRITE half of the I02 workspace/sharing model —
                  seven forms (the affordance-AC lesson: the FORM is the
                  deliverable — hidden _csrf_token + named fields + POST). */}
              <form data-testid="create-workspace-form" method="post" action="/workspaces"
                    className="space-y-2 rounded border p-2">
                <input type="hidden" name="_csrf_token" value={csrfToken()} />
                <input name="name" required placeholder="workspace slug, e.g. my-lab"
                       className="w-full rounded border px-2 py-1 text-sm" />
                <p className="text-xs text-muted-foreground">
                  name must match ^[a-z0-9][a-z0-9-]&#123;0,63&#125;$ — a lowercase slug,
                  1-64 chars (global; created workspaces make you their first member)
                </p>
                <button type="submit" className="rounded border px-2 py-1 text-sm">
                  Create workspace
                </button>
              </form>

              <form data-testid="public-grant-form" method="post" action="/grants/public"
                    className="space-y-2 rounded border p-2">
                <input type="hidden" name="_csrf_token" value={csrfToken()} />
                <p className="text-xs text-muted-foreground">
                  make one of your sources public — the grant row records who/why
                </p>
                <input name="source_urn" required placeholder="kb:src:… (a source you own)"
                       className="w-full rounded border px-2 py-1 text-sm" />
                <input name="note" required placeholder="why — the grant records who/why"
                       className="w-full rounded border px-2 py-1 text-sm" />
                <button type="submit" className="rounded border px-2 py-1 text-sm">
                  Make source public
                </button>
              </form>

              {props.workspaces && props.workspaces.owned.rows.length === 0 && (
                <p className="text-sm text-muted-foreground">
                  No workspaces yet — create one above; grants you issue are listed below.
                </p>
              )}

              {props.workspaces?.owned.rows.map((w) => (
                <Card key={w.id} data-testid="workspace-card" className="space-y-2">
                  <CardHeader>
                    <CardTitle className="text-sm">{w.name}</CardTitle>
                    <CardDescription className="text-xs">owned workspace</CardDescription>
                  </CardHeader>
                  <CardContent className="space-y-3">
                    <div className="grid gap-2 sm:grid-cols-2">
                      <form data-testid="workspace-rename-form" method="post"
                            action={`/workspaces/${w.id}/rename`} className="flex gap-2">
                        <input type="hidden" name="_csrf_token" value={csrfToken()} />
                        <input name="name" required placeholder="new slug"
                               className="w-full rounded border px-2 py-1 text-sm" />
                        <button type="submit" className="rounded border px-2 py-1 text-sm">
                          Rename
                        </button>
                      </form>
                      <form data-testid="add-member-form" method="post"
                            action={`/workspaces/${w.id}/members`} className="flex gap-2">
                        <input type="hidden" name="_csrf_token" value={csrfToken()} />
                        <input name="handle" required placeholder="user handle, e.g. gh-…"
                               className="w-full rounded border px-2 py-1 text-sm" />
                        <button type="submit" className="rounded border px-2 py-1 text-sm">
                          Add member
                        </button>
                      </form>
                    </div>
                    <ul className="space-y-1">
                      {(props.workspaces?.members.rows ?? [])
                        .filter((m) => m.workspace_id === w.id)
                        .map((m) => (
                          <li key={m.user_id} className="flex items-center gap-2 text-sm">
                            <span>
                              {m.handle}
                              <span className="text-muted-foreground">
                                {' '}(joined {m.joined_at})
                              </span>
                            </span>
                            <form data-testid="remove-member-form" method="post"
                                  action={`/workspaces/${w.id}/members/remove`}>
                              <input type="hidden" name="_csrf_token" value={csrfToken()} />
                              <input type="hidden" name="handle" value={m.handle} />
                              <button type="submit"
                                      className="rounded border px-2 py-0.5 text-xs">
                                remove
                              </button>
                            </form>
                          </li>
                        ))}
                    </ul>
                    <form data-testid="workspace-grant-form" method="post"
                          action={`/workspaces/${w.id}/grants`} className="space-y-2">
                      <input type="hidden" name="_csrf_token" value={csrfToken()} />
                      <p className="text-xs text-muted-foreground">
                        grant one of your sources to {w.name} — its members can read it
                      </p>
                      <input name="source_urn" required placeholder="kb:src:… (a source you own)"
                             className="w-full rounded border px-2 py-1 text-sm" />
                      <input name="note" required placeholder="why — the grant records who/why"
                             className="w-full rounded border px-2 py-1 text-sm" />
                      <button type="submit" className="rounded border px-2 py-1 text-sm">
                        Grant source to {w.name}
                      </button>
                    </form>
                  </CardContent>
                </Card>
              ))}
              <ShowingOf listing={props.workspaces?.owned} />
              <ShowingOf listing={props.workspaces?.members} />

              <div className="space-y-1">
                <h3 className="text-sm font-medium">Your memberships</h3>
                {(props.workspaces?.memberships.rows ?? []).map((m) => (
                  <p key={m.workspace_id} className="text-sm text-muted-foreground">
                    member of {m.workspace_name} (joined {m.joined_at})
                  </p>
                ))}
                {(props.workspaces?.memberships.rows ?? []).length === 0 && (
                  <p className="text-sm text-muted-foreground">no memberships yet.</p>
                )}
                <ShowingOf listing={props.workspaces?.memberships} />
              </div>

              <div className="space-y-1">
                <h3 className="text-sm font-medium">Grants you issued</h3>
                {(props.workspaces?.grants.rows ?? []).map((g) => (
                  <div key={g.id} className="flex items-center gap-2 text-sm">
                    <span>
                      {g.source_urn}
                      {g.source_title ? ` — ${g.source_title}` : ''} · {grantScope(g)}
                      {g.note ? ` · note: ${g.note}` : ''} · granted {g.granted_at}
                    </span>
                    <form data-testid="revoke-grant-form" method="post"
                          action={`/grants/${g.id}/revoke`}>
                      <input type="hidden" name="_csrf_token" value={csrfToken()} />
                      <button type="submit" className="rounded border px-2 py-0.5 text-xs">
                        revoke
                      </button>
                    </form>
                  </div>
                ))}
                {(props.workspaces?.grants.rows ?? []).length === 0 && (
                  <p className="text-sm text-muted-foreground">no grants issued.</p>
                )}
                <ShowingOf listing={props.workspaces?.grants} />
              </div>
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

// The I02 scope ladder's display half: public (the global door), workspace
// (a named group), shared (one user — rendered read-only; the row is the
// operator's own and stays revocable), private is the ABSENCE of a grant
// row and never reaches this list.
function grantScope(g: GrantRow): string {
  if (g.is_public) return 'public'
  if (g.grantee_workspace_id) return `workspace ${g.workspace_name ?? ''}`
  if (g.grantee_user_id) return `shared with ${g.grantee_handle ?? ''}`
  return 'unknown'
}

// The F10 move (I17): the shared "showing N of M" caption lives in
// components/ShowingOf.tsx — the definition above is gone; Dashboard imports
// it from there. The re-export is a compat shim for the ONE legacy consumer
// outside the I17 touch set (pages/Costs/Index.tsx); new surfaces import the
// component directly.
export { default as ShowingOf } from '@/components/ShowingOf'
