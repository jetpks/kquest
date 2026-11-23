# I07 — assurance: DECISIONS

Numbered decision records. Status is DECIDED (carried by prior law,
measured PoC default, or no-executable-alive necessity) or
OPERATOR-RULING-NEEDED (a genuine judgment call — options + recommendation
on record; nothing silently decided). Prior-law changes appear ONLY here as
proposals (none in this iteration: every threshold matches I06
stop-rules.tsv byte-for-byte — DR-04).

## DR-01 — The three-failure-modes audit cadence

**Status:** OPERATOR-RULING-NEEDED
**Decision (proposed):** the three failure modes (quote-mining,
provenance ≠ truth, cherry-picking — §1.3 of DESIGN) run as a standing
agenda at EVERY verification phase: path-checking + Q1V zero rows
(mode-agnostic structure), stratified spot-checks (quote-mining),
conflict-ledger review with resolution-hypothesis status (cherry-picking),
provenance-tier review of the corpus (provenance ≠ truth). The phase
result records the audit seed so the sweep is reproducible.
**Options:**
- A — per-verification-phase cadence (proposed): every quest audits before
  completion; cost is bounded by the spot-check size (DR-02); matches the
  bolt2 precedent (the self-catch happened IN the verification phase).
- B — per-quest-end only, with verification phases running just
  path-checking: cheaper, but the self-caught-citation class (report
  mislabels) is exactly what a lighter verification phase would miss.
- C — per-KB cadence (a standing audit job sweeping archived quests):
  catches cross-quest drift late; complements A rather than replacing it.
**Recommendation:** A, with C as an additive later mode (it needs the
materialized-hub/embeddings era to be affordable).
**Rationale:** the audit agenda only disciplines what it sweeps often
enough to catch; the PoC's verification phases were where both the
mislabel was caught and the residual holes were typed.
**Alternatives considered:** no cadence at all (the three modes named in
prose only) — rejected: that is pretend coverage, the exact thing R-066
exists to prevent.

## DR-02 — Spot-check sampling law (seed/size/stratification)

**Status:** OPERATOR-RULING-NEEDED
**Decision (proposed):** unit = one evidence node (re-read span_text in
snapshot context vs the reading; confirm polarity follows); size = fixed
n = 20 per verification phase; stratified across sources (no source
contributes more than ⌈n/|S|⌉+1 picks) and across need bands; the seed +
sampled ids are recorded in the phase result JSON — the audit is
reproducible (L14 determinism applied to auditing).
**Options:**
- A — fixed n = 20, seeded, stratified (proposed): reproducible, bounded,
  runnable every verification phase.
- B — proportional n = 10% of evidence: scales, but small quests audit
  almost nothing (5 evidence = 0-1 picks) and big quests pay heavy
  LLM-cost swings; the seed makes either reproducible.
- C — stratified-by-risk: weight picks by conflict load + provenance tier
  + terminal type (risk-of-bias tool logic, Cochrane mapping): the most
  honest allocation but needs calibrated weights we have no measurements
  for yet — invention risk.
**Recommendation:** A day one; revisit toward C once refusal/evidence
metrics accumulate (the metrics of §5 feed real weights).
**Rationale:** errors cluster by source (C74) and by topic; a fixed
seeded n bounds cost, and 20 spot re-reads is the PoC verification-phase
order of magnitude that caught the C47→C48 mislabel.
**Alternatives considered:** full re-read of every evidence node —
rejected: O(evidence) LLM cost per quest, pricing the audit above the
build; spot-checking is the audited REDUCED level's honest price.

## DR-03 — Conflict-ledger shape

