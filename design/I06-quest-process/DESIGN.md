# I06 — quest-process: the phased quest state machine as machine-readable law

## 1. Scope and method

The quest PROCESS is the product's operating system: the phase state machine
that turns frontier mass into reports without reportless stops, the stop
rules that make exit an economics decision (BRIEF §3 L4), and the phase
contracts that pin each phase's deliverables to gates the schema can sweep.
This iteration productizes the PoC's hardest-won mechanics as
**machine-readable law**: a transition table and a stop-rule catalog that a
checker validates (gates must bite) and the implementation arc consumes as
config source.

Owned requirements: catalog §F, **R-056–R-065**. Prior law consumed
read-only: I01 (the five law views `v_claim_closure`,
`v_unmined_sources`/`v_decompose_remaining`, `v_frontier_open`,
`v_frontier_mass`; the `phases` table with `kind`/`round_no`/`attempt_no`/
`frontier_open`/`frontier_mass` snapshots; `quests.process_config` as the
config carrier, DR-20), I02 (quest lifecycle table, verification gate,
fingerprints, report versioning + re-synthesis, citation binding), I03
(embed jobs, spend rows, mechanical relevance DR-14), I04 (session
lifecycle: pause-reconfigure-resume DR-04, one-writer DR-05, transcript
ceiling as runtime operator decision DR-06, budget lines all-advisory
DR-09, failure modes FM-01/FM-02/FM-17/FM-18), I05 (status=gate parity —
gates sweep ONLY the parity fields; frozen refusal texts as the teaching
surface; the three-zeros CONFIRMED composition).

PoC evidence base (all under
`/Users/eric/architect/spaces/20261110-knowledge-builder/`, cited per
claim): the WORKING driver `repos/hermit-kb/quest/quest-driver` (read as
the reference implementation of the transition law);
`notes/reference-claim-graph-mechanics.md` (the transition table, counters,
economics, quirks); `notes/muse-20261122T-frontier-building-phase.md`
(frontier-build birth: mass floor, rounds cap, re-entry law);
`notes/muse-20261120T-i20-definition-of-done.md` (mass currency, 3-layer
uncertainty, stop-as-economics); `notes/arc-run-20261122T-quest2-arc-summary.md`
§2 (the mass backtest); `notes/arc-run-20261122T-llm-trading-v3-launch.md`
(the v4 drained-exit endgame, ENDGAME DRAIN law, the model-swap and
ceiling episodes); `notes/north-star-20261114-claim-graph.md` (briefing as
the entry point).

