# I06 — quest-process: decision records

Fourteen records. Status is DECIDED or OPERATOR-RULING-NEEDED (those carry
Options + Recommendation; the operator ratifies at the iteration gate).
Prior law is consumed exactly as ratified; amendments are proposals only
(DR-14: none).

## DR-01 — Exit discipline defaults per phase kind

**Status:** DECIDED
**Ratified 2026-11-22 (knowingly):** the operator confirmed the ONE
reference-ordering amendment — mass-decay is checked BEFORE plateau-cut
(the PoC driver checked plateau first); rationale: mass decays before
count ever flattens, and a primary checked second is not primary
(R-057 + the −75.5%/−61% backtest).
**Decision:** Descent carries THREE exits in priority order:
mass-decay primary (fires when frontier mass ≤ 0.25×running peak
sustained over 10 boundaries — DR-07 calibrates), plateau-cut backstop
(count-flatness, level-blind, retained for the equilibrium-at-high-mass
shape mass-decay cannot see), drained-exit (frontier open = 0). All three
route to synthesis. Decompose exits by pure counter (v_decompose_remaining
= 0; questions the corpus cannot answer never gate it — they become
frontier entries). Frontier-build exits by the mass floor + rounds cap.
Synthesis exits by citation coverage; verification by verification_clean.
Transition rows evaluate in file order (first match wins); stop rows
(never-reportless wiring) precede succession rows; mass-decay precedes
plateau precedes drained inside descent.
**Rationale:** The backtest (arc-run-20261122T-quest2-arc-summary §2):
mass −75.5% (941→230) while count −61% AND rising; I16 fired 0/115
checkpoints — count-flatness cannot see a decaying-but-reseeding frontier,
and mass cannot see a high-mass equilibrium (quest 3's frontier pinned at
1, then v3's cut at 86 open / mass 1199). The two are complementary; the
drained exit is the only one that reads "exhausted" in provenance (v4: no
PLATEAU_CUTOFF line). The PoC checked plateau FIRST (driver law); kquest
inserts mass-decay ahead of it because the backtest shows mass decays
BEFORE count ever flattens.
**Alternatives considered:** (a) mass-decay ONLY (replace I16, the I20
graduation option) — rejected: the quest-3 conveyor belt proves a
high-mass equilibrium can persist forever with mass-decay blind to it;
(b) count-flatness AND mass-near-zero gated together — rejected: gating
AND would have stopped neither quest 2 (count never flat) nor quest 3
(mass never near zero); (c) keep plateau primary — rejected: 0/115 with
the organic exits reportless is a dead law as primary.

## DR-02 — Plateau window + mass floor defaults

**Status:** DECIDED (operator ruling 2026-11-22: **A — ratified as recommended**) — the frontier floor ships 200 built-in)
**Ruling note:** harness-validated (12/12 dry runs; would have fired on quest 3's mass 98). The window and range are decided within.
**Decision:** Plateau window W = max(10, ⌊n/2⌋) completed descent phases
with a recorded frontier_open snapshot, range ≤ 2 (`descent.plateau_window`
ships 10, `descent.plateau_range_max` ships 2) — the measured I16 law
verbatim (mechanics reference §5; fired live once, v3 phase 112,
window=10). The frontier floor `quest.frontier_floor_mass` ships at the
built driver default **200** (0 = gate off) with the shape mass-based,
never count-based.
**Rationale for the floor flag:** 200 is the built, harness-tested default
(muse-20261122T-frontier-building §Build landed: 12/12 transition harness
PASS; real-data mass verified vs SQL) but was NEVER live-fired as a gate:
quest 3's decompose fed the frontier past the floor directly ("the floor
of 400 was never needed — decompose of the 43-source launch corpus fed
the frontier past the floor directly"), and the SKILL law carried breadth
instead. The operator has twice run 400 with explicit inflation awareness
("i was tempted to go for mass 800, but with the inflation, 400 seems
reasonable" — llm-trading-v3 §Operator rulings) — a live-ruled value that
contradicts the shipped default is exactly what an operator ruling
should settle. Mass inflation (the R-059 awareness) is real: self- or
model-assigned u×r drifted across sessions in the PoC (I20 §caveats);
I01's schema-side floor is 1..5 per axis, and I03 DR-14's mechanical
relevance is the consistency fix — the floor's absolute meaning therefore
shifts with relevance scoring vintage.
**Options:**
- (A) Ship 200 (the built default): the gate fires early on thin
  frontiers; risk: under a mature mechanical-relevance scorer, absolute
  mass values may sit differently than in the PoC, so 200 may be too low
  or too high — unmeasurable until a kquest quest runs.
- (B) Ship 400 (the operator's twice-live value): matches the two arcs
  where a floor was actually in the operator's mind; risk: it was never
  a GATE value either — 400 was the floor quests were launched WITH while
  decompose outran it.
- (C) Ship 0 (off) as default and rely on the frontier-build phase being
  operator- or overlay-triggered: maximum honesty about what is measured;
  risk: fresh-corpus quests lose the structural breadth guard and inherit
  the conveyor-belt failure mode by default.
**Recommendation:** (A) — ship 200 as the catalog default (it is the only
value the driver machinery was actually built and harness-tested
against), keep 0=off, document 400 as the live-run precedent in the
config registry, and MANDATE a revisit at the first kquest quest that
actually fires the gate (the same review trigger as DR-07's).
**Alternatives considered:** a count floor with per-cluster coverage —
rejected at PoC design time and reaffirmed here ("a count floor alone
re-creates the count-vs-mass blind spot the quest-2 measurement exposed").

## DR-03 — MAX_PHASES + decompose-counts-toward-cap

**Status:** DECIDED
**Decision:** `quest.max_phases` default **200**, counting phases of ALL
kinds — decompose phases count toward the cap (the PoC lesson:
"decompose phases count toward the cap, so long decompose phases (big
inherited corpus) shorten descent headroom. Watch phase index if
decompose runs past ~35" — mechanics reference §8). At the cap the quest
routes to synthesis (never-reportless), and synthesis + verification are
CAP-EXEMPT (DR-06).
**Rationale:** The measured arc: quest 2 ran **215 phases end to end**
with MAX_PHASES=200 pinned in launch env — the cap was discovered
env-frozen "with 5 slots left, ~6 minutes from a reportless stop" (arc
summary §3 item 3), and finishing required the phase-cap restart
precedent (operator intervention). 200 is therefore the measured
"complete organic arc is slightly MORE than this" value; with the cap
routing to synthesis (instead of stopping reportless), crossing it is a
report with a cut-at-cap provenance marker, not a stranded quest. Big
inherited corpora (v3: 82 consecutive decompose phases) raise the cap as
per-quest config — the live-rereadable channel (P-REREAD) is what makes
that safe to change mid-quest, which the env-frozen PoC cap was not.
**Alternatives considered:** (a) the driver's un-env default 10 — a toy
value, worse than useless as a product default; (b) 400 (v3's value) —
defensible for inherited-corpus arcs but it delays the backstop for
everyone; (c) exempting decompose from the cap — rejected: the cap exists
to bound TOTAL spend of phases; the parallel-decompose candidate
(mechanics reference §8) is the right fix for decompose eating the cap,
and it stays design-compatible (L12).

## DR-04 — Briefing autonomy threshold

**Status:** DECIDED (operator ruling 2026-11-22: **A — ratified as recommended**) — briefing autonomy = sign-off-only; no numeric threshold exists to misfire)
**Decision:** The briefing is an interactive decompose round 1 (operator
+ agent decompose the top-level question, stage agenda docs, freeze the
topic + topic questions); the autonomy gate is `agenda_staged` (≥1 agenda
source on the quest) PLUS operator sign-off delivered as a pause-resume
(the operator ends the briefing session; the orchestrator resumes
autonomously). The THRESHOLD — how much briefing is enough before
autonomy — is not measured anywhere in the PoC.
**Rationale:** The PoC's only initiation precedents are ambient: topic
surgery on a from-corpus clone ("TOPIC ADAPTATION" lines, topic staged as
a single line into the ledger pre-phase 0) and staged agenda docs with a
quest-local AGENDA-ONLY law (v3's primer C43). No PoC run ever had a
structured briefing, so any threshold number would be invented. R-062
says "operator + agent decompose the top-level question, stage agenda
docs, then autonomy" — the word "then" is the operator's, but its
duration/depth is a product-taste call.
**Options:**
- (A) Sign-off only (no numeric threshold): the briefing ends when the
  operator says so; `agenda_staged` is the only mechanical gate.
  Maximum operator control; zero autonomy for operator-less quests.
- (B) N-round briefing: exactly N interactive decompose rounds before
  autonomy, N as config (unmeasured default).
- (C) Deliverable-gated: autonomy when the topic questions + agenda
  cover a cluster map the operator accepts — subjective, unenforceable.
**Recommendation:** (A) for v1 — it is the only option with no invented
number; it matches L13 (interactive requires pause; one writer; same
tools/constraints/audit) and the D5 posture; autonomous-only quests simply
skip the briefing session and stage agenda docs at init. Revisit when the
first real briefings produce observable shapes (how many rounds they
take, what agenda-doc counts look like).
**Alternatives considered:** a required cluster count — rejected:
frontier-build already enforces cluster coverage structurally (mass
floor), double-gating the same property at the briefing adds a veto point
with no measured failure to justify it.

## DR-05 — Re-synthesis model defaults

**Status:** DECIDED
**Decision:** Re-synthesis (I02 §7: repeat synthesis + verification with
a different model over the SAME graph) routes by a two-slot law:
**builder** (context assembly — sliced reads, graph export, band-survey
for large graphs) may run cheap/local where the context window allows;
**writer** (the report draft) routes to a strong large-window REMOTE
model. Cache-wall guard: mega-context synthesis never routes local —
measured effective wall ~205k on a 262k window with 8GiB prefix cache;
above it every turn pays ~7 minutes of re-prefill (arc summary §3 item 6;
I04 FM-24). Default VALUES are config (the routing map cites the
qualification ladder, ENTRY 7), seeded from the PoC-proven facts:
remote workhorse 1M-context class ~$0.04–0.05/M (proved on 3+2 quests,
the cheap closer), remote writer 1.05M-context class $8–40/M (both
standing reports, zero interventions), local 262k class (fine for
phases, wrong for mega-synthesis).
**Rationale:** The pattern ran live TWICE with the same shape (quest 2
v4-astra; llm-trading v4-astra): move the old report out (artifact
hygiene), route the writer to the strong remote model, run synthesis +
verification over the same graph, land the standing artifact. The
builder/writer split follows from cache economics: assembly is
parallelizable and cache-tolerant (band-survey workers are read-only,
context-free), drafting is one long append-only context where prefix
cache hits only exist if the window never crosses the wall.
**Alternatives considered:** (a) local mega-context synthesis with
compaction — rejected: the PoC measured the fragility (the 496k ceiling
deaths AND the 205k cache wall are both local-serving failures; the
executed ruling both times was the swap); (b) digest-then-write (census
without context) — operator-rejected at PoC; (c) fixed model names in law
— rejected: model identity is config + audit columns, never law and never
prompt-echoed (I04 DR-11).

## DR-06 — Phase-cap vs never-reportless interplay

**Status:** DECIDED
**Decision:** The finisher RESERVES headroom: synthesis and verification
are exempt from `quest.max_phases` — the cap binds work phases only
(decompose, frontier-build, descent). At the cap, the transition routes
to synthesis regardless of queue state; the report carries a
cut-at-phase-cap provenance marker (§5's loud shape); the phase-cap
restart precedent (I02 stopped→active) remains available to the operator
who wants more depth instead of a report.
**Rationale:** The PoC's phase-cap episode is the never-reportless
failure in its purest form: cap discovered with "5 slots left, ~6 minutes
from a reportless stop", and the actual rescue was an operator restart
with a raised cap. If the cap can stop the finisher itself, no reserve
exists and the law is circular. Reserving two slots converts the cap
from a cliff into a floor: the worst case at cap is a CUT report (with
honest open markers), never NO report. The reserve is cheap by
measurement: synthesis + verification together were 2 phases of 115 (v3)
and 2 of 7 (v4) with ~0 web calls.
**Alternatives considered:** (a) cap counts everything, stop at cap —
the PoC behavior, measured reportless, rejected; (b) cap + N reserved
slots where N is config — needless generality: the finisher is exactly
synthesis+verification (the I01 phase set is frozen); (c) no cap at all
— rejected: the backstop is load-bearing for runaway decompose on big
inherited corpora (82 consecutive decompose phases in v3).

## DR-07 — Mass-decay cut calibration

**Status:** DECIDED (operator ruling 2026-11-22: **A — ratified as recommended**) — mass-decay cut = 0.25× running peak over a 10-phase window; peak-relative kills the inflation problem)
**Decision:** The rule shape is decided (DR-01): fire when frontier mass
≤ cut-fraction × running peak, sustained over the window. The catalog
ships `descent.mass_decay_cut_fraction` = **0.25** and
`descent.mass_decay_window` = **10** — with the explicit flag that 0.25 is
BACKTEST-ANCHORED, never live-fired.
**Rationale:** The backtest (arc summary §2) measured the currency
validated and the arc's end state — mass 230 against a 941 peak (24.5%
of peak, −75.5%) — at the point where the operator intervened to close
the quest. No rule ever FIRED on a live quest (I16: 0/115; mass-decay:
not wired). 0.25 is therefore the measured arc-end ratio, not a measured
firing point; presenting it as a calibrated default would be dishonest.
The window 10 reuses the measured plateau window (both windows look at
the same boundary snapshot series).
**Options:**
- (A) 0.25×running peak sustained 10 boundaries (the catalog default):
  would have fired near the end of quest 2's qwen phase — approximately
  where the operator actually ruled the switch. Risk: one quest's
  exhaustion curve is a sample of one.
- (B) Absolute mass floor (fire at mass ≤ X): simpler, but absolute mass
  is scorer-vintage-dependent (the inflation problem, DR-02) — a value
  calibrated against PoC u×r assignments does not transfer.
- (C) Gate mass-decay with count-flatness (fire only when BOTH): most
  conservative; risk: gates can deadlock (neither fires), which is the
  0/115 failure mode wearing a second rule.
**Recommendation:** (A) as the shipped default — peak-relative kills the
inflation problem (the peak inflates with the floor), the 0.25 anchor is
the only measured exhaustion ratio that exists, and DR-02/DR-07 share a
mandatory review trigger: the first kquest live firing of either rule
re-opens both calibrations with real curves (the mass snapshots persist
on every phases row, I01 §3.13 — the calibration ledger is structural).
**Alternatives considered:** I20's expected-graph-delta scoring (score
items by expected restructure of the graph) — the principled successor,
but unimplemented and unmeasured in the PoC; the layer-1 structural
uncertainty it needs is design freedom (I20 §caveat 4: "the backtest is
what disciplines them, not intuition"). Named as the growth slot; not the
day-one rule.

## DR-08 — Frontier-build rounds cap default

**Status:** DECIDED
**Decision:** `quest.frontier_build_max` default **3** (the built,
harness-tested driver default), overridable per quest (live precedent:
v2/v3 ran 5).
**Ratified 2026-11-22:** operator confirmed 3 (harness-tested) over the
live-runbook 5; neither value ever fired as a gate; toggleable at pause. Rounds are per QUEST (count of frontier-build phase rows),
and the cap is the re-entry valve: at cap with mass still under the
floor, the gate stops opening and descent/synthesis proceed — the
frontier stays thin and the report says so (honest thin-queue markers,
the plateau-cut provenance discipline).
**Rationale:** The valve exists to prevent an infinite build↔descend
loop (driver comment: "the re-entry valve, never an infinite loop"); 3 is
the value the machinery shipped and was tested with (12/12 harness),
5 is the value two live arcs carried without ever entering the phase
(decompose outran the floor both times, so the rounds were never spent).
No live data distinguishes 3 from 5; the shipped default is the only
harness-tested number.
**Alternatives considered:** 5 (the live-runbook value) — equally
unfired as a gate; unbounded rounds — rejected (the loop); per-round
decaying floors (floor × 2^-n) — elegance without evidence, deferred with
the parallel-decompose candidate.

## DR-09 — Token and spend cap defaults

**Status:** DECIDED (operator ruling 2026-11-22: **A — ratified as recommended**) — token/spend caps ship 0 = off; honest measured absence; the I03 DR-06 revisit trigger governs if spend ever gains consequences)
**Decision:** `quest.token_budget` and `quest.spend_budget_usd` ship
default **0 = off**, mode advisory-default (toggleable hard per the I04
DR-09 pattern). The web-call budget ships 1400 (the live-runbook value,
quest-2 closed at 911/1400).
**Rationale:** 0=off is the measured PoC state, not an invented
calibration: no PoC quest ever ran a token or spend cap — the launch
dials were FRONTIER_FLOOR_MASS, FRONTIER_BUILD_MAX, MAX_PHASES,
WEB_BUDGET, ACTIVITY_TIMEOUT_S only (llm-trading-v3 §Design), and the
ledger's budget object was {web_calls_used, max_web_calls} (driver
write_ledger_init). Spend was OBSERVED (D10's origin: glm ~$0.04–0.05/M
workhorse, $8–40/M writer) but never bounded. Cloud routing (the
ProviderDesk seam) makes real money day-one-relevant in kquest, which the
file-based PoC never faced — a default the operator must actually rule.
**Options:**
- (A) 0/off with the advisory-default mode and a loud advisory crossing
  event: honest about what is measured; the operator rules per deployment.
- (B) A conservative absolute spend cap (e.g. single-digit dollars per
  quest): safe-looking, invented — no PoC quest's spend was ever
  totted per-quest in a capped form.
- (C) Mandatory hard caps before any cloud-routed quest (a launch
  precondition in the runner): strongest containment; couples this
  iteration to ENTRY 8's runner wiring.
**Recommendation:** (A) for the catalog + (C) as a proposed runner
precondition for ENTRY 8 (recorded as a deferral, not decided here):
the honest default is off until the operator sets a number they will
actually stand behind; the precondition makes "off" safe to ship.
**Alternatives considered:** deriving a cap from the metabolism
constants (calls × price) — a derived ceiling pretending to be a
measured one; the metabolism is per-source yield, not per-quest spend.

## DR-10 — Budget-line modes consumed exactly

**Status:** DECIDED
**Decision:** Consume I04 DR-09 as ratified and amended: every budget
line is {scope, value, mode ∈ advisory|hard}, ADVISORY BY DEFAULT,
per-line toggleable, EXCEPT the read_slice line which ships mode=hard
(I05 DR-04/A — the one ratified exception; the refusal is the teaching
mechanism). Advisory crossings are loud boundary events + ENTRY 7 signals
+ teaching (never silent truncation); hard crossings fire the §5
transition rows. The structural backstops (quest.max_phases, phase walls/
timeouts, retry cap, the descent exit rules) are HARD by nature — they
are machinery, not steering, and are not "budget lines" under DR-09.
**Rationale:** Ratified law, consumed exactly (AC5); re-deciding it here
would be a prior-law amendment in disguise. The PoC's hard-cap
reportless stops are why the steering lines are advisory; the
never-reportless finisher is why the hard lines are safe.
**Alternatives considered:** treating the phase cap as advisory —
rejected: a backstop that teaches is not a backstop (the env-frozen cap
near-miss is the cautionary tale FOR hard caps that route loudly, not
against them).

## DR-11 — The loud-stop shape (stop-loud + pause-and-present)

**Status:** DECIDED
**Decision:** Two non-synthesis stop classes exist, both loud by the
four-part shape (event line on the driver stderr channel; ledger +
lifecycle marker; operator surface event; route recorded in the
artifact's provenance): **stop-loud** (graph_invalid → quest stopped —
the ONE stop that cannot route to synthesis; the refusal names the
repair path; resume is the stopped→active restart) and
**pause-and-present** (retry-cap exhaustion, transcript hard ceiling
[I04 DR-06's runtime menu], slow-stall after the unattended window,
budget crossing in a finisher phase, verification violations beyond
in-phase repair → quest paused, operator disposes).
**Rationale:** R-058's carve-out needs a shape, not a vibe: every element
of the four-part shape is a PoC-proven channel (PLATEAU_CUTOFF stderr
line + plateau_cut ledger marker; the tender's "needs repair, not a
restart" refusal; the babysitter's ALERT surfaces; v3's honest [open]
markers). The pause-and-present class is I04 DR-06's protocol generalized
to every operator-decision stop; stop-loud is reserved for the single
case where honest synthesis is impossible (a graph that failed its
boundary check).
**Alternatives considered:** routing graph_invalid to synthesis with a
caveat — rejected: fabricating a report over a failed integrity check is
the honesty-bounds inversion (BRIEF §2: fabrication fails at write time);
a fifth channel (email/webhook) — ENTRY 8's alerting surface, not law
here.

## DR-12 — Quest-local law overlay mechanics

**Status:** DECIDED
**Decision:** Overlays are quest-scoped config rows (name, target phase
kinds, law text) read at cold-boot and at every phase boundary, applied by
prompt assembly only. They teach; they never widen gates, relax schema
law, or add tools. The PoC-proven corpus ships as examples, not defaults:
DEDUP SEARCH CAP, AGENDA-ONLY, DISTINCT-NEEDS, ID-PROBE, SYNTHESIS
POINTER, FRONTIER FLOOR, ENDGAME DRAIN (§10.2 table).
**Rationale:** The channel is the PoC's most-proven steering mechanism
(the medical refusal-loop patch, the frontier-floor live patch —
"workers boot cold and read the quest SKILL first"; the frontier went
1→6 at the first boundary after the patch). Making it config (not SKILL
file surgery) is what R-064 asks; keeping overlays teaching-only is what
keeps L6/L13 intact (same tools, same constraints, same audit).
**Alternatives considered:** overlays as first-class schema law (a rules
table the gates read) — rejected: gate law is prior-law frozen (I01/I05);
an overlay that could change gate behavior would be a second validator,
the exact asymmetric-validator defect class I05 killed.

## DR-13 — Prompt-assembly discipline

**Status:** DECIDED
**Decision:** Prompts are assembled from exactly four parts (§10.1:
mode-conditioned phase task text; overlay text; the status/gate surface;
boundary state) — never model/config identity strings (I04 DR-11), never
report bodies (I02 DR-11), never stale artifacts. Every prompt line is
phase-kind-conditioned; vestigial single-pass prose is a defect class
(the mode-unconditioned facet line, arc summary §3 item 4).
**Rationale:** The PoC's prompt defects were all assembly defects:
mode-unconditioned vestige (item 4), config-echo with a long half-life
(the model-swap census), artifact inheritance (v2 restructuring v1). The
four-part assembly is the structural kill for all three: assembly is a
pure function of durable state + then-current config.
**Alternatives considered:** one monolithic per-quest prompt file (the
PoC's SKILL) — rejected for kquest: it is exactly the artifact that had
to be live-patched per quest; free-text operator prompt additions —
rejected: that is the overlay channel, or it is nothing.

## DR-14 — Prior-law amendment proposals: none

**Status:** DECIDED
**Decision:** No prior-law amendments are proposed. The transition law
consumed I01 (views, phases columns, process_config carrier, DR-13
briefing-as-decompose-round-1), I02 (lifecycle pairs — including the
"never-reportless finisher honored, ENTRY 6" note on the complete
transition, which this iteration's verification→quest-done row wires),
I03 (DR-14 relevance carrier), I04 (DR-04/DR-06/DR-09, FM-01/02/17/18),
I05 (parity law, three-zeros CONFIRMED composition) exactly as ratified.
**Rationale:** The phase contracts needed no schema change: every gate
the transition law sweeps is an existing view or an existing column; the
config carrier (quests.process_config) and the routing carrier
(quests.model_config) were pre-shaped by I01 for exactly this iteration
(I01 §3.3: "contents shaped by ENTRY 6", DR-20: "ENTRY 6's stop-rule
catalog (R-059) consumes them").
**Alternatives considered:** proposing a phases.stop_marker column for
the §5 ledger markers — rejected: the phases result jsonb (I01 §3.13:
"result jsonb (phase deliverables; shape owned by ENTRY 6 phase
contracts R-063)") is the designated carrier; this iteration's contracts
define the marker shape inside it, no DDL change.