**Status:** DECIDED
**Decision:** the ledger is prior law, unchanged: `conflicts` +
`conflict_sources` (≥2 distinct citable sources per conflict BY
CONSTRUCTION, junction-UNIQUE, citable-only conditional FK) +
`conflicts.resolution_hypothesis` (the examiner's theory — windows,
measures) + the derived-hub divergence signal (`tw_hub_divergence` over
`v_canonical_claims.type_divergent`). Adjudication happens in the SOURCE
quest (D3 ruling); the hub holds no state to fix.
**Rationale:** I01 DR-17 built the junction; I02 DR-16 ruled the hub
derived; this iteration only wires the detection (the tripwire) and
writes the workflow prose (DESIGN §3). Re-opening the shape here would
amend ratified law with no new evidence.
**Alternatives considered:** (a) a new conflict_states machine table —
rejected: adjudication outcomes already land as typed
claims/residual-uncertainty + the hypothesis column; a state machine
duplicates the closure contract; (b) auto-generating conflicts rows from
`tw_hub_divergence` — rejected: detection and ledgering stay separate
steps so a signal can be dismissed by adjudication without touching the
ledger.

## DR-04 — Stall-signal thresholds: match I06, amend nothing

**Status:** DECIDED
**Decision:** the catalog's shared values match I06 stop-rules.tsv
exactly, with no amendment: SR-17 `engine.slow_stall_bytes` = 100;
SR-18 `engine.slow_stall_window_s` = 1200; SR-19
`engine.unattended_pause_s` = 3600; SR-15
`engine.transcript_ceiling_warn_bytes` = 450000; SR-16
`engine.transcript_ceiling_hard_bytes` = 496000; SR-08 phase retry cap =
3 (consumed by `tw_rotation` and `tw_empty_storm`). check-coverage.sh
verifies the parity mechanically.
**Rationale:** I06 froze these as the operator's measured defaults
(llm-trading-v3 §SLOWSTALL rule added; §Post-resume ground truth;
FM-18/FM-02). Two sources of truth for one threshold is the drift the
catalog exists to prevent.
**Alternatives considered:** I07-local overrides (e.g. a wider wedge
window for SQL) — rejected: the babysitter-v3 lesson (widen the gate for
local-model pace) is a per-quest config concern living in I06's config
keys, not a second hardcoded number.

## DR-05 — Blind-spot scope day one

**Status:** OPERATOR-RULING-NEEDED
**Decision (proposed):** day one ships the four SQL-expressible blind-spot
metrics as definitions over existing I01 views — unmined_citable
(v_unmined_sources), fetched_never_cited, uncited_claims
(v_claim_closure.evidence_count = 0), aging_open_needs (age-banded open
frontier). capped_listing_overhang (rows beyond the L15 listing caps)
lands with the tool-layer per-request cap telemetry — named destination:
ENTRY 5 (tool surface) + ENTRY 8 (SSE dashboard).
**Options:**
- A — the four SQL metrics day one, overhang deferred to cap telemetry
  (proposed): everything shipped is executable against the I01 schema
  today; the deferred one names its wiring.
- B — all five, with overhang approximated by estimating caps in SQL —
  rejected in advance: caps are tool-layer config (I05 listing caps,
  I03 result caps); a SQL guess would be a fabricated number.
- C — day-one = unmined_citable only (the decompose gate already sweeps
  it): minimal, but leaves "never cited" and "aging needs" unmeasured
  when they are one view away.
**Recommendation:** A.
**Rationale:** blind spots are coverage accounting, not tripwires —
nothing fires; the value is the dashboard number being real. Only
measurable-now things ship as measured; the rest defer with named
destinations.
**Alternatives considered:** blind spots as tripwires (fire when
unmined_citable > 0) — rejected: an unmined source mid-decompose is
normal life, not an alert; firing on it would violate the
false-positive law.

## DR-06 — Ladder gate criteria (probe → smoke → partial → full)

**Status:** OPERATOR-RULING-NEEDED
**Decision (proposed):** gates per rung (DESIGN §7): probe = usable first
tool call + artifacts written + citation resolves (the frozen stage-1
method, 900 s wall, spend capped); smoke = every staged source mined ≥1
evidence + no GRAPH_INVALID loop + ctx peak under window (stage-2's
12/12-vs-3/12 discriminator); partial quest = three zeros at every
boundary + refusal_rate_session under ceiling + no tripwire storm +
metabolism within band of the R-018 constants; full quest =
never-reportless finish + path-checking/Q1V zero + spot-check pass +
binding-pass citation coverage. Routing rule: model_config cites rung
evidence — probe-only never routes; smoke-pass routes to decompose-class
at most; full-quest carries synthesis/verification.
**Options:**
- A — the four-rung ladder above with measured gates (proposed).
- B — continuous scoring (one blended score per model): rejected — a
  blend hides which gate failed; the longcat case (983K window, 0.9 s
  warm prefills, UNFIT as a driver today) shows single-factor assets
  never excuse gate failures.
