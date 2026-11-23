# I07 — assurance: DESIGN

> Operationalizing honesty: the guarantee map, the verification machinery,
> the conflict adjudication workflow, the tripwire catalog as EXECUTABLE SQL
> predicates, metric definitions with units and provenance, blind-spot
> metrics, and the model qualification ladder. Owned requirements: catalog
> §G, R-066–R-072. NOT app code: SSE/metrics-endpoint wiring is ENTRY 8
> (R-075/R-077); the fast-prometheus gem implementation is the
> implementation arc (BRIEF §6 D1).
>
> Grounds: BRIEF §2 (the honesty ladder), §3 L15; I01 schema (the predicate
> surface), I02 (the hub + fingerprints), I04 failure-modes.tsv (the
> detection contract), I05 (status=gate parity), I06 stop-rules.tsv (the
> threshold law); PoC: reference-explaining-the-stack.md (honesty-bounds
> audit, courtroom frame, the three stories), arc-run-20261122T
> (babysitter v3 tripwires), arc-run-20261121T (refusal-rate measurement),
> fleet-ladder notes (qualification shape).

## 0. The defensible claim, restated as engineering

"Fabrication can't happen for free, or silently. Every claim has a return
address — which span, which fetch, which session, which phase. Lies, if
present, are findable and attributable" (reference-explaining-the-stack §
Honesty bounds). Assurance is the subsystem that makes "findable and
attributable" a mechanical property: every guarantee gets a named layer, a
named piece of evidence, and — where the guarantee is only behavioral or
absent — an honest REDUCED/UNTOUCHED label instead of pretend coverage.
The discipline is the product; this iteration makes the discipline
watchable and auditable.

## 1. The guarantee map (R-066)

### 1.1 The ladder

| Level | What holds | Where it lives |
|---|---|---|
| **ENFORCED** (write-time) | No claim without a verbatim span; no span without a fetched source; citations resolve mechanically | I01 DDL + tool-time constraint catalog; report binding pass (I02) |
| **REDUCED** (behavioral) | Misreadings and cherry-picking — rarer and catchable, never impossible | Verification machinery (§2), conflict discipline (§3), blind-spot metrics (§6), tripwires (§4) |
| **UNTOUCHED** | Whether sources themselves are true; adversarial source poisoning; logical validity of derives_from | No detection surface claims these; named per row below |

### 1.2 Layer × guarantee × evidence × failure-mode exposure

| Layer | Guarantee | Evidence (mechanical) | Quote-mining (claim misreads the span) | Provenance ≠ truth (the source itself is wrong/garbled/poisoned) | Cherry-picking (favorable line cited, contrary line un-logged) |
|---|---|---|---|---|---|
| **Storage/schema** (I01) | ENFORCED: span is byte-exact against a fetched snapshot; citable-only anchoring; offset bounds; URN identity | CHECK/FK constraints (uq_evidence_quest_span, conditional citable FK, ck_evidence_span_len); L1 exact-substring proof at tool time | UNTOUCHED — the schema proves the span exists, never that the reading follows from it | UNTOUCHED — C74 (the mis-saved wrong paper) anchors as legally as a true one; the schema certifies the fetch, not the world | UNTOUCHED — a faithful quote from the favorable half of page 3 passes every constraint |
| **Tool surface** (I05) | ENFORCED: refusal-that-teaches on every malformed write; span-copy discipline; fused atomic forms; status=gate parity | refusal recipes; the canonical-call descriptions; L6 parity table | REDUCED — span-copy discipline makes retyping rarer; the reading field must be written per evidence node, forcing a second look | UNTOUCHED | REDUCED — agenda/citable role law (R-003) removes one systematic cherry-picking surface (the primer); beyond that, tool law cannot see what the model chose NOT to cite |
| **Process/phase gates** (I06) | ENFORCED at boundaries: closure contract (three zeros), decompose completeness, budgets, stop rules, never-reportless exits | v_claim_closure / v_decompose_remaining / v_frontier_mass sweeps wired in transitions.tsv | UNTOUCHED at the gate — closure is structural, not semantic | UNTOUCHED | REDUCED — frontier mass and re-entry keep unresolved mass on the books (a cherry-picked-away question stays visible as open mass) |
| **Cross-quest hub** (I02) | Divergence DETECTED, never prevented: same text, conflicting typed terminals coexist and are flagged | v_canonical_claims.type_divergent → tw_hub_divergence (§4) | REDUCED — a re-derivation of the same line in a second quest that types it differently is a recorded disagreement, exactly the quote-mining-adjacent divergence the audit wants | REDUCED — conflicting sources surface as terminal-type divergence or contradicts edges (the Zhang binding: corroboration AND non-replication on either side of the hole) | REDUCED — the hub makes the same text's treatment across quests comparable |
| **Runtime loop** (I04) | Transport honesty: retry classes, exactly-one telemetry hook, transcript ceilings, seed variation | failure-modes.tsv handling rows; FM-25 hook contract; FM-03 seed law | — | — | — |
| **Assurance** (I07, this) | WATCHABLE: tripwires signal, metrics carry units, blind spots are measurable, models qualify before routing | artifacts/tripwires-i07.sql (12 executable predicates, fire+quiet proven); §5 metric table; §6 blind spots; §7 ladder | REDUCED — verification spot-checks (§2.2) re-read readings against spans; the audit cadence (§2.4) treats this as standing agenda | UNTOUCHED at the machine level — the system records the hole (residual-uncertainty with search trail, the Zhang pattern) but cannot verify the world; honesty about this is the product | REDUCED — blind-spot metrics (§6) measure "what the agent never saw" (unmined sources, uncited claims, aging needs); conflict discipline (§3) records the disagreement |

