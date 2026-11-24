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
