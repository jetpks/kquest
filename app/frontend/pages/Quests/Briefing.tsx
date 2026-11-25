import { Head, usePage, router } from '@inertiajs/react'
import { useEffect } from 'react'
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
import { BriefingProps, SharedProps, TranscriptLine } from '@/types'

// THE CHAT (I06 §8 + the §8 amendment / I18 Spec Part 2.5): ONE chat surface
// — the conversation replays from the ledger blob (the transcript list), the
// operator's send box ENQUEUEs a turn (POST to the turns door with the
// `_csrf_token` wire name — NO LLM in the web process; the worker executes
// the agent half), still-enqueued turns render as queued, and the agenda
// list + the agenda_staged gate state + the topic questions + the topic
// render AS TRANSCRIPT CONTEXT — never as forms (no staging inputs, no
// question inputs, no topic-freeze box anywhere in this tree). The
// open-session button (absent session) and the sign-off button (the console
// door, disabled without a session) carry the honest gate line: sign-off
// without staged agenda leaves the worker awaiting_briefing — presented,
// never blocked. ONE EventSource on the frozen stream URL; EVERY event
// reloads the page props (the transcript + queued + gate context refetch).
function ChatLine({ line }: { line: TranscriptLine }) {
  if (line.kind === 'operator') {
    return (
      <div className="flex justify-end">
        <p className="max-w-[80%] rounded-lg bg-primary px-3 py-2 text-sm text-primary-foreground whitespace-pre-wrap">
          {line.body}
        </p>
      </div>
    )
  }
  if (line.kind === 'final') {
    return (
      <div className="flex justify-start">
        <p className="max-w-[80%] rounded-lg bg-muted px-3 py-2 text-sm whitespace-pre-wrap">
          {line.body}
        </p>
      </div>
    )
  }
  if (line.kind === 'tool_call') {
    return (
      <p className="font-mono text-xs text-muted-foreground">
        → {line.tool}({line.excerpt})
      </p>
    )
  }
  if (line.kind === 'tool_result') {
    return (
      <p className={`font-mono text-xs ${line.is_error ? 'text-destructive' : 'text-muted-foreground'}`}>
        ← {line.tool}{line.is_error ? ' (error)' : ''}: {line.excerpt}
      </p>
    )
  }
  return (
    <p className="rounded border border-dashed px-2 py-1 font-mono text-xs text-muted-foreground">
      [salvaged partial — audit only] {line.body}
    </p>
  )
}

export default function Briefing() {
  const { current_user } = usePage<SharedProps>().props
  const p = usePage<BriefingProps>().props
  const live = !!p.session

  useEffect(() => {
    // jsdom has no EventSource — the EventFeed guard pattern; the tests
    // install a mock. ONE subscription, owned by the page (no new files).
    if (typeof window.EventSource === 'undefined') return
    const source = new window.EventSource(p.stream_url)
    source.onmessage = () => {
      router.reload()
    }
    return () => source.close()
  }, [p.stream_url])

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
                  <input type="hidden" name="_csrf_token" value={csrfToken()} />
                  <button type="submit" className="rounded border px-2 py-1 text-sm">
                    Open the briefing session
                  </button>
                </form>
              )}
              <form method="post" action={`/quests/${p.quest.id}/console/session/end`}>
                <input type="hidden" name="_csrf_token" value={csrfToken()} />
                <button type="submit" disabled={!live}
                        className="rounded border px-2 py-1 text-sm disabled:opacity-40">
                  Sign-off (ends the session)
                </button>
                <span className="ml-2 text-xs text-muted-foreground" data-testid="gate-honesty">
                  {p.agenda_staged
                    ? 'the sign-off is the autonomy threshold — the orchestrator resumes at its next tick'
                    : 'sign-off without staged agenda leaves the worker awaiting_briefing (presented, never blocked)'}
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

        <section data-testid="chat-transcript" className="space-y-2">
          <h2 className="text-lg font-semibold">Conversation</h2>
          {p.transcript.lines.length === 0 && (
            <p className="text-sm text-muted-foreground">
              nothing said yet — say what the quest should answer.
            </p>
          )}
          <div className="space-y-2">
            {p.transcript.lines.map((line, i) => (
              <ChatLine key={i} line={line} />
            ))}
          </div>
          {p.transcript.omitted > 0 && (
            <p className="text-xs text-muted-foreground">
              showing the last {p.transcript.lines.length} of{' '}
              {p.transcript.lines.length + p.transcript.omitted} lines.
            </p>
          )}
        </section>

        {p.queued.length > 0 && (
          <section data-testid="queued-turns" className="space-y-1">
            <h2 className="text-sm font-semibold">Queued (the worker will serve these)</h2>
            {p.queued.map((turn) => (
              <p key={turn.id} className="text-sm text-muted-foreground">
                #{turn.seq} · {turn.body}
              </p>
            ))}
          </section>
        )}

        <section data-testid="send-turn" className="space-y-2">
          <form method="post" action={`/quests/${p.quest.id}/briefing/turns`} className="space-y-2">
            <input type="hidden" name="_csrf_token" value={csrfToken()} />
            <textarea
              name="body"
              placeholder={live ? 'steer the agent — it searches, stages, and writes the questions' : 'open a briefing session first'}
              disabled={!live}
              rows={3}
              className="w-full rounded border px-2 py-1 text-sm"
            />
            <button type="submit" disabled={!live}
                    className="rounded border px-2 py-1 text-sm disabled:opacity-40">
              Send (enqueues the turn — the worker replies in the transcript)
            </button>
          </form>
        </section>

        <section data-testid="context-strip" className="space-y-1">
          <h2 className="text-sm font-semibold">Context (emerging from the conversation)</h2>
          <p className="text-sm">
            topic: <span className="font-medium">{p.topic}</span>
          </p>
          <div>
            <p className="text-sm font-medium">Topic questions ({p.topic_questions.length})</p>
            {p.topic_questions.length > 0 ? (
              p.topic_questions.map((q) => (
                <p key={q} className="text-sm text-muted-foreground">· {q}</p>
              ))
            ) : (
              <p className="text-sm text-muted-foreground">none recorded yet — the agent writes them.</p>
            )}
          </div>
          <div>
            <p className="text-sm font-medium">Agenda ({p.agenda.rows.length})</p>
            {p.agenda.rows.map((doc) => (
              <p key={doc.id} className="text-sm">
                {doc.title} · <span className="font-mono text-muted-foreground">{doc.urn}</span>
              </p>
            ))}
            {p.agenda.rows.length === 0 && (
              <p className="text-sm text-muted-foreground">nothing staged yet — the agent searches and stages.</p>
            )}
            <ShowingOf listing={p.agenda} />
          </div>
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