### 1.3 The three failure modes as the audit agenda (R-066)

The honesty-bounds audit names three failure modes that survive all
write-time enforcement (reference-explaining-the-stack §Three named
failure modes). Each is a standing agenda item, not a solved problem:

1. **Quote-mining** ("proves" vs "suggests") — the claim faithfully cites
   a span it misreads. Detection surface: verification-phase spot checks
   re-reading `evidence.reading` against `span_text` and source context
   (§2.2); the hub's type divergence (the same line typed two ways is a
   smoking gun); conflicts ledgered from contradicts edges. Never
   write-enforceable — REDUCED, catchable.
2. **Provenance ≠ truth** (C74: a paper about Cesarean deliveries
   mis-saved into an investing corpus; JS-shell stubs; crank pages) —
   the span matches the fetch, the fetch is on file, the content is
   garbage. Detection surface: refusal-with-trail (C74 was refused
   through four phases of sessions — "that would fabricate relevance");
   provenance tiers in the audit agenda; residual-uncertainty typing with
   search trail. The truth of sources is UNTOUCHED — the machine's
   version of honesty is recording the hole (Zhang), not pretending to
   fill it.
3. **Cherry-picking** — the favorable line cited, the contradicting line
   un-logged. Detection surface: conflict prompting + the conflicts
   ledger (§3); blind-spot metrics (§6) that count what was never
   anchored; verification citation-coverage sweeps. Behavioral, never
   write-enforced — REDUCED.

## 2. Verification machinery (R-067)

