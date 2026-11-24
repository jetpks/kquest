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
import ShowingOf from '@/components/ShowingOf'
import { BriefingProps, SharedProps } from '@/types'

// THE INTERACTIVE BRIEFING (I06 §8 + I08 §5.3 / I17 Part 3): the session
// open/state (the LANDED launch gate — decompose round 1 per I01 DR-13),
// the agenda staging form (the LANDED FetchBody door — role `agenda`, idem
// by content address, keyless), the agenda list (capped), the topic-questions
// form (the I03 DR-14 carrier) with the optional topic freeze, the
// agenda_staged gate state rendered HONESTLY (sign-off without staged agenda
// leaves the worker awaiting_briefing — presented, never blocked), and the
// sign-off button (POSTs the landed console/session/end door — DR-04 ruling
// A: the operator ends the session; autonomy resumes). NO web-process LLM
// turns anywhere — the agent half of round 1 is the autonomous decompose the
// hand-off opens.
export default function Briefing() {
  const { current_user } = usePage<SharedProps>().props
  const p = usePage<BriefingProps>().props
  const live = !!p.session

  return (
    <AppLayout>
      <Head title={`Briefing — ${p.quest.topic}`} />
      <div className="mx-auto max-w-4xl space-y-4 p-6">
        <section data-testid="briefing-header">
          <h1 className="text-xl font-semibold">{p.quest.topic}</h1>
          <p className="text-sm text-muted-foreground">
            state {p.quest.state}
            {p.binding_phase && ` · binding phase ${p.binding_phase}`}
          </p>
        </section>

        <section data-testid="session-state" className="space-y-2">
          <Card>
            <CardHeader>
              <CardTitle className="text-sm">Briefing session</CardTitle>
              <CardDescription className="text-xs">
                the launch gate: mode interactive, driver operator — one active writer per quest
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-2 text-sm">
              {live ? (
                <p data-testid="session-live">
                  live session {p.session!.id.slice(0, 8)} ({p.session!.model}) — the operator holds
                  the write gate
                </p>
              ) : (
                <p data-testid="session-absent" className="text-muted-foreground">
                  no open briefing session.
                </p>
              )}
              {!live && (
                <form method="post" action={`/quests/${p.quest.id}/briefing/session`}>
                  <input type="hidden" name="authenticity_token" value={csrfToken()} />
                  <button type="submit" className="rounded border px-2 py-1 text-sm">
                    Open the briefing session
                  </button>
                </form>
              )}
              <form method="post" action={`/quests/${p.quest.id}/console/session/end`}>
                <input type="hidden" name="authenticity_token" value={csrfToken()} />
                <button type="submit" disabled={!live}
                        className="rounded border px-2 py-1 text-sm disabled:opacity-40">
                  Sign-off (ends the session)
                </button>
                <span className="ml-2 text-xs text-muted-foreground">
                  the sign-off is the autonomy threshold — the orchestrator resumes at its next tick
                </span>
              </form>
            </CardContent>
          </Card>
        </section>

        <section data-testid="agenda-gate" className="text-sm">
          <span className="font-medium">agenda_staged gate: </span>
          <span data-testid="agenda-staged-state" className={p.agenda_staged ? '' : 'text-muted-foreground'}>
            {p.agenda_staged
              ? 'STAGED — the briefing-init phase_complete → decompose transition hands autonomy.'
              : 'not staged — sign-off without staged agenda leaves the worker awaiting_briefing (presented, never blocked).'}
          </span>
        </section>

        <section data-testid="agenda-stage-form" className="space-y-2">
          <h2 className="text-lg font-semibold">Stage an agenda doc</h2>
          <form method="post" action={`/quests/${p.quest.id}/briefing/agenda`} className="space-y-2">
            <input type="hidden" name="authenticity_token" value={csrfToken()} />
            <input name="url" placeholder="https://…" disabled={!live}
                   className="w-80 rounded border px-2 py-1 text-sm" />
            <input name="title" placeholder="title" disabled={!live}
                   className="w-80 rounded border px-2 py-1 text-sm" />
            <textarea name="text" placeholder="the document text (the operator supplies it — keyless)"
                      disabled={!live} rows={4} className="w-full rounded border px-2 py-1 text-sm" />
            <button type="submit" disabled={!live}
                    className="rounded border px-2 py-1 text-sm disabled:opacity-40">
              Stage (content-address idem — re-staging registers membership only)
            </button>
          </form>
        </section>

        <section data-testid="agenda-list" className="space-y-1">
          <h2 className="text-lg font-semibold">Agenda ({p.agenda.rows.length})</h2>
          {p.agenda.rows.map((doc) => (
            <p key={doc.id} className="text-sm">
              {doc.title} · <span className="font-mono text-muted-foreground">{doc.urn}</span>
            </p>
          ))}
          {p.agenda.rows.length === 0 && (
            <p className="text-sm text-muted-foreground">nothing staged yet.</p>
          )}
          <ShowingOf listing={p.agenda} />
        </section>

        <section data-testid="questions-form" className="space-y-2">
          <h2 className="text-lg font-semibold">Topic questions</h2>
          <p className="text-xs text-muted-foreground">
            current: {p.topic_questions.length > 0 ? p.topic_questions.join(' · ') : 'none recorded'}
          </p>
          <form method="post" action={`/quests/${p.quest.id}/briefing/questions`} className="space-y-2">
            <input type="hidden" name="authenticity_token" value={csrfToken()} />
            <input name="questions[]" placeholder="question 1" disabled={!live}
                   className="w-80 rounded border px-2 py-1 text-sm" />
            <input name="questions[]" placeholder="question 2" disabled={!live}
                   className="w-80 rounded border px-2 py-1 text-sm" />
            <input name="topic" placeholder={`freeze the topic (current: ${p.topic})`} disabled={!live}
                   className="w-80 rounded border px-2 py-1 text-sm" />
            <button type="submit" disabled={!live}
                    className="rounded border px-2 py-1 text-sm disabled:opacity-40">
              Record (the merge rides the binding phase's result)
            </button>
          </form>
        </section>

        <section data-testid="surface-links" className="space-x-4 text-sm">
          <a href={p.console_url} className="underline">Console</a>
          <a href={p.view_url} className="underline">Quest view</a>
          {current_user && <span className="text-muted-foreground">signed in as {current_user.username}</span>}
        </section>
      </div>
    </AppLayout>
  )
}