- C — adding a formal APC/cache rung between smoke and partial (the
  stage-2 APC feasibility probe): attractive but it measures the SERVING
  stack, not the model — folded into smoke's evidence columns instead.
**Recommendation:** A, with the ceiling values for refusal-rate and
metabolism band left as config keys the operator tunes per domain (they
are UNMEASURED as gates; the rung structure is the decision, the
thresholds are calibration).
**Rationale:** the ladder is admission control for the routing map —
the one place a bad model can silently corrupt every quest it touches
(v3's empty-completion tax and the 496 KB ceiling were both
model+stack-specific and were caught by exactly these rungs' methods).
**Alternatives considered:** no ladder (route by provider marketing) —
rejected: R-072 is owned law.

## DR-07 — Byte-level tripwires as durable-ledger projections

**Status:** DECIDED
**Decision:** the SQL catalog expresses the babysitter v3's byte-level
signals as projections over the durable audit ledger: payload = octet
length of tool_calls args+result (L8: verbatim transcript bytes), windows
from the SR keys. `tw_size_ceiling`'s audit bytes are a LOWER BOUND of
the live transcript (firing is reliable, quiet is not proof); the
byte-accurate live forms (blob size, growth) ride the ENTRY 8 watcher
under the SAME SR-15/16/17/18 keys. DESIGN §4 states this per predicate.
**Rationale:** the transcript blob lives in object storage (D8); I01 law
carries no byte column and none may be added silently. A one-sided
detector honestly labeled beats an exact detector pretended. There is no
executable alternative over the frozen predicate surface.
**Alternatives considered:** (a) adding a live transcript-size column to
sessions (prior-law amendment proposal) — rejected: it would need
write-path plumbing (ENTRY 8) to stay honest, and the watcher already
reads the blob directly; (b) summing usage tokens as a byte proxy —
rejected: tokens are not bytes and the ceiling deaths were BYTES.

## DR-08 — Spend attribution stays reporting-only (FM-17's enforcement
half; the I03 DR-06 revisit trigger)

**Status:** OPERATOR-RULING-NEEDED (judge F2: a frozen-grounds mandate —
I06 §14 explicitly deferred the consequence-enforcement half HERE —
cannot be closed as DECIDED-by-prior-ruling; the operator owns it)
**Options:**
- **(A) Ratify reporting-only + re-point the enforcement half explicitly**
  — day one ships signals, not consequences; the enforcement half is
  re-pointed to the implementation arc (or a future design entry) with
  the reopen-condition recorded (consequence machinery reopens I03
  DR-06 attribution by decision record). RECOMMENDED — matches the I06
  DR-09 0=off ruling and the operator's recorded reasoning.
- (B) Design the consequence layer now (quotas/throttles/lockouts) —
  reopens I03 DR-06 attribution by the revisit trigger, formally.
- (C) Design the SIGNAL threshold at which consequences WOULD attach
  (hard-line crossing counts), machinery still off — a middle shape
  the implementation arc could enable by config.
**Recommendation:** (A) — matches the I06 DR-09 0=off ruling and the
operator's recorded I03 DR-06 reasoning; the enforcement half gets an
explicit destination instead of silence.
**Decision:** day one, spend attribution is REPORTING-ONLY: the §5 spend
metrics + budget signals exist; NO consequence machinery (quotas,
throttles, lockouts) ships with this iteration. The I03 DR-06 revisit
trigger stands unreopened: "the only reason we're going with A right now
is that the cost tracking isn't tied to consequences — it's purely
reporting … If we were using this to enforce budgets/quotas, we'd have to
revisit the design here" (operator ruling 2026-11-22). Consequence
enforcement would REOPEN I03 DR-06's per-quest embed-job attribution — a
prior-law amendment that must be proposed as a decision record, never
slipped in.
**Rationale:** I06 ruled token/spend caps 0 = off (advisory defaults,
DR-09 there); FM-17's never-reportless handling is I06's transition law;
this iteration's contribution is the SIGNAL surface (tw_missing_spend,
the spend metric family) that would make any future consequence rule
enforceable honestly.
**Alternatives considered:** shipping a throttle class now (alert at
N× budget) — rejected: budgets are 0=off by ratified ruling; a throttle
would be consequences by the back door, exactly what the revisit
trigger forbids without a ruling.