The verification phase is the audit, and its machinery is query-shaped
(I01 canonical-queries.sql is the storage seam's contract):

### 2.1 Path-checking (L2, mechanical)

- **Q1 derivation paths**: every deriving claim's walk reaches a typed
  terminal (definitional-mathematical / primary-empirical /
  residual-uncertainty). Run by the verification phase over the whole
  quest graph, and re-run at report finalization.
- **Q1V dangling-leaf violations**: walk nodes that satisfy nothing
  (no terminal, no further derivations, no open frontier). Must be zero
  at verification; any row is a finding fixed before the phase completes
  — the same contract as the phase gate (I06 three-zeros), swept at a
  deeper radius.
- **Q2 citation-ancestry independence** (L3): evidence pairs on
  ancestor/descendant claims sharing one source are dependent
  corroborations, surfaced (not silently counted).
- Report-side: the binding pass (I02 B1) re-binds every inline ordinal
  mechanically; the self-caught-citation precedent below is what the pass
  makes possible.

### 2.2 Spot-check sampling (DR-02)

The verification phase re-reads a SAMPLE of the graph's evidence against
its sources — the reading-vs-span re-read that is the only mechanical
quote-mining detector. The sampling law (decision record DR-02, flagged
OPERATOR-RULING-NEEDED):

- **Unit**: one evidence node = one check (re-read `span_text` in the
  snapshot context, compare against `reading`, confirm the claim's
  `supports`/`contradicts` polarity follows).
- **Stratification**: the sample is drawn across sources (no source
  contributes more than ⌈n/|S|⌉+1 picks) and across claim mass (at least
  one pick from each open-then-closed need band), because errors cluster
  by source (the C74 story) and by topic area.
- **Seed discipline**: the sample is drawn with a RECORDED SEED (the
  phase result JSON carries the seed + the sampled evidence ids), so the
  audit is reproducible: the same graph + the same seed = the same
  sample. Determinism awareness (L14) applied to auditing itself.
- **Size**: fixed-n per phase (proposed default n = 20, DR-02 options
  carry the alternatives) — small enough to run every verification phase,
  large enough that a systematic misreading class surfaces more than
  once (the PoC verification phases sampled this order of magnitude).

### 2.3 The self-caught-citation precedent

bolt2's verification phase found the C47→C48 mislabeling in the final
report and fixed it BEFORE completion was recorded — 84/84 footnotes
resolved (reference-explaining-the-stack §the three stories). That is the
designed outcome: the verification phase is the clerk re-checking his
exhibits; a finding it raises is a SUCCESS of the machinery, not a
failure of the quest. kquest wiring: the verification phase re-runs the
binding pass against the standing report version, any ordinal that
resolves differently is a finding, and the report is corrected and
re-synthesized before `quest.complete` — the same never-reportless
discipline (I06 P-NOREPORT) applied to wrongness.

### 2.4 The audit cadence (DR-01)

The three failure modes (§1.3) are a standing agenda with a cadence
(decision record DR-01, flagged OPERATOR-RULING-NEEDED): the proposed
default is per-verification-phase (every quest's verification phase
sweeps all three modes: path-checking + Q1V zero rows [mode-agnostic],
stratified spot-checks [quote-mining], conflict-ledger review [cherry-
picking], provenance-tier review of the corpus [provenance ≠ truth]),
plus a per-report random re-audit seed recorded for reproducibility.
Per-quest-end and per-KB-cadence options are in the decision record.

## 3. Conflict adjudication workflow (R-068)

The courtroom frame (reference-explaining-the-stack §the frame that
lands) is the workflow's shape; the mapping is exact:

| Courtroom | kquest | Carrier |
|---|---|---|
| deposed witnesses | fetched corpus (immutable snapshots) | sources + snapshots |
| sworn testimony excerpt | evidence node (verbatim span, one source) | evidence |
| contention being weighed | claim, typed by how it can be settled | claims.terminal_type |
| verdict classes incl. "dismissed for lack of evidence" | terminal types incl. residual-uncertainty | the typed-terminal law |
| precedent chains | derives_from edges | claim_derivations |
| cross-examination with the examiner's theory | conflict + resolution hypothesis | conflicts.resolution_hypothesis |
| the docket | the scored frontier | frontier_entries |
| the verdict, cite-bound | the standing report, mechanically bound | report_versions + report_citations |

**Detection → ledgering → resolution hypotheses → cross-examination:**

1. **Detection** — three surfaces feed the ledger: (a) `contradicts`
   evidence edges written during descent (I01 evidence_edges); (b) the
   hub type-divergence tripwire `tw_hub_divergence` (same canonical text,
   conflicting typed terminals across quests — D3's "divergence =
   tripwire signal, adjudicated in the source quest"); (c) verification
   spot-check findings (§2.2).
2. **Ledgering** — a `conflicts` row per detected disagreement, ≥2
   distinct citable sources per conflict BY CONSTRUCTION (I01
   conflict_sources junction, UNIQUE, citable-only conditional FK —
   DR-17). The ledger row carries the claim, the divergence text, and
   the session that wrote it (return address).
3. **Resolution hypotheses** — `conflicts.resolution_hypothesis` is the
   examiner's theory of WHY the sources disagree (windows, measures,
   samples, populations) — the Zhang record ("different windows,
   different measures") is the exemplar. A hypothesis is a commitment
   the next cross-examination tests, never a verdict by itself.
4. **Cross-examination** — the frontier schedules the test: targeted
   fetches (new witnesses), re-reads of the deposed corpus, or a
   derivation that reconciles the disagreement. Outcomes: the conflict
   resolves into typed claims (primary-empirical with the reconciling
   evidence), or it is ADJOURNED — the unsettleable is typed
   `residual-uncertainty` with the conflict and its hypothesis still on
   the books ("an 'I don't know' that shows its work"). Conflicts are
   never averaged away; dissent is data.

The conflict-ledger shape (DR-03) is settled by prior law: conflicts +
conflict_sources + resolution_hypothesis (I01), the divergence tripwire
over the derived hub (I02 DR-16), adjudication in the source quest. This
iteration adds only the tripwire wiring (§4) and the workflow prose.

## 4. The tripwire catalog (R-069)

**Law**: every tripwire DETECTS and SIGNALS. Signals are alert-class
events on the ENTRY 8 SSE quest-watch stream (slot: `assurance_alert`,
payload = predicate id + key fields); no tripwire ever transitions a
phase (I06 owns the transition law — transitions.tsv) and none ever
auto-kills (FM-18: never auto-kill on growth alone; FM-17: a budget stop
is never silently reportless). **A tripwire that fires on clean data is a
defect** — every predicate ships with a firing fixture AND a clean
counter-case, asserted by the gate (`check-tripwires.sh`).

**Provenance of shape**: the PoC babysitter v3 (arc-run-20261122T
llm-trading-v3) — WEDGE/CHURN/SLOWSTALL/SIZE-CEILING + phase-rotation
liveness + the v3-learned rules (SLOWSTALL replaces counter-based
tripwires as the operator's authoritative stall signal; SIZE-CEILING as
the early-warning band ahead of the measured ~496 KB ceiling).

**The durable-ledger honesty note (DR-07)**: the babysitter read the
LIVE transcript file (byte growth, byte size). The transcript blob lives
in object storage, not PG. The SQL catalog expresses each signal's
DURABLE PROJECTION over the verbatim audit ledger (tool_calls
args/result bytes ARE transcript bytes — L8) plus the spend ledger
(usage_events) and the process ledger (phases). Where the projection is
one-sided (audit bytes are a LOWER BOUND of live transcript bytes:
firing is reliable, quiet is not proof), the byte-accurate live form
rides the ENTRY 8 watcher under the SAME I06 stop-rule keys. Nothing is
pretended to be exact that is not exact.

### 4.1 Catalog table (all twelve are executable views in
artifacts/tripwires-i07.sql, named `tw_<id>`; parity is checker-enforced
both directions)

| id | Detection semantics (SQL shape) | Threshold + provenance | Signal action |
|---|---|---|---|
| `tw_wedge` | Live session whose durable event ledger (tool_calls + usage_events) has been silent longer than the stall window — the FM-04/FM-20 signature: the harness's deadline row never landed (it lost track). `last_tool` is carried in the payload: `'spawn'` means check the run registry by run id — **"no tool result ≠ no process"** (FM-20), never infer child death from the missing result. | Window = SR-18 `engine.slow_stall_window_s` = 1200 s (I06; the per-call 120 s tool watchdog is I04 FM-04's harness half — this catches the case where even that failed). Unattended escalation beyond SR-19 `engine.unattended_pause_s` = 3600 s is I06's `slow_stall_unattended → paused` transition, never this predicate's. | SIGNAL (`assurance_alert`); operator adjudicates; never kill (FM-18) |
| `tw_slowstall` | Live session, ledger IS flowing (≥1 event in window — that is wedge, not this) but window payload < the growth line: trickling, not frozen. The durable projection of SLOWSTALL; the byte-accurate live form (transcript blob growth) is the ENTRY 8 watcher's with the same keys. | SR-17 `engine.slow_stall_bytes` = 100 B over SR-18 = 1200 s (I06; FM-18; the local-model ruling: slow phases are EXPECTED). | SIGNAL only, alert text carries the FM-18 rule: the driver is NOT to be killed on this alone |
| `tw_size_ceiling` | Session whose cumulative verbatim audit payload entered the ceiling band (warn ≥ 450,000 / hard ≥ 496,000; PoC measured deaths at 496,294 B and 496,578 B — FM-02). Audit bytes are a lower bound of live transcript bytes: firing is reliable, quiet is not proof. | SR-15 `engine.transcript_ceiling_warn_bytes` = 450000 fires; band hard at SR-16 `engine.transcript_ceiling_hard_bytes` = 496000. | SIGNAL (band in payload); SR-15/16 runtime handling (refuse new ingestion / bank / operator menu) is I06/I04 law — this predicate never ends a session |
| `tw_churn` | ≥ 10 consecutive failed tool calls in one session — results flowing as refusals (churn, not wedge): the recovery loop is not landing. | 10 consecutive — quest-3 SKILL law 1 (">~10 consecutive searches with no mutation → STOP") calibrated against the quest-2 measured burst shape (max 8-identical burst, 12/session max) — DR-09. | SIGNAL; in-band teaching refusals are the DESIGNED mechanism (I05); the loop keeps running |
| `tw_rotation` | A phase attempt row with attempt_no beyond the phase retry cap while unfinished — the quest cycles attempts (wall kills, empty-completion deaths) without landing (babysitter's phase-rotation liveness check, inverted). | SR-08 phase retry cap = 3 (I06; PoC RETRY_CAP=3, quest-2 wall kills, v3 phase-105) — fires at attempt_no > 3. | SIGNAL; the pause-and-present at cap exhaustion is I06's `retry_cap_exhausted → paused` row; a raised cap (v3's RETRY_CAP=8) is an operator decision the signal makes visible |
| `tw_empty_storm` | ≥ 3 usage rows in one phase attempt with input billed but output_tokens = 0 — the FM-01 signature (rc=0, terminal empty assistant event; the v3 phase-105 five-death cluster). `input_tokens > 0` discriminates the FM-25 zero-usage recording (all-zero rows are legal events). | 3 = SR-08 retry cap (three consecutive empties exhaust a phase attempt by the measured default) — FM-01. | SIGNAL; FM-01 is retryable-with-fresh-seed; the attempt-cap pause is I06's law |
| `tw_repetition` | ≥ 3 consecutive byte-identical tool calls (same tool/op/args) — the durable signature of a retry loop that never mutates state (FM-03: "a failed call that does not mutate state produces an identical retry body"). | 3 — past the transport-retry caps (FM-05/06/08 default 3), so a legal bounded retry (identical body, fresh seed) stays under; the S_SMALL fixture pair proves the quiet side. | SIGNAL ("alert on repetition" — FM-03); prevention is I04's seed-variation law |
| `tw_missing_spend` | An ENDED session that made tool calls but recorded zero llm usage rows — spend would silently under-record (FM-25: "a missing row at rollup time is an ENTRY 7 tripwire"). Scoped to ended sessions: a live mid-first-turn session has no rollup yet and must not false-positive. | none (existence check; the gem's EXACTLY-ONE-terminal-hook contract is I04 law) | SIGNAL — a ledger defect (telemetry sink wiring), not a model defect |
| `tw_cache_wall` | ≥ 3 high-context turns (input ≥ 205,000) in one session with cache_read = 0 — above the effective prefix-cache wall every turn pays the full re-prefill (FM-24, measured: 262k window, 8 GiB prefix cache, effective wall ≈ 205k). | input_tokens ≥ 205000 (FM-24's measured effective wall; per-provider `cache_wall_tokens` config) + cache_read_tokens = 0, count ≥ 3 (the FM family alert default — FM-12/FM-14 use 3). | SIGNAL; the fix is I06 §7 routing (mega-context phases to cache-capable models) — the operator re-routes, never the predicate |
| `tw_shape_storm` | ≥ 3 tool calls refused for stream/shape honesty classes (`unknown_tool` — FM-12; `tool_arguments_failure` — FM-11) in one session: the designed in-band self-correction is not landing. (FM-14's dropped-chunk count is a gem/runtime counter, not a tool_calls error_class — it rides the ENTRY 8 watcher; named here for provenance, not as SQL.) | 3 — `unknown_tool_alert_at` default 3 (FM-12), `dropped_chunk_alert_threshold` default 3 (FM-14). | SIGNAL — "a stuck model, not a bad call" (FM-12's escalation rule); the loop keeps running |
| `tw_context_blowout` | ≥ 3 `non_sliced_read` refusals in one session (FM-22: the full-file read storm) — the I05 frozen teaching refusal ignored three times in a row; the 78% lesson's failure shape (corpus ingestion via full-file reads was 78% of a 79,677-token final context). Detects the TEACHING NOT LANDING; the I05 tool boundary (read_slice hard-capped) and tw_cache_wall are the backstops. | 3 — the FM family's alert default (FM-12/FM-14 = 3); the S_NEAR pair (2 refusals) proves the quiet side. | SIGNAL — a model ignoring the read discipline; the fix is behavioral (phase prompt / overlay), never a kill |
| `tw_hub_divergence` | Hub entries (v_canonical_claims) whose (user, canonical text) carries > 1 distinct NON-NULL terminal_type — same claim, conflicting typed verdicts across quests (D3). Same-text-same-type and typed+untyped coexistence never fire (fixture-proven). | none — divergence is exact identity, not a calibrated threshold (I02 DR-02/DR-16). | SIGNAL (`assurance_alert`) — adjudicated in the SOURCE quest via the §3 workflow: ledger a conflicts row, hypothesize, cross-examine; the hub is derived, holds no state to fix |
| `tw_fingerprint_drift` | Any pinned graph fingerprint ≠ the live quest fingerprint — two pin kinds: report pins (synthesis-time fingerprint; a stale version is never silently fresh — R-024) and archive pins (freeze-time fingerprint; post-archive rework is LEGAL and drifts the pin by design — I02 DR-17 "detected, not prevented"). The M3 queries are this predicate's seed. | none — drift is exact inequality (fingerprint algorithm: v_quest_graph_fingerprint, I02). | SIGNAL (pin_kind in payload); stale hygiene (supersede + re-synthesize) is an operator/phase decision; a drifted archive pin is information about a reworked quest, not a violation |

### 4.2 Fixture + gate contract

artifacts/tripwires-i07.sql seeds, under one dedicated fixture tenant: a
wedge session (frozen ledger, last call a spawn), a slowstall trickle
session, a ceiling-band transcript (~455 KB audit payload), a churn burst
(10 consecutive refusals), a phase on attempt 4/4, an empty-completion
storm (3 billed-input-zero-output rows), a replay loop (3 identical
bodies), a spendless ended session, a cache_read=0 high-context run, an
unknown-tool storm, a divergent claim pair (same text, two terminal
types), a stale report pin + a drifted archive pin — AND the clean
counter-cases: a live healthy session, an ended session with a legal
retry pair, an isolated empty completion, same-type coexistence, a
untyped+typed pair, a fresh pin. The self-verification block asserts
every fire EXACTLY (scoped to the tenant) and every quiet ZERO;
`check-tripwires.sh` re-proves fire/quiet + idempotency, then drops the
scratch db.

## 5. Metric definitions (R-070)

Every metric carries formula, units, provenance, and the normalization
it rides. The fast-prometheus integration is SHAPE ONLY (D1 names the
gem; the app-side `/metrics` endpoint is ENTRY 8 R-075/R-077; the gem
itself lands in the implementation arc): counters/gauges named per row
below, labeled by (quest_id, phase_kind, session_id, model, user_id)
where the row says so, exported from the same durable tables the
formulas query — no second bookkeeping (double-entry stays single-entry
at the metric layer: metrics are VIEWS over the ledgers, never new
mutation surfaces).

| Metric | Formula (SQL shape over I01 tables) | Units | Provenance | Normalization |
|---|---|---|---|---|
| refusal_rate_session | `count(tool_calls WHERE ok = false) / count(tool_calls)` per session | dimensionless ratio | quest-2 failure taxonomy: 789 errored / 6,683 tool results = 11.8%; 664 GRAPH_INVALID = 10.0% | per session; also census by error_class (the taxonomy's classes) |
| refusal_class_census | `count(*) GROUP BY error_class` per session/phase | calls | quest-2 taxonomy §1 (classes a–i, burst widths) | per session + per phase |
| empty_completion_rate | `count(usage_events WHERE kind='llm' AND input_tokens>0 AND output_tokens=0) / count(usage_events WHERE kind='llm')` per phase | dimensionless ratio | v3 phase-105 empty-death cluster (FM-01) | per phase attempt |
| closure_economics_cost_per_class | `sum(usage_events.cost_usd) per phase / count(frontier_entries closed by that phase)` — closing-phase attribution: a frontier entry belongs to the phase whose session window contains its `closed_at` (I01 carries `spawned_by_phase_id` + `closed_at`; the join is `closed_at BETWEEN phase.started_at AND coalesce(phase.ended_at, now())` scoped to the quest's sessions) grouped by `closure_type ∈ (fetch, internal, refusal)` | USD / closure | D10 spend ledger + PoC closure classes | per phase; cross-quest comparable via the class axis |
| cost_per_claim / cost_per_evidence | `sum(cost_usd) / count(claims)` (resp. evidence) per quest | USD / node | PoC economics; D10 | per quest |
| mass_curve | `phases.frontier_mass` (snapshot at boundary) over descent rounds; live value = `v_frontier_mass` (Σ uncertainty×relevance over open entries) | mass points (integer product-sum) | I01 v_frontier_mass; PoC arc: 20 → 96 → … → 1103 (v3), plateau cut at 86 open / mass 1199; v4 drain 86 → 0, mass 1199 → 0 | per quest, per phase boundary |
| metabolism | `count(evidence)/count(quest_sources)`; `count(claims)/count(quest_sources)`; web calls per fetch-closure; web calls per internal-closure | ratios | R-018 measured constants: ~5 evidence / ~2.6 claims per source; FETCH ≈ 6.1 web calls, INTERNAL ≈ 1.2 (BRIEF §5; I06 §measured defaults) | per quest and per phase; deviations from the constants are themselves signals |
| spend | `sum(cost_usd)`, `sum(input_tokens)`, `sum(output_tokens)`, `sum(cache_read_tokens)`, `sum(cache_write_tokens)`, `sum(reasoning_tokens)` by session→phase→quest→user | USD; tokens | D10 + I04 DR-12 provider-token detail columns | the full tenancy chain |
| transcript_audit_bytes | `sum(octet_length(args::text) + octet_length(result::text))` per session (the tw_size_ceiling/tw_slowstall payload) | bytes | L8 verbatim audit; PoC size-ceiling deaths | per session (durable lower bound — DR-07) |
| tripwire_fires | `count(*) per tw_<id>` per window | alerts | this iteration §4 | per predicate; the alert stream's rate axis |

## 6. Blind-spot metrics (R-071, L15)

"What the agent never saw is measurable" (L15). Blind spots are NOT
tripwires (nothing is wrong) — they are coverage accounting, the honest
complement to the guarantee map:

| Blind spot | Formula (over I01 views/tables) | Units |
|---|---|---|
| unmined_citable | `count(v_unmined_sources)` per quest — staged, citable, never anchored | sources |
| fetched_never_cited | sources with zero evidence rows across the owning user's quests | sources |
| uncited_claims | claims with `evidence_count = 0` in v_claim_closure (referencing zero, closure satisfied by terminal or frontier arm only) | claims |
| aging_open_needs | open frontier_entries with `now() - opened_at` beyond a configured age band, grouped by mass decile | entries × days |
| capped_listing_overhang | listing surfaces (frontier, search, corpus lists) are capped (L15 principled caps, I05/I03); the overhang = `count(*) - cap` per surface per request — how much existed beyond what the agent was shown | rows |

Day-one scope (DR-05, flagged OPERATOR-RULING-NEEDED): proposed default =
the four SQL-expressible rows (unmined_citable, fetched_never_cited,
uncited_claims, aging_open_needs) shipped as metric definitions over
existing views; capped_listing_overhang needs the tool layer to emit
per-request cap telemetry (ENTRY 5/8 wiring) and lands with the SSE
dashboard. Options in the decision record.

## 7. Model qualification ladder (R-072)

Shape from the PoC fleet-ladder (stage 1 + stage 2 notes): candidates
earn routing eligibility rung by rung, and the routing config CITES the
evidence (a model appears in `quests.model_config` for a phase kind only
with a rung pass on record — I06 §7's seeder/closer profiles consume
exactly this). Durable carrier (judge F8): the rung-pass record needs a
home the rule can mechanically read — a `ladder_passes` table (model,
rung, stack, date, evidence ref) is the natural shape, DEFERRED to
ENTRY 8's schema map with the enforcement rule (model_config rows cite a
ladder_passes id) noted for that entry; day one the rule is reviewable
(human-checked at config time), not machine-checked — recorded, not
hidden.

| Rung | What runs | Gate (DR-06 carries options + recommendation) | Evidence recorded |
|---|---|---|---|
| 1. **probe** | Sandbox print session on a fixed probe topic (the Antikythera method): one web search → fetch-with-save → index write → paragraph with a resolving `[C1]`; hard wall 900 s, spend capped | PASS = usable first tool call + artifacts written (index path points at the saved file, citation resolves); FAIL = empty-args flail / tool-channel break / nothing | per-candidate dir: transcript, artifacts, wall, spend |
| 2. **smoke** | One map/decompose phase on a fresh topic through the real driver, WEB_BUDGET small, equal-wall cap | Measured breadth + anchoring: every staged source mined ≥1 evidence (stage-2's 12/12 vs 3/12 discriminator), GRAPH_INVALID loop absence, ctx peak under window | turns, tok_in/out, ctx_peak, graph/file/web counts, map at cap |
| 3. **partial quest** | decompose + a descent slice (web budget 0 or small, phase cap low) on a fixture topic | Three zeros at every boundary; refusal_rate_session under a set ceiling; no tripwire storm (churn/shape/repetition quiet); metabolism within band of R-018 constants | per-phase gate results, refusal census, tripwire ledger |
| 4. **full quest** | Complete arc decompose → frontier-build → descent → synthesis → verification with report + binding pass | Never-reportless finish; path-checking + Q1V zero; spot-check pass; citation coverage (v4: 79 footnotes urn-bound); cost/economics recorded | the quest itself + its ledgers |

**The routing-config-cites-evidence rule**: `quests.model_config` is the
only place a model meets a phase kind at runtime (I06 §7; model identity
never in prompts — I04 E-NOECHO). The ladder's gate criteria (DR-06,
flagged OPERATOR-RULING-NEEDED for the exact thresholds) are the
admission law for that map: probe-only models never route; smoke-pass
models route to decompose-class phases at most; full-quest models carry
synthesis/verification. The stage-2 selection table (APC + map quality +
ops) is the evidence template; the ladder re-runs on model updates — a
model's rung is a property of (model, serving stack, date), never a
permanent title (the longcat channel break and the tf-qwen ceiling are
both serving-stack-dependent verdicts).

## 8. Traceability R-066–R-072

| R | Status | Carrier |
|---|---|---|
| R-066 | DESIGNED | §1 the guarantee map (layer × guarantee × evidence × failure-mode exposure; §1.3 the three failure modes as the audit agenda); DR-01 (cadence) |
| R-067 | DESIGNED | §2 verification machinery (path-checking §2.1, spot-check sampling §2.2 with seed/size discipline, self-caught-citation precedent §2.3, cadence §2.4); DR-01/DR-02 |
| R-068 | DESIGNED | §3 conflict adjudication workflow (detection → ledgering → resolution hypotheses → cross-examination; the courtroom frame); DR-03 |
| R-069 | DESIGNED | §4 the tripwire catalog + artifacts/tripwires-i07.sql (12 executable `tw_*` predicates, fixtures + clean counter-cases, self-verify) + artifacts/check-tripwires.sh; DR-04/DR-07/DR-09 |
| R-070 | DESIGNED | §5 metric definitions table (formula/units/provenance/normalization; fast-prometheus integration SHAPE only — implementation → implementation arc, endpoint → ENTRY 8); DR-08 |
| R-071 | DESIGNED | §6 blind-spot metrics (L15); DR-05 (day-one scope; capped-listing overhang wiring → ENTRY 5/8 named) |
| R-072 | DESIGNED | §7 model qualification ladder + the routing-config-cites-evidence rule; DR-06 |