**The machine-readable twin is law.** `artifacts/transitions.tsv` (27 rows
— 25 as authored + 2 briefing-init stop rows added at judge F1)
and `artifacts/stop-rules.tsv` (19 rows) are the transition table and the
stop-rule catalog; this document is their prose twin.
`artifacts/check-transitions.sh` and `artifacts/check-coverage.sh` validate
them (the iteration's executable gates). Where prose and table disagree,
the table wins and the prose is a defect.

## 2. The phase set and the transition law (R-056)

### 2.1 The phase set

Five phase kinds, frozen in I01 `ck_phases_kind` (the model and the process
share one vocabulary): **decompose, frontier-build, descent, synthesis,
verification**. Plus:

- **briefing-init** — not a phase kind: the interactive entry state (§8).
  Initiation work runs as **decompose round 1 in an interactive session**
  (I01 DR-13: sessions always belong to a phase attempt — the briefing
  session is phase-attributed, audited, and cold-bootable like every other
  session; L13 parity: same tools, same constraints, same audit).
- **quest-done** — the terminal (verification passed ⇒ quest lifecycle
  `complete` per I02 `ck_quest_lifecycle_transition`: "verification passed
  (never-reportless finisher honored, ENTRY 6)" — that wiring is this
  iteration's row `verification → quest-done`).
- **paused / stopped** — quest-lifecycle targets (I02), reached by the
  loud-stop rows (§5). They are terminal-by-law in the PHASE table; their
  continuation law is the I02 lifecycle (paused→active resume;
  stopped→active the phase-cap restart precedent), delivered through I04's
  pause-reconfigure-resume mechanics. Pause is ORTHOGONAL to phase
  succession: the table keys on phase COMPLETION events; a pause banks or
  cancels the in-flight attempt and resume relaunches the same phase kind.

### 2.2 The transition law

`artifacts/transitions.tsv` is the law. Reading rules:

1. **Row order is priority.** For a completed phase, applicable rows are
   collected in FILE ORDER (explicit rows plus wildcard expansions) and the
   FIRST match fires. This is how the PoC's "plateau checked FIRST"
   discipline generalizes: stop rows (§5) precede succession rows;
   mass-decay precedes plateau-cut precedes drained inside descent.
2. **Wildcards**: `any-phase` expands to {briefing-init, decompose,
   frontier-build, descent, synthesis, verification}; `any-work-phase` to
   {decompose, frontier-build, descent}; `any-finisher-phase` to
   {synthesis, verification}. **Briefing-init stop coverage (judge F1
   fix, ratified shape)**: budget crossings and the phase cap at the
   briefing boundary are explicit rows — pause-and-present, because the
   briefing is interactive and the operator is present BY DEFINITION;
   disposition (reconfigure budgets/caps or abort) is theirs. P-NOREPORT
   now covers every (state, event) pair.
3. **Every guard identifier resolves** (checker-enforced) to an I01 law
   view (`v_*`), a config key in `stop-rules.tsv`, a named gate/metric in
   the §3 vocabulary, or a prior-law status field. `none` is a legal guard
   (event-carried stops).
4. **Every evidence cell resolves** (checker-enforced): an absolute PoC
   path (file exists; §-anchor text present in the file) or
   `design-law (<prior-law object>)` (the object greps in I01–I05).

The succession core (the PoC driver's claim-graph `next_phase`, carried
forward and amended):

```
briefing-init ──agenda_staged──▶ decompose
decompose:     v_decompose_remaining > 0            → decompose   (repeat)
               + fb_eligible                         → frontier-build
               + v_frontier_open > 0                 → descent
               else                                  → synthesis
frontier-build: same tail as decompose (undecomposed first, then
               build rounds while eligible, then descent, else synthesis)
descent:       mass-decay cut (PRIMARY)              → synthesis
               plateau cut (backstop)                → synthesis
               v_frontier_open = 0 ∧ remaining > 0   → decompose   (re-entry)
               v_frontier_open = 0                   → synthesis   (drained)
               fb_eligible                           → frontier-build
               v_frontier_open > 0                    → descent     (repeat)
synthesis      ──citation_coverage──▶ verification
verification   ──verification_clean──▶ quest-done
               verification failed                    → paused (rework)
```

The three re-entry laws (R-056: "mass floor, re-entry rounds, decompose
re-entry"):

- **Mass floor** (`fb_eligible`): `v_frontier_mass <
  quest.frontier_floor_mass AND frontier_build_rounds_used <
  quest.frontier_build_max` — the one-way law killed
  (muse-20261122T-frontier-building-phase: "the driver's transition law is
  one-way … and with a small seed corpus decompose exhausts
  decompose_remaining in one phase. There is NO phase whose job is frontier
  construction"). The gate opens from BOTH decompose and descent tails.
- **Re-entry rounds**: `quest.frontier_build_max` caps frontier-build
  rounds per quest — "the re-entry valve, never an infinite loop"
  (driver). Entering emits a loud `FRONTIER_BUILD` event (round n/MAX,
  mass < floor) — the same stderr channel law as `PLATEAU_CUTOFF`.
- **Decompose re-entry**: a drained frontier with un-decomposed sources
  goes back to decompose — "fetched-but-undecomposed sources get extracted
  instead of stranding at synthesis" (driver). The decompose tree is REBUILT
  on continuation quests (quest-2: remaining=90 after init despite the
  source quest ending at 8 — §6 of the mechanics reference).

Reachability and dead ends are checker-proven (AC2): every phase kind is
reachable from briefing-init; every phase has an outbound row; quest-done,
paused, stopped are terminal-by-law.

## 3. Gate vocabulary (guards resolve here)

Every bare identifier named in a `transitions.tsv` guard is defined in this
block (checker-enforced resolution); dotted identifiers are config keys in
`stop-rules.tsv`; `v_*` identifiers are I01 law views. The three zero
counts are the I05 parity status fields (status=gate, 1:1 both directions
— the gate sweeps exactly these).

```gates
gate: agenda_staged | at least one agenda source staged on the quest (quest_sources join sources role=agenda; I01 §3.4, R-002/R-003, R-062)
metric: bare_claims | count of v_claim_closure rows with bare set (I01 §3.17 v_claim_closure; I05 §5 parity field status.bare_claims)
metric: unreferenced | count of v_claim_closure rows with evidence_count = 0 (I01 §3.17; I05 parity field status.unreferenced)
metric: dual_arm_claims | count of v_claim_closure rows with has_terminal AND derives_from_count > 0 (I01 §3.17; I05 parity field status.dual_arm_claims)
gate: fb_eligible | v_frontier_mass < quest.frontier_floor_mass AND frontier_build_rounds_used < quest.frontier_build_max (PoC driver fb_eligible)
metric: frontier_build_rounds_used | count of phases rows of kind frontier-build (I01 §3.13 round_no)
gate: mass_decay_sustained | frontier_mass <= descent.mass_decay_cut_fraction x running_peak_mass at each of the last descent.mass_decay_window completed descent boundaries
metric: running_peak_mass | max of the phases.frontier_mass snapshots over completed descent rounds (I01 §3.13; I20 shadow instrumentation made structural)
gate: plateau_flat | plateau_range <= descent.plateau_range_max over descent.plateau_window completed descent phases each recording a frontier_open snapshot (PoC I16)
metric: plateau_range | max minus min of phases.frontier_open over the plateau window (I01 §3.13 snapshots)
gate: citation_coverage | every material claim in the draft is cited and every report citation resolves to own-quest evidence or an explicitly marked import (I02 §3.4 report_citations, §9 binding pass; R-026/R-027)
gate: verification_clean | verification path-checking + spot checks found zero uncorrected violations (R-063; v4 astra precedent: corrections made IN phase)
metric: web_calls_used | rollup over web tool_calls for the quest at the phase boundary (I01 §3.15; I04 FM-17 rollup point)
metric: tokens_used | rollup over usage_events tokens for the quest (I01 §3.16; D10)
metric: spend_used_usd | rollup over usage_events cost for the quest (I01 §3.16; D10)
metric: phases_launched | count of phases rows, ALL kinds — decompose counts toward the cap (the PoC lesson, §6.2 DR-03)
metric: phase_attempts | attempt count of the in-flight phase = max(ledgered sessions, launches) — file-less attempts count (I01 §3.13 attempt_no; PoC retry-loop law)
metric: transcript_bytes | live session transcript size in bytes (I04 §7 context accounting; FM-02)
metric: transcript_growth | byte growth of the newest session transcript over engine.slow_stall_window_s (I04 FM-18)
metric: operator_absent | seconds since the last operator interaction with the quest (I04 §5.4; FM-18 unattended window)
```

**Three-zeros wiring (the ratified CONFIRMED composition, gate wiring is
this iteration's).** The closure verdict — `bare_claims = 0 unreferenced = 0
dual_arm_claims = 0`, all three over `v_claim_closure` (I05 §5; operator
CONFIRMED 2026-11-22; the PoC's `violations` zero has no kquest equivalent
— `bare` subsumes it) — is swept at **every phase completion boundary**:
the PoC ran its graph-check at every claim-graph boundary and a violation
anywhere stopped the quest (the asymmetric-validator kill,
2026-11-17-descent-observation §incident C, is why I05 made status=gate
1:1). Per-phase ADDITIONS:

| phase | additional gate at its boundary |
|---|---|
| decompose | `v_decompose_remaining = 0` to EXIT to any non-decompose phase (the phase's own zero; agenda sources excluded by schema, R-003) |
| frontier-build | `v_frontier_mass` vs `quest.frontier_floor_mass` (the floor it exists to meet) |
| descent | the exit disciplines (§4) — stop rules over the mass/count snapshots |
| synthesis | `citation_coverage` (its deliverable gate) |
| verification | `verification_clean` (its deliverable gate) |

The gates sweep ONLY the I05 parity fields — no rule the agent cannot see
(I05 §5 law, consumed exactly).

## 4. Both exit disciplines + mass-decay primary (R-057)

Descent is where exit is an economics decision (L4: stop-as-economics; I20:
"the machine stops when it can no longer buy knowledge at the price of
running"). Three exits, checked in priority order:

### 4.1 Mass-decay — the validated PRIMARY

**The backtest** (arc-run-20261122T-quest2-arc-summary §2, validated to the
boundary: 150/150 boundary counts match driver.log): frontier mass
(Σ uncertainty×relevance over open entries) fell **−75.5%** (941 peak →
230) while count fell only **−61%** and was **rising** at the end
(re-seeding outpaced closure). **I16's count law fired 0/115 simulated
checkpoints** (closest-ever range 3, needs ≤2; window range 30 on the last
day). And every organic exit was reportless. Count is the wrong currency;
mass is the validated one (I20's thesis, validated live).

**The rule**: descent ends when `mass_decay_sustained` fires —
`frontier_mass ≤ descent.mass_decay_cut_fraction × running_peak_mass` at
each of the last `descent.mass_decay_window` completed descent boundaries.
Defaults: cut fraction **0.25** (the backtest's arc-end sat at 24.5% of
peak — 230/941 — the closest measured analogue of the right cut), window
**10** (the measured plateau window shape). **Honesty flag**: the
threshold was never live-fired — the backtest validated the CURRENCY, not
the firing point; the I20 graduation decision was open ("replace or gate
I16 with mass-decay") when the PoC closed. Calibration is
OPERATOR-RULING-NEEDED (DR-07), with a mandatory review after the first
live firing. Firing is LOUD by law: a stderr event line + a ledger marker
(the `plateau_cut` channel discipline — the report's provenance of an
arc CUT, never a silent stop; I20's Goodfaith caveat: "the metric stops the
quest only through a loud, recorded, judge-reviewable line — never
silently").

### 4.2 Plateau-cut — retained as BACKSTOP, level-blind (limitation recorded)

The PoC's I16 law: frontier_open flat (max−min ≤ 2) over the last
W = max(10, ⌊n/2⌋) completed descent phases → synthesis. It fired
legitimately once live (v3, phase 112: "PLATEAU_CUTOFF: frontier flat
(range ≤2) over last 10 phases"; 115-phase quest, 79/1400 web calls).

**The limitation, recorded honestly**: the law is **level-blind** — it
conflates cheap and valuable closes ("3 u2-r3 stub recoveries ≡ 1 u4-r4
feud adjudication, as far as the law can see" — I20 §problem) and it cut
v3's synthesis at **86 open / mass 1199** (the operator's words: "the
plateau law is level-blind (it cut v3's synthesis at 86 open / mass 1199)").
An equilibrium (closure rate ≈ reseed rate) can persist forever at high
mass — which is exactly the shape mass-decay cannot see. So the two rules
are COMPLEMENTARY, not redundant: mass-decay catches decaying-but-reseeding
frontiers (quest 2: mass down, count up); plateau-cut catches
equilibrium-at-high-mass conveyor belts (quest 3: frontier pinned at 1
every boundary, then flat at the end). Checked AFTER mass-decay.

### 4.3 Drained exit

`v_frontier_open = 0` → synthesis. The PoC's own comment: frontier_open=0
"never arrives organically" during productive descent — but it DOES arrive
under the **ENDGAME DRAIN** discipline (v4: "the drained exit
(descent → synthesis when drained) already existed; the change is
discipline, not law"). v4 measured: 86 open → 83 → 80 → 49 → **0** across
four descent phases (mass 1199 → 1151 → 1103 → 643 → 0), 28 web calls, then
synthesis + verification, quest complete in 7 phases — **no PLATEAU_CUTOFF
line, no plateau_cut marker: provenance reads exhausted, not cut**.

The drained endgame is an OVERLAY (R-064), not base law: ENDGAME DRAIN —
mass-ordered closures, multi-item sessions, **reseed restraint
(uncertainty ≥ 4 AND relevance ≥ 5, load-bearing only)**, unreachable
primaries → `residual-uncertainty` terminals, NO queue building. v4's proof
the restraint held: exactly **two** residual-uncertainty terminals in the
whole 296-claim graph, +69 evidence nodes across the drain — real closures,
not terminal dumping.

All three exits route to **synthesis** — never to a stop.

## 5. The never-reportless finisher (R-058) — hard law

**The law: every stop routes to synthesis, or is loud + explicit +
operator-visible. There is no third kind of stop.**

The PoC's costliest process defect (arc summary §2): "budget-exceeded and
MAX_PHASES both `stop_quest` without synthesis … Finishing required
operator intervention — twice." Hard law in kquest:

| stop | route | wiring |
|---|---|---|
| budget line crossed (ruled hard) in a work phase | → synthesis | transitions row `any-work-phase budget_exhausted → synthesis` |
| budget crossed in synthesis/verification | → paused (pause-and-present) | row `any-finisher-phase budget_exhausted → paused` — a half-written report is preserved and the operator disposes |
| phase cap reached in a work phase | → synthesis | row `any-work-phase phase_cap → synthesis`; synthesis + verification are CAP-EXEMPT (the finisher reserve, DR-06) |
| retry cap exhausted (a phase that cannot complete) | → paused (pause-and-present) | row `any-phase retry_cap_exhausted → paused` — the PoC's `PHASE_RETRY_EXHAUSTED` was a silent halt ("driver behavior at cap unknown, halt presumed"); superseded |
| transcript hard ceiling | → paused (pause-and-present) | I04 DR-06 runtime operator menu (swap-at-the-wall / compact-and-continue); the executed PoC ruling was the swap |
| slow stall, operator absent | → paused (pause-and-present) | I04 FM-18: alert-only by itself; NEVER auto-kill on growth alone; pause after the unattended window |
| verification violations beyond in-phase repair | → paused (rework-pause) | corrections are in-phase graph mutations (v4 astra corrected K227/E300 in verification); beyond that, the operator reworks — the graph is reworkable in place (I02 DR-17 fingerprints make drift visible) |
| **graph_invalid** (the boundary sweep refused) | → **stopped (stop-loud)** | the ONE stop that cannot route to synthesis: a broken artifact cannot be honestly reported on. The refusal names the repair path (the PoC tender's law: "needs repair, not a restart"); resume is the I02 stopped→active restart precedent |

**The loud shape (what "loud + explicit + operator-visible" means,
mechanically)** — every stop and every rule firing emits ALL FOUR:

1. **An event line** on the driver's stderr channel (the
   `PLATEAU_CUTOFF`/`FRONTIER_BUILD` channel law), one composed line:
   `PROCESS_STOP: <rule_id> at phase <n> (<phase_kind>) — <reason> — route: <route-to-synthesis | stop-loud: report impossible: <why> | pause-and-present>`.
2. **A ledger marker**: the phases row's result for the boundary + a quest
   lifecycle event (I02 `quest_lifecycle_events`: actor, note, the
   from/to pair) — the report's provenance (an arc CUT AT PLATEAU, CUT AT
   MASS, DRAINED, or STOPPED-LOUD is distinguishable from the artifact
   forever).
3. **The operator surface**: the stop surfaces on the quest-watch
   successor (ENTRY 8 SSE design) as an alert-class event, not a log line
   to tail.
4. **The synthesis route itself is recorded**: when a stop routes to
   synthesis, the synthesis prompt carries the stop marker as provenance
   (the PoC's `plateau_cut` marker: at_phase/window/lo/hi/
   decompose_remaining) — the report says what kind of arc produced it
   (v3's honest `[open]` markers for its 86-open plateau-cut arc).

FM-17 wiring (I04): "stop starting new turns at the boundary; route to the
never-reportless finisher discipline (synthesis, or an explicit loud stop —
ENTRY 6); pause the quest for the operator; a budget stop must never be
silently reportless" — consumed exactly: this section IS that ENTRY 6
discipline. FM-18 wiring: alert → unattended window → pause, never
auto-kill. Budget enforcement happens at TURN/PHASE BOUNDARIES only, never
mid-turn (I04 DR-09).

## 6. The stop-rule catalog as quantified config (R-059) + live re-readable boundaries (R-060)

### 6.1 The catalog

`artifacts/stop-rules.tsv` — 19 rules, columns
`rule_id / scope / metric / default / operator / action / provenance /
config_key` (the Specification's schema, law). Every default cites a
PoC-measured provenance that resolves (checker-enforced, AC3); the
calibrations the PoC never measured are flagged OPERATOR-RULING-NEEDED in
DECISIONS (never invented as silent defaults). Actions are the ruled enum:
`route-to-synthesis | pause-and-present | stop-loud | adjust` (adjust =
the machinery continues differently: fail the attempt and retry, or open
the frontier-build gate).

**Which defaults are what kind of honest** (the ledger):

| default | kind | evidence |
|---|---|---|
| web budget 1400 | live-run value (v2/v3 runbooks; quest-2 closed at 911/1400) | llm-trading-v3 §Design; arc summary §5 |
| token / spend budgets 0 (= off) | measured ABSENCE — no PoC quest ever ran one; the PoC budget object was web-calls only | llm-trading-v3 §Design; UNMEASURED → DR-09 ruling |
| max phases 200 | quest-2's launch cap; the measured complete arc took 215 phases (the near-miss: cap discovered env-frozen "with 5 slots left, ~6 minutes from a reportless stop") | arc summary §1, §3 |
| phase wall 2700s / phase timeout 7200s / retry cap 3 | PoC discovered defaults (env unset) | llm-trading-v3 §Phase-87 incident |
| activity timeout 1800s | the reaper's operative value ("ACTIVITY_TIMEOUT_S reaper, now 1800s"; live runs 1800/900; the driver's un-env default was 480) | mechanics reference §2 |
| mass-decay cut 0.25 / window 10 | backtest-anchored, NEVER live-fired | arc summary §2 → DR-07 ruling |
| plateau range ≤2 / window 10 (max(10,⌊n/2⌋)) | measured law shape; fired once live (v3 phase 112) | mechanics reference §5; llm-trading-v3 §Ruling (a) |
| frontier floor mass 200 | the built, harness-tested driver default (0 = off); NEVER live-fired as a gate (v3's decompose fed the frontier past 400 directly; the SKILL law carried breadth instead); operator ran 400 twice ("i was tempted to go for mass 800, but with the inflation, 400 seems reasonable") | muse-frontier §Build landed; llm-trading-v3 §Operator rulings → DR-02 ruling |
| frontier-build rounds 3 | the built default; live runs overrode to 5 | muse-frontier §Build landed |
| transcript ceilings 450,000 / 496,000 warn/hard | measured deaths at 496,294 B and 496,578 B, 284 B apart (I04 FM-02, consumed) | llm-trading-v3 §Post-resume ground truth |
| slow-stall 100 B / 1200 s / 3600 s | the operator's authoritative stall signal (I04 FM-18, consumed) | llm-trading-v3 §SLOWSTALL rule added |

**Budget-line modes** (I04 DR-09 consumed exactly, as amended by I05
DR-04): every budget line is per-line config data {scope, value,
mode ∈ advisory|hard}, **advisory by default**, per-line toggleable to hard
with adjustable values — with ONE ratified exception: the `read_slice`
line ships mode=hard (I05 DR-04: the refusal is itself the teaching
mechanism). An ADVISORY crossing is a loud boundary event + a teaching
surface + an ENTRY 7 signal — never a silent stop, never silent
truncation. A HARD crossing fires the transition row (§5). Quest-scope
steering lines (web/token/spend) are advisory-default; the structural
backstops are hard by nature: `quest.max_phases`, the phase walls/timeouts,
the retry cap, and the descent exit rules are machinery, not steering.

### 6.2 Live re-readable config at boundaries (R-060, L13, L7/L9)

Every phase boundary, the runner re-reads the whole process config from the
database: global defaults overlaid by `quests.process_config` (I01 DR-20's
carrier), plus `quest.web_call_budget` / `quest.token_budget` /
`quest.spend_budget_usd` (I01 §3.3), plus the per-phase-kind routing map
`quests.model_config` (§7). Cold-boot sessions read the same config at
session start (L7: every session reconstructs from durable state — the
live-patch precedent: "workers boot cold and read the quest SKILL first").
Config CHANGES land only through pause (I04 DR-04: pause-reconfigure-
resume; steer-while-running is REJECTED, D5) and take effect at the next
boundary.

The defect this kills (arc summary §3 item 3): "Phase cap env-frozen.
MAX_PHASES=200 in launch env, never re-read (unlike
budgets.max_web_calls, re-read every boundary)". The PoC's own
`WEB_BUDGET_RAISE` behavior (env may only RAISE a recorded cap on resume)
is the steering-channel precedent carried forward: boundary re-read is
law; the phase cap is a config FIELD, not an env pin.

**The full config-key registry** (19 keys; checker-verified 1:1 with
`stop-rules.tsv` both directions):

| config_key | mode | default |
|---|---|---|
| `quest.max_phases` | hard (backstop) | 200 |
| `quest.web_call_budget` | advisory-default, toggleable hard | 1400 |
| `quest.token_budget` | advisory-default, toggleable hard | 0 (off — DR-09 ruling pending) |
| `quest.spend_budget_usd` | advisory-default, toggleable hard | 0 (off — DR-09 ruling pending) |
| `quest.frontier_floor_mass` | hard (gate; 0 = off) | 200 (DR-02 ruling pending) |
| `quest.frontier_build_max` | hard (gate) | 3 |
| `phase.wall_timeout_s` | hard (attempt failure) | 2700 |
| `phase.timeout_s` | hard (attempt failure) | 7200 |
| `phase.activity_timeout_s` | hard (reaper) | 1800 |
| `phase.retry_cap` | hard (escalation) | 3 |
| `descent.mass_decay_cut_fraction` | hard (exit rule) | 0.25 (DR-07 ruling pending) |
| `descent.mass_decay_window` | hard (exit rule) | 10 |
| `descent.plateau_range_max` | hard (exit rule) | 2 |
| `descent.plateau_window` | hard (exit rule) | 10 |
| `engine.transcript_ceiling_warn_bytes` | per-provider config (early warning) | 450000 |
| `engine.transcript_ceiling_hard_bytes` | per-provider config (runtime menu, I04 DR-06) | 496000 |
| `engine.slow_stall_bytes` | alert-only | 100 |
| `engine.slow_stall_window_s` | alert-only | 1200 |
| `engine.unattended_pause_s` | pause trigger | 3600 |

The `engine.*` lines are I04 law consumed here (they bind the phase
runner's boundaries); their values and modes are I04 DR-06/DR-09's, not
re-ruled. Consequence enforcement (what HAPPENS when a hard line is
crossed repeatedly — quotas, throttles) is ENTRY 7's; the I03 DR-06
revisit trigger and I04 FM-17 enforcement wiring live there. This
iteration fixes detection, routing, and loudness.

## 7. Model routing (R-061)

Config carrier: `quests.model_config` (I01 §3.3: "per-phase-kind routing
map (contents shaped by ENTRY 6)"). Model identity lives in the routing
map and the audit columns — never in prompts (I04 DR-11 E-NOECHO; the v3
swap census needed three independent signals because the prompt echoed
the ledger's model provenance string).

### 7.1 Per-phase-kind: seeder vs closer

Banked PoC profiles (arc summary §1; muse-frontier §live evidence):
glm-5.3-flash = **aggressive closer, conservative seeder** (quest 3 phase
0: 6 seeds → frontier_open=1, "the only seeding event a fresh corpus
gets, and glm seeded it once, conservatively"); qwen/astra-class =
**strong seeder** (quest 2: qwen pre-built the 84-item frontier glm later
closed). Routing law:

| phase kind | profile | why |
|---|---|---|
| decompose, frontier-build | strong seeder | these phases CREATE the work queue; conservative seeding starves breadth (the quest-3 conveyor belt: frontier pinned at 1 for four phases) |
| descent | cheap closer | closure grind is the volume workload; the "machinery insisting" thesis: the glm switch closed ~50 phases + a 24-source decompose sweep in ~1 hour after qwen's slow grind |
| synthesis | strong writer (§7.3) | the report is the product |
| verification | closer-class | path-checking + spot checks are mechanical |

### 7.2 Mid-quest swap

Swaps land through pause-reconfigure-resume (I04 DR-04): pause at a
boundary, edit `quests.model_config`, resume; phase attempt numbering
continues (the PoC's banked phase-86 → phase-87 continuation). Two live
precedents: quest 2's operator-ruled closer switch (economics: slow local
grind → fast remote closer); quest 3's pause-swap-resume to the local
model and back when the ceiling confirmed ("finish the tail on glm via
or-relay; local model stood down"). The swap is a CONFIG edit, never a
running-session injection (D5).

### 7.3 Re-synthesis routing: cheap builder local / strong writer remote

Re-synthesis (I02 §7: repeat synthesis+verification with a different
model over the SAME graph — the repeated operator pattern) routes:

- **Builder** (context assembly): a cheap model — local where the window
  allows — assembles the synthesis context: sliced reads, the graph
  export, and for big graphs the **band-survey** pattern (I04 DR-10:
  read-only subagent workers over disjoint claim bands; astra's five-band
  survey K1–199…K750–821 was "a complete, parallel, context-free survey";
  the digest alternative was operator-rejected: "census without context").
- **Writer** (the report draft): a strong large-window REMOTE model. Both
  live re-syntheses (quest 2 v4, llm-trading v4) used the astra-class
  writer; both produced the standing artifact with zero interventions.

**Cache-wall economics** (arc summary §3 item 6; I04 FM-24): a 262k window
with an 8GiB prefix cache has an effective wall ~**205k** tokens; above it
every turn pays ~7 minutes of re-prefill — "local serving of big-context
synthesis is fragile; remote 1M windows sidestep it". Law: mega-context
phases (synthesis over large graphs) route to cache-capable /
large-window remote models per the routing map; the prefix is kept
append-only within a session (stable prefix = cache hits); cache_read /
cache_write are recorded per call (I04 DR-12) and cache_read=0 at high
context is an ENTRY 7 signal.

PoC-proven route facts (config VALUES, not law): remote workhorse
1M-context class at ~$0.04–0.05/M (proved on 3+2 quests); remote writer
1.05M-context class at $8–40/M (both standing reports); local 262k class
(cache-fragile >205k — fine for phases, wrong for mega-synthesis). Model
QUALIFICATION (probe → smoke → partial → full) is ENTRY 7's ladder; the
routing map cites ladder evidence per entry (R-072, consumed here as a
slot requirement).

## 8. Interactive briefing initiation (R-062)

The briefing is the entry point (north-star §sequencing: "The interactive
briefing (backlog) becomes the entry point that seeds the top-level
question decomposition"). Mechanics:

1. **Session**: interactive mode, operator driver (I04 §5.4 orchestrator-
   vs-operator table: the briefing/decompose initiation is the named
   interactive case), running as **decompose round 1** (I01 DR-13) —
   phase-attributed, audited, cold-bootable.
2. **Work**: operator + agent decompose the top-level question — stage
   agenda documents (quest_sources rows; sources role=`agenda`: readable,
   NEVER anchorable or citable, natively excluded from the decompose gate
   by schema, R-003 — the C43 lesson cost the PoC two hand surgeries),
   freeze the topic, and write the **topic questions** (the ground truth
   I03 DR-14's mechanical relevance embeds need-texts against).
3. **Gate**: `agenda_staged` — at least one agenda source staged — then
   autonomy: the orchestrator takes over (autonomous sessions, same tools/
   constraints/audit, L13) and decompose continues by the transition law.
4. **Autonomy threshold**: how much operator sign-off the briefing
   requires before autonomy is **OPERATOR-RULING-NEEDED** (DR-04) — the
   PoC has only the topic-surgery precedent (v1: topic staged as a single
   line into the ledger pre-phase-0, "TOPIC ADAPTATION" lines). Options +
   recommendation in DR-04.

The briefing's agenda-docs law kills the PoC's recurring defect class:
agenda documents are readable direction, never evidence — and in kquest
the exclusion is SCHEMA-native (`v_unmined_sources` filters
role = 'citable', I01 §3.17), so a staged primer can never wedge the
decompose counter the way C43 did (twice: the index surgery, then the
graft-carried ghost that minted K279 + E386 about the residue).

## 9. Per-phase contracts (R-063)

Each phase kind's contract: task, deliverables, gate (sweeping ONLY the
I05 parity fields), model profile, exit discipline. Span validity is
write-time law everywhere (I01 DR-08: pinned snapshot_char_count; L1
byte-exact offsets against the blob) — the phase gate re-verifies, never
first-verifies.

### 9.1 decompose

- **Task** (mode-conditioned; the PoC's two-line core, mechanics reference
  §4b): "Take one or more corpus sources with no evidence nodes yet:
  extract verbatim-anchored evidence and claim nodes and seed the frontier."
  Read SLICED (I05 DR-04 hard line); fused atomic forms (claim+evidence+
  edge in one call — the tool surface refuses evidence-free claims);
  ~3–4 sources per session (the session-context economy).
- **Deliverables**: evidence rows citing previously-unmined citable
  sources (the citation is what makes a source "mined"); claims (E:K ≈ 2:1);
  frontier seeds for secondarily-grounded claims.
- **Gate**: three-zeros sweep + **`v_decompose_remaining = 0`** to exit
  (else repeat). Metabolism (config defaults, R-018/I01 §9): ~5 evidence
  and ~2.6 claims per source, ~0.8–1 frontier seed per source — the yield
  brake is span strictness + the dedup law + the topic lens, no configured
  cap.
- **Model**: strong seeder. **Exit**: counter-exit (a pure counter —
  "decompose's exit is a pure counter (all sources mined). Questions
  unanswerable from the corpus never gate it — they become open frontier
  claims, which is exactly descent's input. The handoff IS the queue.")

### 9.2 frontier-build

- **Task**: enumerate the topic's clusters against the listing surface;
  create evidence-anchored queued claims + frontier entries with needs
  naming primaries (authors/year/venue) until the MASS floor is met.
  **Mass-based, not count-based** (muse-frontier §durable design: "a count
  floor alone re-creates the count-vs-mass blind spot the quest-2
  measurement exposed"). Anchoring spans come from already-saved corpus
  sources — no citation fabrication.
- **Deliverables**: frontier entries with distinct, claim-specific needs
  (the DISTINCT-NEEDS law: duplicate need strings corrupt mass ranking);
  per-cluster coverage.
- **Gate**: three-zeros + `v_frontier_mass` vs `quest.frontier_floor_mass`.
  Entry emits the loud `FRONTIER_BUILD` event (round n/MAX, mass < floor).
- **Model**: strong seeder. **Exit**: mass-floor-gate, rounds-capped.

### 9.3 descent

- **Task** (the PoC's line): "Take the top open frontier item: resolve its
  descent need (from the saved corpus when the target is already saved,
  else search and fetch it), decompose the target, wire derives_from,
  type terminals, update the frontier."
- **Deliverables**: closures (fetch/internal/refusal-tagged), derives_from
  wiring, typed terminals (definitional-mathematical / primary-empirical /
  residual-uncertainty — L2), successor spawns.
- **Gate**: three-zeros at every boundary; budgets rolled up
  (`web_calls_used`, `tokens_used`, `spend_used_usd`).
- **Model**: cheap closer (ENDGAME DRAIN overlay may flip to multi-item
  mass-ordered sessions, §4.3). **Exit**: mass-decay primary → plateau
  backstop → drained(+decompose re-entry) → fb re-entry → repeat.
- **Closure economics** (measured, arc summary §2, over 138 closures):
  FETCH mean **6.11** web calls (5.24 pure vs 7.51 after-paywall-substitute);
  INTERNAL **1.21**; give-up-alone 0.

### 9.4 synthesis

- **Task**: write the report FROM THE GRAPH (question-shaped chapters —
  the facet law, mode-conditioned; every material claim cited with local
  ordinals; imports explicitly marked, never silent, R-026/R-027).
- **Context is CONSTRUCTED, never inherited** (I02 DR-11/R-024: no
  report-body read affordance in a synthesis session — the artifact-
  inheritance defect, structural kill). For large graphs: band-survey
  assembly (§7.3).
- **Deliverables**: report draft + `report_citations` rows (the binding
  pass runs at finalization, I02 DR-12 — the model never transcribes
  hashes). Write in sections (the write-tool truncation teaching, R-053).
- **Gate**: three-zeros + **`citation_coverage`**. **Model**: writer
  (remote large-window). **Exit**: citation-coverage-exit → verification.

### 9.5 verification

- **Task**: **path-checking** (sample derivation paths; every assertion's
  path reaches a typed terminal or an explicit uncertainty flag — L2;
  verification becomes path-checking, not prose re-reading, north-star
  §architectural reading) + **spot checks** (spans byte-exact vs blobs;
  readings faithful to their spans).
- **Deliverables**: the verification result + corrections made IN PHASE
  (in-phase graph mutations; the v4 astra precedent: K227/E300 corrected —
  "101 bp/month is the mismatch portfolio; 139 is the mismatch-minus-
  agreeing-news spread — now stated correctly in the report").
- **Gate**: three-zeros + **`verification_clean`** → quest-done (lifecycle
  complete). Violations beyond in-phase repair → rework-pause (§5).
- **Model**: closer-class. **Exit**: verification-terminal.

## 10. Prompt-assembly discipline (R-063) + quest-local law overlays (R-064)

### 10.1 Assembly

Every phase prompt is ASSEMBLED at session cold-boot from exactly four
parts, nothing else:

1. **Phase-kind task text** — mode-conditioned; each line keyed to the
   phase kind it ships to. The vestigial-prose defect (arc summary §3
   item 4: the facet line "one chapter per facet" — a single-pass vestige
   — shipped mode-unconditioned into claim-graph synthesis and had to be
   live-patched) is killed at the source: no line enters a prompt without
   its phase-kind condition.
2. **Quest-local law overlay text** (§10.2).
3. **The status/gate surface** — the assembled `status` result (I05 §5:
   exactly the parity fields; the agent sees exactly what the gate
   enforces) and `quest_status` (phase, writer, budget lines — the agent's
   self-orientation).
4. **Boundary state**: the frontier top (descent), the unmined list
   (decompose), the mass snapshot, the stop markers carried as provenance
   (§5 item 4).

Never in a prompt: model/config identity strings (I04 DR-11 prompt-echo
prohibition, L13); report bodies (I02 DR-11); stale artifacts of any
kind. Config reads happen live at assembly (L13 corollary: "config reads
live at boundaries") — an assembled prompt is a pure function of durable
state + then-current config, which is what makes pause-reconfigure-resume
a complete steering channel.

**I05 frozen refusals as the teaching surface**: the phase prompts carry
the canonical calls (I05 §3.1); the frozen refusal texts teach IN-BAND at
the tool surface when the model errs — the phase contract does not
re-teach what a refusal already teaches (the frontier re-add recipe took
glm's 319-refusal storm to ~0 with zero prompt changes). Refusal-locates
(I05 §6) make the recoverable classes one-shot fixes.

### 10.2 Quest-local law overlays (the SKILL-law pattern, R-064)

Per-quest policy text grafted into phase prompts — the PoC's proven
live-steering channel, made structural. Shape: quest-scoped overlay rows
(name, target phase kinds, law text), read at cold-boot and at every phase
boundary with the rest of the config (R-060), applied by assembly. Overlays
TEACH; they never widen gates, never relax schema law, never add tools —
same tools, same constraints, same audit (L13).

PoC-proven overlay corpus (all were quest-local SKILL grafts; kquest makes
them config rows):

| overlay | origin | effect |
|---|---|---|
| DEDUP SEARCH CAP (≥1 search per candidate; >~10 consecutive searches with no mutation → STOP) | quest 3 phase-16 search storm | bounded dedup cost |
| AGENDA-ONLY PRIMER (mine for needs/direction; never anchor, never cite) | v3 operator ruling | agenda-doc law, enforced |
| DISTINCT-NEEDS (a need is a claim-specific question) | v3 | mass-ranking integrity |
| ID-PROBE / SYNTHESIS POINTER | v3 | tool-honesty ergonomics |
| FRONTIER FLOOR (first duty = frontier construction when thin) | quest 3 live patch | frontier 1→6 at the first boundary, 22+ frontier_add calls in-session |
| ENDGAME DRAIN (§4.3) | v4 | the drained exit, proven |

Because overlays are config, they are operator-steerable at pause — the
PoC's ruling pattern ("Option A: merge after quest 3 completes; Option B
declined — revisit if the live patch stops holding") becomes: edit the
overlay, resume.

## 11. Data-flow diagrams (R-065)

### 11.1 Corpus pipeline: fetch → chunk → embed (I03)

```
web fetch (budgeted op) ──▶ snapshot blob (object storage, content-hashed)
        │                        │
        │                        └─▶ sources row (URN = f(canonical_url, snapshot_sha))
        ▼
   quest_sources row (membership; role citable|agenda)
        │
        ▼
   chunk job (strategy config row: size/overlap/para/version)
        │  verbatim substrings + char offsets (L1/L10: offsets into the BLOB)
        ▼
   chunks rows ──▶ embed job (registry row pins model+batch) ──▶ per-model
   pgvector table + tsvector (GENERATED)          [idempotent, resumable,
                                                   J-IDEM: rerun = no-op resume]
   re-chunk = NEW strategy generation (old retained); re-embed = same jobs
   over the new generation — both are corpus jobs, never quest phases.
```

### 11.2 Extraction (decompose round n)

```
un-mined citable source (v_unmined_sources) ──sliced read──▶ session
   ──fused atomic forms──▶ evidence rows (byte-exact spans vs blob; write-time
   validation) + claims + evidence_edges (supports/contradicts) + frontier
   seeds (secondarily-grounded claims)
        │
        ▼ (boundary)
   three-zeros sweep over v_claim_closure + v_decompose_remaining recount
   ──pass──▶ transition law (§2.2)      ──refuse──▶ graph_invalid stop-loud (§5)
```

### 11.3 Frontier (frontier-build + descent)

```
frontier_add (need, uncertainty, relevance; distinct-needs law; one OPEN
entry per claim — schema) ──▶ v_frontier_open (u×r DESC order) 
        │                                        │
   [frontier-build:                               │
    enumerate clusters, pose until v_frontier_mass ≥ floor]
        ▼                                        ▼
   descent session: take TOP item ──▶ closure (fetch|internal|refusal tag)
        │                            └─▶ spawns (next-generation questions)
        ▼
   boundary: v_frontier_mass + v_frontier_open snapshot onto the phases row
   ──▶ exit rules (mass-decay → plateau → drained → fb re-entry → repeat)
   mass curve + closure classes persist as the calibration ledger (I20).
```

### 11.4 Synthesis + verification

```
graph + corpus ──constructed context (band-survey assembly for large
graphs; NO report-body reads)──▶ synthesis session (writer model)
   ──▶ report draft (local ordinals) ──binding pass──▶ report_citations
   rows (ordinals → URNs; imports explicitly marked)
        │
        ▼
   verification: path-checking (derivation paths → typed terminals, L2)
   + spot checks (spans vs blobs) ──corrections──▶ in-phase graph mutations
        │
   verification_clean ──▶ quest-done; report version pins the quest
   fingerprint (I02 DR-17); standing pointer flips at finalization.
   violations beyond repair ──▶ rework-pause (§5).
```

### 11.5 Canonical merge + re-chunk/re-embed

`v_canonical_claims` is a DERIVED view (I02 DR-16): there is no merge data
flow — the hub is an index, divergence is a tripwire, and reports draw on
own-quest evidence or explicitly marked imports. Re-chunk/re-embed are
the §11.1 corpus jobs re-run over new generations (I03 DR-10/DR-04);
nothing in the quest phase machine touches them.

## 12. Constraint catalog EXTENSION — process laws

| id | law | enforcement point |
|---|---|---|
| P-PRIO | transition rows evaluate in file order within a phase; first match wins — stop rows precede succession rows | the phase runner reads transitions.tsv as ordered config; check-transitions.sh pins the order classes |
| P-NOREPORT | every stop routes to synthesis or is loud + explicit + operator-visible (§5's four-part shape) | transitions.tsv route column + the event/ledger/lifecycle wire (checker: every non-synthesis stop target carries pause-and-present/stop-loud) |
| P-REREAD | the full process config is re-read from the database at every phase boundary and session cold-boot; changes land only through pause | the phase runner's boundary step; quests.process_config is the carrier (I01 DR-20) |
| P-BND | budget checks run at turn/phase boundaries only, never mid-turn; advisory crossings teach, hard crossings fire the transition row | I04 DR-09 consumed; FM-17 rollup point |
| P-OVERLAY | quest-local overlays teach; they never widen gates or relax schema law | overlay rows are prompt-assembly inputs only |
| P-GATEPARITY | phase gates sweep ONLY the I05 parity fields | I05 §5 law consumed; the three-zeros + per-phase additions are exactly §3's table |

## 13. Traceability — R-056–R-065 (machine-checked by check-coverage.sh)

| R-item | status | carrier | notes |
|---|---|---|---|
| R-056 | DESIGNED | §2 phase set + transition law; artifacts/transitions.tsv (25 rows) + artifacts/check-transitions.sh | mass floor, re-entry rounds, decompose re-entry all wired |
| R-057 | DESIGNED | §4 both exit disciplines + mass-decay primary (backtest −75.5%/−61%, I16 0/115); plateau level-blind limitation recorded §4.2 | drained-exit §4.3 |
| R-058 | DESIGNED | §5 never-reportless finisher as hard law; the loud shape (4 parts); FM-17/FM-18 wiring named | graph_invalid = the one stop-loud exception |
| R-059 | DESIGNED | §6.1 stop-rule catalog (19 rows, PoC-measured defaults + honesty ledger); artifacts/stop-rules.tsv | unmeasured calibrations → DR-02/DR-07/DR-09 |
| R-060 | DESIGNED | §6.2 live re-readable config at boundaries (P-REREAD); the 19-key registry | the env-frozen phase-cap defect killed |
| R-061 | DESIGNED | §7 per-phase-kind seeder/closer, mid-quest swap via pause-reconfigure-resume, re-synthesis builder/writer + cache-wall economics | model_config carrier |
| R-062 | DESIGNED | §8 interactive briefing (decompose round 1, interactive session, agenda_staged gate) | autonomy threshold → DR-04 ruling |
| R-063 | DESIGNED | §9 per-phase contracts (deliverables + gates; three-zeros wiring §3; citation coverage; verification = path-checking + spot checks); §10.1 prompt-assembly discipline | mode-conditioned, no vestigial prose |
| R-064 | DESIGNED | §10.2 quest-local law overlays (the SKILL-law pattern; PoC overlay corpus table) | overlays are config rows |
| R-065 | DESIGNED | §11 data-flow diagrams: fetch→chunk→embed; extraction; frontier; synthesis/verification; canonical merge + re-chunk/re-embed | canonical merge is I02's derived view — no data flow |

## 14. Deferrals and handoffs

- **Consequence enforcement** (what repeated hard-line crossings cost —
  quotas, throttles, quest-level lockouts): ENTRY 7 (assurance). The I03
  DR-06 spend-accounting revisit trigger and the I04 FM-17 enforcement
  half land there; this iteration ships detection + routing + loudness.
- **Tripwire predicates** over the process signals this iteration persists
  (mass curves, closure classes, stall alerts, stop events): ENTRY 7
  (R-069/R-070 consumers).
- **Model qualification ladder** (probe → smoke → partial → full) that the
  routing map must cite: ENTRY 7 (R-072).
- **Phase-runner/job-runner wiring, SSE event shapes for the stop/alert
  surface (§5 item 3), the steering console**: ENTRY 8 (R-074/R-075/R-076).
- **Tool-side enforcement mechanics** (fused forms, refusal fixtures,
  write-guard): I05 (law) → implementation arc.
- **The transitions/stop-rules consumers**: the implementation arc reads
  both TSVs as the config source for the phase runner (this iteration's
  contract with ENTRY 8's topology).

## 15. Method note: what was verified vs assumed

Verified against source: the PoC driver's transition law (read
`repos/hermit-kb/quest/quest-driver` — `next_phase`, `fb_eligible`,
`plateau_cutoff`, `stop_quest`, the env-knob defaults); the I16 window
shape (mechanics reference §5); the mass backtest numbers (arc summary §2);
the v3/v4 endgame records (llm-trading-v3 §Ruling (a), §v4 ENDGAME
CONTINUATION); the I01 views/phases/quests columns; the I04/I05 rulings
cited. Assumed (design, flagged): the mass-decay firing threshold
(backtest-anchored, DR-07); the briefing autonomy threshold (DR-04); the
token/spend cap defaults (DR-09). No SQL was executed in this iteration
(no new schema expected — the Grounds' environment note); the gates are
parsers over the two TSVs plus prior-law immutability checks.