## DR-09 — Tripwire threshold inventory (non-SR values)

**Status:** DECIDED
**Decision:** the non-SR thresholds, each with its provenance (none
invented): churn = 10 consecutive failures (quest-3 SKILL law 1 ">~10
consecutive searches with no mutation → STOP", calibrated against the
quest-2 measured burst shape — max 8-identical burst, 12/session);
repetition = 3 (past the transport-retry caps FM-05/06/08 = 3, so legal
fresh-seed retries stay quiet); shape storm = 3 (`unknown_tool_alert_at`
default 3, FM-12; `dropped_chunk_alert_threshold` default 3, FM-14);
cache wall input = 205000 (FM-24's measured effective wall — per-provider
`cache_wall_tokens` config, PoC-measured for the local engine); size
band discrimination proven by fixture (warn ≥ 450000 AND < 496000).
**Rationale:** every number cites a measured PoC value or an I04 FM-row
default; where a value is per-provider config (cache wall), the SQL
constant is the PoC-measured instance and the config key is named.
**Alternatives considered:** making all non-SR thresholds config keys
day one — rejected: no consumer varies them yet (YAGNI); the SQL
constants carry their provenance inline and a config overlay can wrap
them at implementation time without redesign.

**Proxy honesty notes (judge F4/F9/F10, added at the fix pass):**
- tw_repetition is a DURABLE PROJECTION of FM-03's signature: the FM's
  byte-identical LLM REQUEST bodies are not a durable surface (I01 keeps
  no request bodies); identical TOOL-CALL bodies are the durable lower
  bound — repetition detected there is real, repetition missed there
  may exist. The threshold (3) is past the COMPLETIONS-layer transport
  retries (FM-05/06/08); a model persistently re-issuing one timing-out
  tool with identical args can legally reach 3 without transport
  retries — the storm count, not the transport cap, is what makes it a
  signal.
- uncited_claims (§6 blind spots) is the closure gate's bare-claims zero
  presented at the metrics layer — NOT a new "never saw" surface; the
  genuine L15 blind spots day one are unmined_citable,
  fetched_never_cited, and aging_open_needs. Disclosed, not hidden.
- tw_missing_spend is scoped to ENDED sessions (the header's
  false-positive reason: a live session mid-first-turn has tool calls
  with no usage rows yet). A live-session variant with a ≥N-calls guard
  would close the window; day-one scope is defensible and recorded
  here.

## DR-10 — Signal action law: SIGNAL only, SSE slot named

**Status:** DECIDED
**Decision:** every `tw_*` predicate's action is SIGNAL, full stop:
alert-class events on the ENTRY 8 SSE quest-watch stream, slot
`assurance_alert` (payload = predicate id + key fields), per the
tripwires-never-transition and never-auto-kill laws (I06 owns the
transition law; FM-18's alert-only rule; FM-17's never-reportless
handling). No predicate writes to quests/phases state; no predicate
kills anything; the SQL is SELECT-only (views — structurally incapable
of transitioning, which is the strongest form of the law).
**Rationale:** the two laws most likely to be silently violated are
false-positives and auto-kill; making the catalog views (not procedures)
removes the second by construction, and the fixtures + quiet asserts
enforce the first at gate time.
**Alternatives considered:** a signal table with ack/state columns —
rejected day one: alert-state management is app wiring (ENTRY 8 alerting
surfaces, R-076); a durable alert ledger can be added then without
touching the predicates.
