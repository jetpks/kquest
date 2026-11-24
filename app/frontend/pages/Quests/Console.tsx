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
import EventFeed from '@/components/EventFeed'
import ShowingOf from '@/components/ShowingOf'
import { ConsoleProps, MenuRow, SharedProps } from '@/types'

// THE STEERING CONSOLE (I08 §4 row 6 / I08 §5 / I17 Part 1): the state
// banner, the parity line (composed through the shared formatter
// server-side — the line arrives ready), the read-only live view (the
// shared EventFeed on the I15 FROZEN stream URL), and the menus with their
// evidence and the steering doors' option forms. ZERO auto-enforcement: no
// pre-selects (every control renders blank — no defaultValue, no default
// checked), no timeout picks, no default on operator silence; every choice
// is an explicit operator-confirmed POST through the landed doors. While
// `active` the console is the read-only live view + the landed pause button
// ONLY — every steering control is DISABLED, rendered from state (the
// disablement is structural, not a policy toggle). The UI never spawns
// workers and never runs LLM turns (the launcher owns boot).
export default function Console() {
  const { current_user } = usePage<SharedProps>().props
  const p = usePage<ConsoleProps>().props
  const active = p.quest.state === 'active'
  const questId = p.quest.id

  return (
    <AppLayout>
      <Head title={`Console — ${p.quest.topic}`} />
      <div className="mx-auto max-w-4xl space-y-4 p-6">
        <section data-testid="console-header">
          <h1 className="text-xl font-semibold">{p.quest.topic}</h1>
          <p className="text-sm text-muted-foreground">
            state {p.quest.state}
            {active ? ' — the console is the live view + the pause button while the quest runs' : ''}
            {p.session && ` · operator session ${p.session.id.slice(0, 8)} live (${p.session.model})`}
          </p>
        </section>

        <Card data-testid="parity-block">
          <CardHeader>
            <CardTitle className="text-sm">Parity block</CardTitle>
            <CardDescription className="text-xs">
              the shared quest_status line (byte-faithful by composition)
            </CardDescription>
          </CardHeader>
          <CardContent>
            <pre className="overflow-x-auto rounded bg-muted p-2 font-mono text-xs">{p.parity_line}</pre>
          </CardContent>
        </Card>

        {active && (
          <section data-testid="pause-door" className="space-x-2">
            <form method="post" action={`/quests/${questId}/pause`} className="inline">
              <input type="hidden" name="authenticity_token" value={csrfToken()} />
              <button type="submit" className="rounded border px-2 py-1 text-sm">
                Pause
              </button>
            </form>
            <span className="text-xs text-muted-foreground">
              pause is the ONLY door while running — steering lands at the pause door
            </span>
          </section>
        )}

        <section data-testid="steering-doors" className="space-y-3">
          <h2 className="text-lg font-semibold">Steering doors</h2>
          <p className="text-xs text-muted-foreground">
            every override is a ledgered transition — one lifecycle row recording every
            changed key from→to with who/why. Budgets may only RAISE, and only on
            resume/restart. A live operator session holds the write gate — end it first.
          </p>
          <DoorForms questId={questId} state={p.quest.state} sessionOpen={!!p.session} muted={p.mutes.rows} />
        </section>

        <section data-testid="menus" className="space-y-3">
          <h2 className="text-lg font-semibold">Runtime-decision menus</h2>
          {p.menus.length === 0 && (
            <p className="text-sm text-muted-foreground">
              {active
                ? 'no menus while the quest runs — the live view + pause only.'
                : 'no trigger-specific menu — the generic doors above are the whole set.'}
            </p>
          )}
          {p.menus.map((menu) => (
            <MenuCard key={menu.id} menu={menu} questId={questId} disabled={active} />
          ))}
        </section>

        <section data-testid="routing-map" className="space-y-2">
          <h2 className="text-lg font-semibold">Routing map</h2>
          <p className="text-xs text-muted-foreground">
            the routing edits ride the resume/restart doors (a recorded merge); the ladder
            evidence below is cited per model — reviewable, never a blocker.
          </p>
          <Card>
            <CardHeader>
              <CardTitle className="text-sm">model_config (the merge target)</CardTitle>
              <CardDescription className="text-xs">
                keys are the five phase kinds; values non-empty strings
              </CardDescription>
            </CardHeader>
            <CardContent>
              <pre className="overflow-x-auto font-mono text-xs">{JSON.stringify(p.quest.model_config, null, 2)}</pre>
            </CardContent>
          </Card>
          <Card>
            <CardHeader>
              <CardTitle className="text-sm">Ladder evidence (ladder_passes)</CardTitle>
              <CardDescription className="text-xs">
                most recent pass first · overrides are recorded, never blocked
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-1 text-xs">
              {p.ladder_passes.rows.length === 0 && (
                <span className="text-muted-foreground">no ladder passes recorded</span>
              )}
              {p.ladder_passes.rows.map((r) => (
                <p key={r.id} className="font-mono">
                  {r.model} · {r.rung} · {r.passed_at} · {r.passed_by} — {r.evidence_ref}
                </p>
              ))}
              <ShowingOf listing={p.ladder_passes} />
            </CardContent>
          </Card>
        </section>

        <section data-testid="stop-rules-echo" className="space-y-1">
          <h2 className="text-lg font-semibold">Stop rules (the menus' evidence)</h2>
          {p.stop_rules.map((r) => (
            <p key={r.rule_id} className="font-mono text-xs">
              {r.rule_id} · {r.scope} · {r.metric} {r.operator} {r.default} · {r.action} · {r.config_key}
            </p>
          ))}
        </section>

        <section data-testid="mute-rows" className="space-y-1">
          <h2 className="text-lg font-semibold">Mutes for this quest</h2>
          {p.mutes.rows.length === 0 && (
            <p className="text-sm text-muted-foreground">none — every signal renders.</p>
          )}
          {p.mutes.rows.map((m) => (
            <p key={m.key} className="text-xs text-muted-foreground">
              {m.key} — {m.text_value} — {m.provenance}
            </p>
          ))}
          <ShowingOf listing={p.mutes} />
        </section>

        <section data-testid="steering-history" className="space-y-1">
          <h2 className="text-lg font-semibold">Steering history</h2>
          {p.lifecycle.rows.map((e) => (
            <p key={e.id} className="text-sm">
              {e.from_state} → {e.to_state} · {e.actor} · {e.note}
            </p>
          ))}
          <ShowingOf listing={p.lifecycle} />
        </section>

        <section data-testid="live-view">
          <h2 className="text-lg font-semibold">Live view (read-only)</h2>
          <EventFeed url={p.stream_url} />
        </section>

        <section data-testid="surface-links" className="space-x-4 text-sm">
          <a href={p.view_url} className="underline">Quest view</a>
          <a href={p.briefing_url} className="underline">Briefing</a>
          {current_user && <span className="text-muted-foreground">signed in as {current_user.username}</span>}
        </section>
      </div>
    </AppLayout>
  )
}

// The steering doors (I17 Part 2): resume (with the recorded-merge fields),
// stop, restart, session end, and the mute — native form POSTs with the
// landed csrf.ts idiom. EVERY control is disabled while the quest is active
// (structural, from state); no field carries a pre-set value (zero
// auto-enforcement — the operator types the override, the door records it).
function DoorForms({ questId, state, sessionOpen, muted }: {
  questId: string
  state: string
  sessionOpen: boolean
  muted: { key: string }[]
}) {
  const disabled = state === 'active'
  const mutedPairs = muted.map((m) => m.key.split('.').slice(-2).join('.'))
  return (
    <div className="space-y-2">
      <form data-testid="resume-form" method="post" action={`/quests/${questId}/console/resume`}
            className="space-y-2 rounded border p-3 text-sm">
        <div className="text-sm font-medium">Resume (paused → active, the recorded-merge door)</div>
        <input name="web_call_budget" type="number" min="0" placeholder="web_call_budget (only-raise)"
               disabled={disabled} className="rounded border px-2 py-1 text-sm" />
        <input name="token_budget" type="number" min="0" placeholder="token_budget (only-raise)"
               disabled={disabled} className="rounded border px-2 py-1 text-sm" />
        <input name="spend_budget_usd" placeholder="spend_budget_usd (only-raise)"
               disabled={disabled} className="rounded border px-2 py-1 text-sm" />
        <input name="process_config" placeholder='process_config JSON object, e.g. {"modes":{…}}'
               disabled={disabled} className="w-72 rounded border px-2 py-1 text-sm" />
        <input name="model_config" placeholder='model_config JSON object, e.g. {"decompose":"…"}'
               disabled={disabled} className="w-72 rounded border px-2 py-1 text-sm" />
        <input name="note" placeholder="why (required with any override)"
               disabled={disabled} className="w-72 rounded border px-2 py-1 text-sm" />
        <button type="submit" disabled={disabled}
                className="rounded border px-2 py-1 text-sm disabled:opacity-40">
          Resume
        </button>
      </form>

      <form data-testid="stop-form" method="post" action={`/quests/${questId}/console/stop`}
            className="space-y-2 rounded border p-3 text-sm">
        <div className="text-sm font-medium">Stop (paused → stopped)</div>
        <input name="note" placeholder="why (recorded)" disabled={disabled}
               className="w-72 rounded border px-2 py-1 text-sm" />
        <button type="submit" disabled={state !== 'paused'}
                className="rounded border px-2 py-1 text-sm disabled:opacity-40">
          Stop
        </button>
      </form>

      <form data-testid="restart-form" method="post" action={`/quests/${questId}/console/restart`}
            className="space-y-2 rounded border p-3 text-sm">
        <div className="text-sm font-medium">Restart (stopped → active, the repair precedent)</div>
        <input name="web_call_budget" type="number" min="0" placeholder="web_call_budget (only-raise)"
               disabled={disabled} className="rounded border px-2 py-1 text-sm" />
        <input name="process_config" placeholder="process_config JSON object"
               disabled={disabled} className="w-72 rounded border px-2 py-1 text-sm" />
        <input name="model_config" placeholder="model_config JSON object"
               disabled={disabled} className="w-72 rounded border px-2 py-1 text-sm" />
        <input name="note" placeholder="why (required with any override)"
               disabled={disabled} className="w-72 rounded border px-2 py-1 text-sm" />
        <button type="submit" disabled={state !== 'stopped'}
                className="rounded border px-2 py-1 text-sm disabled:opacity-40">
          Restart
        </button>
      </form>

      <form data-testid="mute-form" method="post" action={`/quests/${questId}/console/mute`}
            className="space-y-2 rounded border p-3 text-sm">
        <div className="text-sm font-medium">Mute a signal for this quest (a display filter, recorded)</div>
        <select name="predicate" disabled={disabled} className="rounded border px-2 py-1 text-sm">
          <option value="">predicate…</option>
          {['tw_wedge', 'tw_cache_wall', 'tw_churn', 'tw_context_blowout', 'tw_empty_storm',
            'tw_fingerprint_drift', 'tw_missing_spend', 'tw_repetition', 'tw_rotation',
            'tw_shape_storm', 'tw_size_ceiling', 'tw_slowstall'].map((predicate) => (
            <option key={predicate} value={predicate}>{predicate}</option>
          ))}
        </select>
        <input name="reason" placeholder="why (required — the row records who/why)"
               disabled={disabled} className="w-72 rounded border px-2 py-1 text-sm" />
        <button type="submit" disabled={disabled}
                className="rounded border px-2 py-1 text-sm disabled:opacity-40">
          Mute
        </button>
        {mutedPairs.length > 0 && (
          <div className="text-xs text-muted-foreground">
            muted: {mutedPairs.join(', ')} — unmute:
            <select name="remove_predicate" disabled={disabled}
                    className="ml-1 rounded border px-1 py-0.5 text-xs">
              <option value="">predicate…</option>
              {mutedPairs.map((pair) => (
                <option key={pair} value={pair.split('.')[1]}>{pair}</option>
              ))}
            </select>
            <button type="submit" name="remove" value="true" disabled={disabled}
                    className="ml-1 rounded border px-1 py-0.5 text-xs disabled:opacity-40">
              remove
            </button>
          </div>
        )}
      </form>

      <form data-testid="session-end-form" method="post" action={`/quests/${questId}/console/session/end`}
            className="rounded border p-3 text-sm">
        <div className="text-sm font-medium">End the operator session (the sign-off)</div>
        <button type="submit" disabled={!sessionOpen}
                className="rounded border px-2 py-1 text-sm disabled:opacity-40">
          End session
        </button>
        <span className="ml-2 text-xs text-muted-foreground">
          {sessionOpen ? 'the operator holds the write gate' : 'no open operator session'}
        </span>
      </form>
    </div>
  )
}

// One presented menu: the trigger, the evidence (echoed config), and the
// option forms. The menu PRESENTS; it never acts — each option's action is
// the operator's explicit POST through the doors above (re-synthesis is the
// resume/restart door with the routing recorded — no spawn-shaped action).
function MenuCard({ menu, questId, disabled }: { menu: MenuRow; questId: string; disabled: boolean }) {
  const evidence = JSON.stringify(menu.evidence, null, 2)
  return (
    <Card data-testid={`menu-${menu.id}`}>
      <CardHeader>
        <CardTitle className="text-sm">{menu.id}</CardTitle>
        <CardDescription className="font-mono text-xs">{JSON.stringify(menu.trigger)}</CardDescription>
      </CardHeader>
      <CardContent className="space-y-2 text-sm">
        <pre className="overflow-x-auto rounded bg-muted p-2 font-mono text-xs">{evidence}</pre>
        <ul className="space-y-1">
          {menu.options.map((option) => (
            <li key={option.id}>{option.label}</li>
          ))}
        </ul>
        {(menu.id === 'retry-cap' || menu.id === 'slow-stall' || menu.id === 'verification-failed' ||
          menu.id === 'budget-finisher' || menu.id === 'briefing-caps') && (
          <a href={`/quests/${questId}/console`}
             className={disabled ? 'text-muted-foreground' : 'underline'}>
            dispose through the doors above (resume/restart/stop)
          </a>
        )}
        {menu.id === 'adjudication' && (
          <a href={String(menu.evidence.browser_url ?? `/quests/${questId}/graph`)} className="underline">
            open the graph browser's courtroom docket
          </a>
        )}
        {menu.id === 'stop-loud' && (
          <a href={`/quests/${questId}/console`}
             className={disabled ? 'text-muted-foreground' : 'underline'}>
            the restart door is the stopped → active repair precedent
          </a>
        )}
        {menu.id === 'transcript-ceiling' && (
          <span className="text-xs text-muted-foreground">
            the swap/compact routing rides the resume door's model_config merge
          </span>
        )}
      </CardContent>
    </Card>
  )
}
