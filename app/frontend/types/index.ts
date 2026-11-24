// Shared inertia props (config/providers/inertia.rb): the auth identity carried
// by the session and the flash bucket. Page-local props live with their pages.
export type FlashData = {
  notice?: string
  alert?: string
}

export type User = {
  id: number
  username: string
  avatar_url: string | null
}

export type SharedProps = {
  current_user: User | null
  flash: FlashData
}

// ── the read surfaces' page-local prop vocabulary (I16 Parts 1–9) ──────────

// The L15 capped-listing result: when requested > cap the page surfaces
// "showing N of M" (never silent truncation).
export type CappedListing<T> = {
  rows: T[]
  requested: number
  cap: number
  existed: number
}

export type MetricsSample = { labels: Record<string, string>; value: number }
export type MetricsFamily = {
  name: string
  help: string
  type: string
  samples: MetricsSample[]
}

export type QuestRow = {
  id: string
  topic: string
  state: string
  provenance_kind?: string
  created_at?: string
  web_call_budget?: number
  token_budget?: number
  spend_budget_usd?: string
  process_config?: Record<string, unknown>
  model_config?: Record<string, unknown>
}

export type LifecycleEvent = {
  id: string
  from_state: string
  to_state: string
  actor: string
  occurred_at: string
  note: string | null
}

export type SessionRow = {
  id: string
  mode: string
  driver: string
  model: string
  started_at: string
  ended_at: string | null
}

export type PhaseRow = {
  id: string
  kind: string
  round_no: number
  attempt_no: number
  state: string
  started_at: string | null
  ended_at: string | null
}

export type OverhangRow = { surface: string; overhang: number; capped_requests: number }

export type FireSet = {
  predicate: string
  listing: CappedListing<Record<string, unknown>>
}

// ── the steering console + briefing prop vocabulary (I17 Parts 1–3) ───────

// One I08 §5.1 runtime-decision menu — presented, never enforced: NO option
// carries a default/pick/timeout flag (the shape law), the evidence ECHOES
// config (the crossed stop_rules row, the budget columns) — never literals.
export type MenuOption = { id: string; label: string }
export type MenuRow = {
  id: string
  trigger: Record<string, unknown>
  options: MenuOption[]
  evidence: Record<string, unknown>
  routing?: boolean
}
export type LadderPassRow = {
  id: string
  model: string
  rung: string
  serving_stack: string
  passed_at: string
  evidence_ref: string
  passed_by: string
}
export type StopRuleRow = {
  rule_id: string
  scope: string
  metric: string
  default: string
  operator: string
  action: string
  config_key: string
}
export type MuteRow = { key: string; text_value: string | null; provenance: string }
export type OperatorSessionRow = { id: string; model: string; started_at: string; phase_id: string }

export type ConsoleProps = {
  quest: QuestRow
  parity_line: string
  menus: MenuRow[]
  alert_param?: string | null
  ladder_passes: CappedListing<LadderPassRow>
  stop_rules: StopRuleRow[]
  lifecycle: CappedListing<LifecycleEvent>
  mutes: CappedListing<MuteRow>
  session: OperatorSessionRow | null
  stream_url: string
  view_url: string
  briefing_url: string
}

export type AgendaRow = { id: string; urn: string; title: string; added_at: string }
export type BriefingProps = {
  quest: { id: string; topic: string; state: string }
  agenda: CappedListing<AgendaRow>
  agenda_staged: boolean
  session: OperatorSessionRow | null
  binding_phase_id: string | null
  binding_phase: string | null
  topic_questions: string[]
  topic: string
  console_url: string
  view_url: string
}
