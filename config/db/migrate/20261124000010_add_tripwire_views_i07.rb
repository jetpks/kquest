# frozen_string_literal: true

# The I07 tripwire views (arc ENTRY 4, Part 7): the 13 `tw_*` catalog views
# from the FROZEN design `design/I07-assurance/artifacts/tripwires-i07.sql`
# PART B, pasted VERBATIM (the gate extracts both sides and diffs — equality
# over frozen design text, the I14 exact-over-frozen-design-lists precedent).
# PART A (fixtures) and PART C (self-verification) NEVER land in the app —
# they are `check-tripwires.sh` scratch-db law. The views sit OUTSIDE the
# fidelity catalog (the I06/I13 lane-authored additive-schema precedent);
# `config/db/structure.sql` regenerates via `hanami db prepare` (the dump
# carries the views in pg_dump form — the MIGRATION is the verbatim carrier).
Sequel.migration do
  up do
    run <<~'SQL'
      -- PART B — THE CATALOG: one named tw_<id> view per signal.
      -- Every header carries: detection semantics / threshold provenance /
      -- signal action (SIGNAL ONLY — ENTRY 8 assurance_alert SSE slot; I06 owns
      -- every transition; FM-18: never auto-kill).
      -- ============================================================================
      
      -- ---------------------------------------------------------------------------
      -- tw_wedge — the frozen-ledger wedge (FM-04 tool wedge; FM-20 spawn wedge).
      -- Detection: a session row that still claims to be live (ended_at IS NULL)
      -- whose durable event ledger (tool_calls + usage_events, the L8 audit) has
      -- been silent for longer than the operator's stall window.
      -- Threshold: SR-18 engine.slow_stall_window_s = 1200 (I06 stop-rules.tsv;
      -- the operator's authoritative stall measurement window, llm-trading-v3
      -- §SLOWSTALL rule added). The per-call 120 s tool watchdog is I04 FM-04's
      -- harness half; this predicate catches the case where even that failed —
      -- the deadline row never landed (the harness lost track).
      -- Action: SIGNAL (assurance_alert). 'No tool result != no process' (FM-20):
      -- the alert carries the last tool (last_tool column — 'spawn' means: check
      -- the run registry by run id, NEVER infer child death from the missing
      -- result). If the operator stays absent past SR-19 engine.unattended_pause_s
      -- (default 3600), I06's slow_stall_unattended event pauses the quest — this
      -- predicate never transitions anything and never auto-kills (FM-18).
      -- ---------------------------------------------------------------------------
      CREATE OR REPLACE VIEW tw_wedge AS
      WITH lastev AS (
        SELECT s.id AS session_id,
               greatest(
                 s.started_at,
                 coalesce((SELECT max(tc.created_at) FROM tool_calls tc
                            WHERE tc.session_id = s.id), s.started_at),
                 coalesce((SELECT max(ue.created_at) FROM usage_events ue
                            WHERE ue.session_id = s.id), s.started_at)
               ) AS last_event_at
        FROM sessions s
      )
      SELECT s.id AS session_id, s.user_id, s.quest_id, s.phase_id, s.model,
             s.started_at, l.last_event_at,
             (extract(epoch FROM (now() - l.last_event_at)))::bigint AS last_event_age_s,
             t.tool AS last_tool, t.ok AS last_tool_ok
      FROM sessions s
      JOIN lastev l ON l.session_id = s.id
      LEFT JOIN LATERAL (
        SELECT tc.tool, tc.ok FROM tool_calls tc
        WHERE tc.session_id = s.id
        ORDER BY tc.created_at DESC, tc.seq DESC LIMIT 1
      ) t ON true
      WHERE s.ended_at IS NULL
        AND l.last_event_at < now() - interval '1200 seconds';  -- SR-18
      
      -- ---------------------------------------------------------------------------
      -- tw_slowstall — SLOWSTALL, the durable-ledger projection (FM-18).
      -- Detection: a live session whose ledger IS flowing (>= 1 event inside
      -- the window — that is tw_wedge's signature, not this one) but whose
      -- window payload is under the growth threshold: events trickling, bytes
      -- below the operator's stall line.
      -- Threshold: SR-17 engine.slow_stall_bytes = 100 over SR-18
      -- engine.slow_stall_window_s = 1200 (I06 stop-rules.tsv; FM-18; the local-
      -- model ruling: slow phases are EXPECTED — this is alert-only).
      -- Payload = octet_length(args::text) + octet_length(result::text): the
      -- verbatim audit bytes ARE transcript bytes (L8), a durable LOWER BOUND of
      -- the live transcript (DR-07; the byte-accurate live form rides the ENTRY 8
      -- watcher with these same SR-17/18 keys).
      -- Action: SIGNAL only, alert text carries the FM-18 rule: the driver is NOT
      -- to be killed on this alone; expected pace under slow local models.
      -- ---------------------------------------------------------------------------
      CREATE OR REPLACE VIEW tw_slowstall AS
      SELECT s.id AS session_id, s.user_id, s.quest_id, s.phase_id, s.model,
             s.started_at,
             w.window_events, w.window_bytes
      FROM sessions s
      JOIN LATERAL (
        SELECT count(*) AS window_events,
               coalesce(sum(octet_length(tc.args::text) + octet_length(tc.result::text)), 0) AS window_bytes
        FROM tool_calls tc
        WHERE tc.session_id = s.id
          AND tc.created_at > now() - interval '1200 seconds'  -- SR-18
      ) w ON true
      WHERE s.ended_at IS NULL
        AND w.window_events >= 1      -- flowing ledger: distinguishes SLOWSTALL from WEDGE
        AND w.window_bytes < 100;     -- SR-17
      
      -- ---------------------------------------------------------------------------
      -- tw_size_ceiling — SIZE-CEILING, the ceiling-band transcript (FM-02).
      -- Detection: a session whose cumulative verbatim audit payload has entered
      -- the ceiling BAND. The PoC measured deterministic transcript-size deaths at
      -- 496,294 B and 496,578 B (284 B apart, llm-trading-v3 §Post-resume ground
      -- truth); the early-warning line gives the operator runway ahead of the hard
      -- ceiling (SR-15 refuse new corpus ingestion / bank at the turn boundary;
      -- SR-16 end the session, then the I04 DR-06 runtime operator menu — never
      -- truncate a live transcript mid-flight, L8).
      -- Threshold: SR-15 engine.transcript_ceiling_warn_bytes = 450000 (fires);
      -- SR-16 engine.transcript_ceiling_hard_bytes = 496000 (band='hard').
      -- Honesty: audit bytes are a LOWER BOUND of the live transcript — firing is
      -- reliable, quiet is not proof (DR-07); the ENTRY 8 watcher reads the live
      -- blob size with these same keys.
      -- Action: SIGNAL (assurance_alert, band in the payload); no transitions —
      -- SR-15/16's runtime handling is I06/I04 law, this predicate only detects.
      -- ---------------------------------------------------------------------------
      CREATE OR REPLACE VIEW tw_size_ceiling AS
      SELECT s.id AS session_id, s.user_id, s.quest_id, s.phase_id, s.model,
             b.audit_bytes,
             CASE WHEN b.audit_bytes >= 496000 THEN 'hard' ELSE 'warn' END AS band
      FROM sessions s
      JOIN LATERAL (
        SELECT coalesce(sum(octet_length(tc.args::text) + octet_length(tc.result::text)), 0) AS audit_bytes
        FROM tool_calls tc
        WHERE tc.session_id = s.id
      ) b ON true
      WHERE b.audit_bytes >= 450000;  -- SR-15; band hard at SR-16's 496000
      
      -- ---------------------------------------------------------------------------
      -- tw_churn — the refusal/error churn loop (babysitter v3 CHURN counter;
      -- quest-3 SKILL law 1; quest-2 failure taxonomy).
      -- Detection: a session with a run of >= 10 consecutive failed tool calls
      -- (the ledger keeps flowing — results are refusals, not silence; that is
      -- churn, not wedge).
      -- Threshold: 10 consecutive — the quest-3 dedup-search-cap law (">~10
      -- consecutive searches with no mutation -> STOP", llm-trading-v3 §SKILL
      -- graft law 1) calibrated against the quest-2 taxonomy's measured burst
      -- shape (max 8-identical refusal burst width, 12 max class-a refusals per
      -- session — arc-run-20261121T §1). DECISIONS DR-09.
      -- Action: SIGNAL; a stuck recovery loop is operator-visible material, but
      -- in-band teaching refusals are the DESIGNED mechanism (I05) — the loop
      -- keeps running; no transition, no kill.
      -- ---------------------------------------------------------------------------
      CREATE OR REPLACE VIEW tw_churn AS
      WITH runs AS (
        SELECT tc.session_id, tc.seq, tc.ok,
               row_number() OVER (PARTITION BY tc.session_id ORDER BY tc.seq)
             - row_number() OVER (PARTITION BY tc.session_id, tc.ok ORDER BY tc.seq) AS grp
        FROM tool_calls tc
      )
      SELECT r.session_id, count(*) AS consecutive_failures,
             min(r.seq) AS first_seq, max(r.seq) AS last_seq
      FROM runs r
      WHERE r.ok = false
      GROUP BY r.session_id, r.grp
      HAVING count(*) >= 10;
      
      -- ---------------------------------------------------------------------------
      -- tw_rotation — phase rotation without completion (babysitter v3's
      -- phase-rotation liveness check, inverted).
      -- Detection: a phase attempt row whose attempt_no is beyond the phase
      -- retry cap while the phase is still unfinished — the quest is cycling
      -- attempts (wall kills, empty-completion deaths) without landing.
      -- Threshold: SR-08 phase retry cap default 3 (I06 stop-rules.tsv; PoC
      -- RETRY_CAP=3, quest-2 §Wall kills, v3 phase-105's six deaths) — fires at
      -- attempt_no > 3.
      -- Action: SIGNAL; the pause-and-present move at cap exhaustion is I06's
      -- transition row (retry_cap_exhausted -> paused) — this predicate never
      -- transitions. A raised cap (v3's RETRY_CAP=8 relaunch) is an operator
      -- decision the signal makes visible.
      -- ---------------------------------------------------------------------------
      CREATE OR REPLACE VIEW tw_rotation AS
      SELECT p.id AS phase_id, p.user_id, p.quest_id, p.kind, p.round_no,
             p.attempt_no, p.state
      FROM phases p
      WHERE p.attempt_no > 3                                -- SR-08 (default 3)
        AND p.state IN ('pending', 'running', 'failed');
      
      -- ---------------------------------------------------------------------------
      -- tw_empty_storm — the empty-completion storm (FM-01).
      -- Detection: >= 3 usage rows in one phase attempt whose request was real
      -- (input billed) but whose completion came back empty (output_tokens = 0)
      -- — the PoC's terminal-empty-assistant-event signature (rc=0, no error,
      -- 15-17 ms after tool results; llm-trading-v3 §degenerate EMPTY
      -- completions; the v3 phase-105 five-death cluster).
      -- Threshold: 3 = SR-08 phase retry cap (I06 stop-rules.tsv): three
      -- consecutive empties exhaust a phase attempt by the measured default.
      -- Zero-token all-zero rows are the FM-25 zero-usage recording, NOT this
      -- signature — input_tokens > 0 discriminates.
      -- Action: SIGNAL (the model may just be flaky — FM-01 is retryable with a
      -- fresh seed); the attempt-cap pause is I06's law.
      -- ---------------------------------------------------------------------------
      CREATE OR REPLACE VIEW tw_empty_storm AS
      SELECT ue.phase_id, ue.quest_id, ue.user_id, count(*) AS empty_completions
      FROM usage_events ue
      WHERE ue.kind = 'llm'
        AND ue.input_tokens > 0        -- a real request (not the FM-25 zero row)
        AND ue.output_tokens = 0       -- the FM-01 empty completion
      GROUP BY ue.phase_id, ue.quest_id, ue.user_id
      HAVING count(*) >= 3;             -- SR-08
      
      -- ---------------------------------------------------------------------------
      -- tw_repetition — the replay loop (FM-03).
      -- Detection: >= 3 consecutive byte-identical tool calls (same tool, op and
      -- args) in one session — the durable signature of a retry loop that never
      -- mutates state ("a failed call that does not mutate state produces an
      -- identical retry body", gateway-20261118T §identical retry bodies).
      -- Threshold: 3 — past the transport-retry caps (FM-05/FM-06/FM-08 default
      -- 3): a legal bounded retry (identical body, fresh seed) stays under it;
      -- the S_SMALL fixture pair proves the quiet side.
      -- Action: SIGNAL ('alert on repetition' — FM-03; prevention is I04's
      -- seed-variation law, not this predicate's).
      -- ---------------------------------------------------------------------------
      CREATE OR REPLACE VIEW tw_repetition AS
      WITH marked AS (
        SELECT tc.session_id, tc.seq, tc.tool, tc.op,
               (tc.tool || '|' || coalesce(tc.op, '') || '|' || tc.args::text) AS body,
               ((tc.tool || '|' || coalesce(tc.op, '') || '|' || tc.args::text) IS DISTINCT FROM
                lag(tc.tool || '|' || coalesce(tc.op, '') || '|' || tc.args::text)
                  OVER (PARTITION BY tc.session_id ORDER BY tc.seq)) AS run_start
        FROM tool_calls tc
      ), runs AS (
        SELECT session_id, seq, tool, op, body,
               sum(run_start::int) OVER (PARTITION BY session_id ORDER BY seq) AS grp
        FROM marked
      )
      SELECT session_id, tool, op, count(*) AS consecutive_identical,
             min(seq) AS first_seq, max(seq) AS last_seq
      FROM runs
      GROUP BY session_id, grp, tool, op
      HAVING count(*) >= 3;
      
      -- ---------------------------------------------------------------------------
      -- tw_missing_spend — the missing spend row (FM-25).
      -- Detection: an ENDED session that made tool calls but recorded not one
      -- llm usage_events row — spend would silently under-record (D10 cost
      -- honesty; "a missing row at rollup time is an ENTRY 7 tripwire" —
      -- FM-25). Scoped to ended sessions: a live session mid-first-turn has no
      -- rollup yet and must not false-positive.
      -- Action: SIGNAL (a ledger defect, not a model defect — the operator
      -- checks the telemetry sink wiring; the gem contract 'EXACTLY ONE terminal
      -- hook per completion' is I04 law).
      -- ---------------------------------------------------------------------------
      CREATE OR REPLACE VIEW tw_missing_spend AS
      SELECT s.id AS session_id, s.user_id, s.quest_id, s.phase_id,
             count(tc.id) AS tool_calls
      FROM sessions s
      JOIN tool_calls tc ON tc.session_id = s.id
      WHERE s.ended_at IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM usage_events ue
                        WHERE ue.session_id = s.id AND ue.kind = 'llm')
      GROUP BY s.id, s.user_id, s.quest_id, s.phase_id;
      
      -- ---------------------------------------------------------------------------
      -- tw_cache_wall — the prefix-cache wall (FM-24).
      -- Detection: >= 3 high-context turns in one session with cache_read = 0 —
      -- above the effective wall every turn pays the full re-prefill (measured:
      -- a 262k window with an 8GiB prefix cache has an effective wall ~205k,
      -- arc-run-20261122T-quest2-arc-summary §Cache-wall economics).
      -- Threshold: input_tokens >= 205000 (FM-24's measured effective wall,
      -- per-provider config cache_wall_tokens) and cache_read_tokens = 0,
      -- count >= 3 (the FM family's alert default — FM-12/FM-14 use 3).
      -- Action: SIGNAL; the routing fix (mega-context phases to cache-capable
      -- models) is I06 §7's routing map — the operator re-routes, never the
      -- predicate.
      -- ---------------------------------------------------------------------------
      CREATE OR REPLACE VIEW tw_cache_wall AS
      SELECT ue.session_id, ue.user_id, ue.quest_id,
             count(*) AS uncacheable_high_context_turns,
             max(ue.input_tokens) AS max_input_tokens
      FROM usage_events ue
      WHERE ue.kind = 'llm'
        AND ue.input_tokens >= 205000    -- FM-24 measured effective wall
        AND ue.cache_read_tokens = 0
      GROUP BY ue.session_id, ue.user_id, ue.quest_id
      HAVING count(*) >= 3;
      
      -- ---------------------------------------------------------------------------
      -- tw_shape_storm — the tool-shape honesty storm (FM-11 + FM-12; FM-14's
      -- threshold default).
      -- Detection: >= 3 calls in one session refused for stream/shape honesty
      -- classes (unknown_tool: the model names a tool absent from its surface;
      -- tool_arguments_failure: unparseable arguments at stream finalize). Both
      -- are DESIGNED in-band self-correction mechanisms (the refusal teaches,
      -- the model re-calls) — a storm means the self-correction is not landing.
      -- Threshold: 3 — unknown_tool_alert_at default 3 (FM-12) and
      -- dropped_chunk_alert_threshold default 3 (FM-14): the family's alert
      -- default. (FM-14's dropped-chunk count itself is a runtime/gem counter,
      -- not a tool_calls error_class — it rides the ENTRY 8 watcher; noted here
      -- for provenance, not as SQL.)
      -- Action: SIGNAL — a stuck model, not a bad call (FM-12's escalation
      -- rule); the loop keeps running.
      -- ---------------------------------------------------------------------------
      CREATE OR REPLACE VIEW tw_shape_storm AS
      SELECT tc.session_id, tc.user_id, tc.quest_id, count(*) AS shape_errors
      FROM tool_calls tc
      WHERE tc.error_class IN ('unknown_tool', 'tool_arguments_failure')
      GROUP BY tc.session_id, tc.user_id, tc.quest_id
      HAVING count(*) >= 3;
      
      -- ---------------------------------------------------------------------------
      -- tw_context_blowout — the full-file read storm (FM-22; judge F1).
      -- Detection: >= 3 non_sliced_read refusals in one session — the I05 frozen
      -- teaching refusal (the non-sliced-read text names the slice form and the
      -- grep-first pattern) ignored three times in a row: the 78% lesson's
      -- failure shape (corpus ingestion via full-file reads was 78% of a
      -- 79,677-token final context — 2026-11-17-arc-decompose-review.md §Q5).
      -- Threshold: 3 — the FM family's alert default (FM-12/FM-14 use 3); the
      -- S_NEAR fixture pair (2 refusals) proves the quiet side. The I05 tool
      -- boundary (read_slice hard-capped per I05 DR-04/A) and the I04 cache-wall
      -- tripwire (FM-24) are the backstops; this predicate detects the TEACHING
      -- NOT LANDING, not the ingestion itself.
      -- Action: SIGNAL (assurance_alert) — the operator sees a model ignoring
      -- the read discipline; the fix is behavioral (phase prompt / overlay),
      -- never a kill.
      -- ---------------------------------------------------------------------------
      CREATE OR REPLACE VIEW tw_context_blowout AS
      SELECT tc.session_id, tc.user_id, tc.quest_id,
             count(*) AS non_sliced_read_refusals
      FROM tool_calls tc
      WHERE tc.ok = false
        AND tc.error_class = 'non_sliced_read'
      GROUP BY tc.session_id, tc.user_id, tc.quest_id
      HAVING count(*) >= 3;   -- the FM family's alert default (FM-12/FM-14 = 3)
      
      -- ---------------------------------------------------------------------------
      -- tw_hub_divergence — the cross-quest type-divergence tripwire (D3/I02;
      -- I02 queries-i02.sql M1 leg 2 is this predicate's seed).
      -- Detection: hub entries (v_canonical_claims) whose (user, canonical
      -- text) carries more than one distinct NON-NULL terminal_type — same
      -- claim, conflicting typed verdicts, in different quests. Same-text-same-
      -- type coexists cleanly; a typed entry coexisting with an UNTERMINATED one
      -- does NOT fire (an open claim is not a conflicting verdict — both quiet
      -- sides are fixture-proven below).
      -- Threshold: none — divergence is exact, not calibrated (identity =
      -- user_id + canonical_text + terminal_type, I02 DR-02/DR-16).
      -- Action: SIGNAL (assurance_alert) — 'divergence = tripwire signal
      -- (ENTRY 7), adjudicated in the source quest' (D3). The hub is derived; it
      -- holds no state to fix — the conflict adjudication workflow (DESIGN §3)
      -- owns the follow-up: ledger a conflicts row, hypothesize, cross-examine.
      -- ---------------------------------------------------------------------------
      CREATE OR REPLACE VIEW tw_hub_divergence AS
      SELECT v.user_id, v.canonical_text, v.terminal_type, v.member_claim_ids,
             v.quest_count, v.first_seen, v.latest_seen
      FROM v_canonical_claims v
      WHERE v.type_divergent;
      
      -- ---------------------------------------------------------------------------
      -- tw_fingerprint_drift — the staleness tripwire (I02 DR-17; queries-i02.sql
      -- M3 is this predicate's seed).
      -- Detection: any pinned graph fingerprint that no longer equals the live
      -- quest fingerprint — two pin kinds: report versions pin the graph at
      -- synthesis time (a stale version is never silently fresh, R-024) and
      -- archive events pin the graph at freeze (post-archive rework is LEGAL and
      -- drifts the pin by design — detected, not prevented).
      -- Threshold: none — drift is exact inequality (fingerprint algorithm:
      -- v_quest_graph_fingerprint, I02 schema-i02.sql).
      -- Action: SIGNAL (assurance_alert, pin_kind in the payload). Stale
      -- hygiene (supersede + re-synthesize) is an operator/phase decision; a
      -- drifted archive pin is INFORMATION about a reworked quest, not a
      -- violation.
      -- ---------------------------------------------------------------------------
      CREATE OR REPLACE VIEW tw_fingerprint_drift AS
      SELECT rv.quest_id, rv.user_id, 'report_pin'::text AS pin_kind,
             rv.version_seq, rv.id AS report_version_id,
             rv.quest_fingerprint AS pinned_fingerprint,
             fp.graph_fingerprint AS live_fingerprint
      FROM report_versions rv
      JOIN v_quest_graph_fingerprint fp ON fp.quest_id = rv.quest_id
      WHERE rv.quest_fingerprint <> fp.graph_fingerprint
      UNION ALL
      SELECT e.quest_id, e.user_id, 'archive_pin'::text AS pin_kind,
             NULL::integer AS version_seq, NULL::uuid AS report_version_id,
             e.graph_fingerprint AS pinned_fingerprint,
             fp.graph_fingerprint AS live_fingerprint
      FROM quest_lifecycle_events e
      JOIN v_quest_graph_fingerprint fp ON fp.quest_id = e.quest_id
      WHERE e.to_state = 'archived'
        AND e.graph_fingerprint <> fp.graph_fingerprint;
      
      -- ============================================================================
      -- PART C (not landed: fixtures + self-verification are check-tripwires.sh
      -- scratch-db law)
    SQL
  end

  down do
    run <<~'SQL'
      DROP VIEW IF EXISTS tw_fingerprint_drift;
      DROP VIEW IF EXISTS tw_hub_divergence;
      DROP VIEW IF EXISTS tw_context_blowout;
      DROP VIEW IF EXISTS tw_shape_storm;
      DROP VIEW IF EXISTS tw_cache_wall;
      DROP VIEW IF EXISTS tw_missing_spend;
      DROP VIEW IF EXISTS tw_repetition;
      DROP VIEW IF EXISTS tw_empty_storm;
      DROP VIEW IF EXISTS tw_rotation;
      DROP VIEW IF EXISTS tw_churn;
      DROP VIEW IF EXISTS tw_size_ceiling;
      DROP VIEW IF EXISTS tw_slowstall;
      DROP VIEW IF EXISTS tw_wedge;
    SQL
  end
end
