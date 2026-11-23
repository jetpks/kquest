# I05 — tool-surface: DESIGN

Design document for kquest's agent-facing tool surface. The PoC's failure
taxonomy proved most engine deaths were tool-teaching failures — 664
GRAPH_INVALID refusals in 6,683 tool results (≈10%) on quest 2
(`arc-run-20261121T-quest2-failure-taxonomy.md` §cost), while the medical
arc's teaching patch cut evidence-hunting failures 330+ → 24
(`arc-run-20261121T-quest2-teaching-patch.md` §preflight 2). This
iteration freezes the normative tool API as PARSEABLE FIXTURES whose
exact refusal texts are the implementation arc's contract tests — design
output here is CONTRACT, not prose.

- Law: space BRIEF §3 L1/L5/L6/L15, §4 D2 (small sharp tools, hard
  contracts, canonical calls + refusal fixes as teaching), §5 (tool layer
  composition). Requirements owned: catalog §E R-047–R-055 (traceability
  §10).
- Prior law consumed as contracts: I01 (the schema every tool writes
  through: claims/evidence/edges/frontier/chunks, the dedup-guard
  constraints, `v_claim_closure`/`v_frontier_open`/`v_frontier_mass`/
  `v_unmined_sources`/`v_decompose_remaining`, tenancy law); I02 (report
  version chain, citation binding pass, import marking, `v_canonical_claims`);
  I03 (hybrid retrieval, dedup-by-construction family d, G-REG: the registry
  is the only model path); I04 (ToolHarness, FM-12/FM-16, DR-08's subagent
  profile whose normative shape lives HERE, DR-09's advisory-line law).
- Artifacts: `artifacts/fixtures/<tool>.md` (one per tool, STRICT format),
  `artifacts/check-fixtures.sh`, `artifacts/check-coverage.sh` (gates).
- Decision records: `DECISIONS.md` (DR-01…DR-10; DR-07 carries
  OPERATOR-RULING-NEEDED).
- Naming law (I04 ratification, 2026-11-22): the provider boundary
  component is **ProviderDesk**; the retired boundary word is not used
  anywhere in this document to name a component or boundary. Catalog §E
  R-054's original wording ("retrieval tools behind the …") predates that
  ratification; this design names the boundary it means "the embedding
  registry" (I03 G-REG) and reads R-054 as: retrieval tools sit behind the
  registry and the agent never names a model.

## 1. Scope and method

In scope: the full agent-facing tool inventory (graph/corpus/web/report/
retrieval/session+quest ops), the teaching stack as normative spec, the
string-coercion spec with write-back, status=gate parity (1:1, both
directions), refusal-locates, subagent restricted-tool profiles, budget
enforcement at the tool boundary, and the constraint-catalog extension.

Out of scope, each with destination (§11): tool IMPLEMENTATION and the
gem (implementation arc, entry 0 = gems); loop mechanics (I04 — the
harness wraps, the loop drives); phase contracts, prompts, gate wiring,
stop rules, the never-reportless finisher (ENTRY 6); tripwire enforcement
(ENTRY 7); app wiring, storage-layer query objects, SSE/UI (ENTRY 8).

Method: every surface law in this document is either (a) a frozen fixture
text under `artifacts/fixtures/` (machine-parsed by `check-fixtures.sh`),
or (b) a row in the constraint-catalog extension (§9) with exactly one
PRIMARY enforcement point. Every number carries its PoC citation. tart's
`lib/tart/tools/graph.rb` is the ergonomics REFERENCE (D1: cited, never
imported); adopt/diverge is recorded per feature, with reasons.

The fixture format is LAW (I05 Specification): `## <tool_name>` header;
`### canonical` with the exact canonical call in a fenced block; one
`### refusal: <class_id>` section per refusal class, each with EXACTLY
ONE `REFUSAL:` line (verbatim, single line, inside a fenced block) + an
`EVIDENCE:` line citing the PoC source (file + §) or
`EVIDENCE: schema-law (<named constraint/view>)` for schema-refused
classes. The checker parses this format — no freeform.

## 2. Tool inventory (R-047)

One tool per operation (D2: small sharp tools). tart's single `graph`
tool dispatched on an `op` key; kquest makes the tool NAME the operation —
the `op`-key defect classes die structurally: quest 2's class b (`unknown
op nil`, 38 refusals, one assistant message with 5 op-less calls) and the
invented-op class (`unknown op "frontier_list"`, 7) have no surface left
to fail on (`arc-run-20261121T-quest2-failure-taxonomy.md` §1 classes b,
i). The unknown-tool path (harness fixture) replaces them and teaches
with the session's legal list.

The parseable inventory (the `tools` block; `check-fixtures.sh` verifies
1:1 with fixture files, both directions):

```tools
graph node_add
graph node_set
graph node_get
graph edge_add
graph frontier_add
graph frontier_close
graph status
graph search
graph list
graph paths
graph mass
graph neighbors
corpus source_read
corpus source_grep
corpus source_list
web web_search
web web_fetch
retrieval retrieve
report report_draft
report report_bind
session harness
session quest_status
session subagent_spawn
session subagent_status
```

All tools are tenancy-scoped by construction (I01 DR-01: every domain row
carries user_id; the session binds user/quest; no tool takes a user
parameter). All tools are quest-scoped for graph/corpus/report reads and
writes; `retrieve` is user-scoped (per-user retrieval legs, I03 H-SCOPE)
with optional quest scoping. Every mutating tool runs its mutation + the
`tool_calls` audit row + the transcript append in ONE transaction (DR-10;
I01 §3.15, I04 E-AUDIT).

| group | tool | role | law |
|---|---|---|---|
| graph | node_add | fused creation: claim, evidence, or evidence+claims atomically (`supports_new`); runs the dedup candidate check; stamps urns | L1/L5/L6, R-036, DR-02/DR-07 |
| graph | node_set | field updates on one node (flat or under `fields`); null deletes optionals | L5, DR-03 |
| graph | node_get | one node by K-alias or urn, with in/out edges | L15 |
| graph | edge_add | ordered typed edge: `derives_from` (claim→claim) | L2, R-047 |
| graph | frontier_add | pose a claim on the scored queue (need, uncertainty, relevance) | L4 |
| graph | frontier_close | close an OPEN entry; refuses closure regressions | L4/L6 |
| graph | status | the gate dashboard: exactly the parity fields (§5) | L6, R-051 |
| graph | search | substring match over node text, capped; refuses id-probes | L15, R-047 |
| graph | list | capped principled node listing (the cold-boot overview) | L15 |
| graph | paths | derivation descent to typed terminals (I01 Q1 shape) | L2 |
| graph | mass | frontier mass + open count (I01 `v_frontier_mass`) | L4 |
| graph | neighbors | bounded-radius cycle-safe neighborhood (I01 Q3 shape) | L15 |
| corpus | source_read | SLICED snapshot reads (offset/limit), capped per slice | L1, R-052, DR-04 |
| corpus | source_grep | grep-over-content: pattern → line numbers + context lines | R-052 |
| corpus | source_list | staged corpus listing: id, title, role, size, chunk/embed state | L15, R-052 |
| web | web_search | query the web; result carries the budget echo | L9, R-052 |
| web | web_fetch | fetch + save: registers source + quest membership in the same transaction (auto-indexing); refuses re-fetches | L1/L9, R-052 |
| retrieval | retrieve | hybrid dense+FTS search (RRF, K=60) over chunks/claims/needs; NO model parameter, ever | R-054, I03 G-REG |
| report | report_draft | structured sectioned authoring on the session's draft version; inline ordinals `[^n]` only | R-053, I02 §7 |
| report | report_bind | the deterministic binding pass + body hash scan + standing flip (finalization) | R-053, I02 §9 |
| session | harness | the ToolHarness dispatch contract: unknown-tool, write-guard, tool deadline (I04 FM-12/FM-16/FM-04 texts frozen HERE) | I04 |
| session | quest_status | quest/phase/writer/budget lines — the agent's self-orientation + budget visibility | L9, R-051 |
| session | subagent_spawn | spawn a profile-restricted child run over a disjoint band; returns immediately | I04 DR-08/DR-10 |
| session | subagent_status | poll a run by id against the run registry | I04 FM-20 |

Quest lifecycle ops (pause, archive) are OPERATOR console surface, not
agent tools (I04 §5.4; ENTRY 8 wires the console). The agent sees quest
state through `quest_status`; steering reaches a quest only through pause
(D5). Phase completion is ENTRY 6's contract; no tool flips phase state.

## 3. The teaching stack as normative spec (R-048)

The seven teaching hunks that cut the medical arc 330+ → 24, plus the
container unification and the coercion layer, are SPEC here — each element
below is normative, with its frozen carrier.

### 3.1 Canonical calls in descriptions

Every tool's registered description opens with the CANONICAL CALL — the
copy-shape example the model imitates before its first call
(`arc-run-20261121T-quest2-teaching-patch.md` §preflight 2, hunk 1: the
DESCRIPTION patch covers BOTH glm's shape-nesting and qwen's
serialization classes "because it shows canonical shapes pre-call"). The
fixture `### canonical` blocks are exactly what the description carries.
Two load-bearing shapes, frozen:

- **claim**: `{"label":"claim","text":"…","terminal":{"type":"primary-empirical","basis":"…"}}`
  — terminal is an OBJECT with basis INSIDE it.
- **evidence (fused, the default)**:
  `{"label":"evidence","src":"C13","span":"…","reading":"…","supports_new":[{"text":"…"}]}`
  — `supports_new` is an ARRAY of field objects; the fused form creates
  evidence + its claims + their edges in ONE atomic call (span proven
  before any write; failure creates nothing). The PoC's claim-side fusion
  refusal taught the wrong direction for three sessions
  (`2026-11-17-descent-observation.md` §incident A); the fused form lives
  EVIDENCE-SIDE, and the claim-side refusal names that inverse (fixture
  `fused-direction`).

### 3.2 The refusal dialect (DR-01)

Structure of every frozen refusal, one line:
`<RULE-ID>: <what was violated> — <the legal alternative / canonical
form>`. Rule-id first (grep-able, census-able over `tool_calls.error_class`),
violation named, alternative named (I04 DR-09: refusals and caps NAME the
legal alternative). Where shape is the issue, the refusal carries the
copy-shape example. No scolding, no bare type checks: quest 2's pre-
teaching refusals (`supports_new must be a non-empty array of field
objects`, 287 times, class a) named the rule but not the fix
(`arc-run-20261121T-quest2-failure-taxonomy.md` §1 class a + §3 — "bare
type checks… no canonical shape, no hint that the caller passed a
JSON-encoded string").

### 3.3 Flat keys + ONE container name (R-050, DR-03)

Field values arrive FLAT at the top level (every key outside the tool's
reserved set is a field value) or nested under `fields:` — one container
name per concept. tart's `set:`/`fields:` split was a shared-repo defect
generator (taxonomy §shared-repo harness defect: quest-2's class-d
`fields` variant was exactly this confusion); the unification commit
(83f1362, `arc-run-20261121T-quest2-teaching-patch.md` §CONTAINER
UNIFICATION LAYER: probes P1–P6 green, `/set:` occurrences → 0) is adopted
wholesale. A key supplied both flat and under `fields:` must carry the
same value (collision refusal, probe P5).

### 3.4 Stray-hints (the frozen map)

The retry-2 layer: on `unknown-field` refusals, append where the stray
key belongs (`arc-run-20261121T-quest2-teaching-patch.md` §preflight 2,
hunk 4; quest-3's dominant classes recovered on first correction):

| stray key | hint (frozen) |
|---|---|
| `basis`, `type` | basis/type belong INSIDE terminal: {"type":…,"basis":…} |
| `derives_from` | derives_from is a CLAIM field / edge_add from,to — evidence carries src/span/reading |
| `text` | text is a CLAIM field; evidence carries src/span/reading instead |
| `label` | label is a TOP-LEVEL key of the call, never a field value |
| `src` | src is an EVIDENCE field; claims carry text/terminal |

### 3.5 Legal-fields lists

Every `unknown-field` refusal ends with the label's legal fields
(`legal fields: text, terminal` / `legal fields: src, span, reading`) —
the composed refusal at `arc-run-20261121T-quest2-teaching-patch.md`
§adoption datum fired all three layers in one line and the agent echoed
the wording 3× afterward (self-teaching visible).

### 3.6 Refusal recipes

Two recipes are frozen verbatim in fixtures because the PoC measured them
winning: **frontier re-add** (hunk 5: glm's 319-refusal storm with a
290-burst went to ~0 once the refusal carried the queue recipe — taxonomy
§1 class f contrast + teaching-patch §2 hunk 5) and **create-the-claim-
first** (the twice-re-made evidence-first fumble,
`2026-11-17-arc-decompose-review.md` §Q6.1; the recipe is I11-proven —
descent-observation §positive findings).

### 3.7 Burst law

Graph mutations ONE at a time; on a SHAPE refusal, fix that call before
re-issuing anything else. The PoC's burst multiplier made single mistakes
expensive: up to 8 identical refusals in one parallel batch, 34
multi-width bursts for class a alone (taxonomy §1). SKILL-side law text is
ENTRY 6's; the TOOL-side halves adopted here: the gem's batch semantics
(isolate a raising `execute` to that call's error result; results append
in call order — I04 §2.4) mean one bad call never poisons its batch, and
every refusal in a burst carries the same teaching text, so the first
result the model reads is the fix.

### 3.8 Span-copy discipline (L1)

`span` is VERBATIM, byte-for-byte from the slice just read — never
retyped, never re-flowed across lines. The tool PROVES byte-presence
against the immutable snapshot blob at the call (L1's tool-time
enforcement point, I01 §5.1); a re-flowed span is refused unanchored and
the refusal LOCATES it (§6). SKILL-side law text is ENTRY 6's; the
tool-side proof and the locating refusal are this iteration's.

### 3.9 Success-side teaching notes (frozen)

Teaching does not live only in refusals — the PoC's advisory answers are
adopted as contract (frozen texts; the implementation arc tests them):

- **bare note** on a claim created satisfying nothing:
  `(satisfies nothing — add terminal, derives_from, or frontier_add before the phase gate)`
  (tart `graph.rb:995`; the answer-begins-with-alias convention with it).
- **unreferenced note** on a claim created with no evidence:
  `(unreferenced — claims need ≥1 evidence node before the phase gate)`
  (the K37 killer made visible at creation;
  `2026-11-17-descent-observation.md` §incident C fix shape).
- **coercion note** on a coerced success:
  `(coerced <what> — the tool-call layer stringified a complex value; nest it under fields: to avoid)`
  (§4).
- **dedup candidates note** on claim creation with near-dup hits:
  `dedup candidates: [K<m> (near_dup, cosine 0.82)] — attach evidence to the existing claim or reword if genuinely distinct; nothing is auto-merged`
  (§7.2).
- **budget echo** on every web result:
  `web_calls=<used>/<cap>` (§7.1).
- **cap-continuation note** on every capped listing:
  `(capped at <n> rows — resume with after:"<last-id>"; ordering is principled, never shuffled)`
  (L15: "what the agent never saw" is measurable, never silent).

### 3.10 The evidence (numbers with citations)

| claim | number | source |
|---|---|---|
| teaching patch effect, medical arc | 330+ GRAPH_INVALID → 24 total | teaching-patch §preflight 2 |
| quest 2 refusal load | 664 GRAPH_INVALID / 6,683 tool results ≈ 10% (84% of 789 errors) | taxonomy §cost |
| top serialization class | class a: 287 refusals, 90 sessions, max 8-wide burst | taxonomy §1 |
| container split as defect generator | class d: 45 refusals (`fields`/`basis`/`source` strays) | taxonomy §1 + §shared-repo harness defect |
| frontier re-add storm (glm) vs trickle (qwen) | 319 (290-burst) vs 27 | taxonomy §notable contrast |
| burst multiplier | 34 multi-width bursts for class a alone | taxonomy §1 |
| wall/retry cost | ≈8.6h of the ~41h run in killed-or-waiting states | taxonomy §cost |
| first post-patch datum | 15 tool messages, 0 GRAPH_INVALID (vs ~10% baseline) | teaching-patch §first failure-count datum |

## 4. String coercion with write-back (R-049, DR-02)

**The defect class** (live evidence, three consecutive calls,
`arc-run-20261121T-quest2-teaching-patch.md` §class evidence): the
provider tool-call layer stringifies TOP-LEVEL complex values — content
perfectly formed, type wrong; the model correctly diagnoses its own
emitter ("maybe the harness is converting the array parameter into a
string") and cannot stop it. Refusing provably-correct content burns
turns (3 burns ≈ 50 s + 3 calls in the live sequence).

**The boundary rule**: parse ONCE at each complex-type parameter
boundary — only Strings whose stripped form starts `{`/`[` AND parse;
`JSON::ParserError` leaves the value untouched and the refusal voice
unchanged. Every downstream invariant (nested rules, canonical dedup,
urns, exclude, endpoints) validates the PARSED value.

**The write-back law (the cold-verifier bomb)**: the PARSED value is what
the call STORES — at every storage site (node creation, fused entries,
node_set writes). tart's first coercion layer validated a parsed COPY at
`check_value` and stored the original String; a claim created with a
stringified `terminal` then SUCCEEDED, planted the raw string, and the
trusted tier's boundary check died LATE (`bad terminal type` at the next
phase launch) — the recorded live-risk note 1, later fixed by the
write-back at the storage boundary (current `graph.rb` `coerce_field_value`,
with the phase-117 regression note in-source). kquest's equivalent
late-death would be the typed-terminal CHECKs refusing at write with a
message about a value the model never sent, or the phase gate dying at a
boundary — both fabrication-adjacent audit pollution. Write-back is
therefore CONTRACT, not implementation detail: coerce-for-validation-
only is forbidden (T-COERCE, §9).

**Validator asymmetry consumed** (`2026-11-17-descent-observation.md`):
the fused-form DIRECTION is fixed structurally — evidence-side fusion is
the canonical (§3.1); claim-side `supports_new` is refused with the
inverse named (fixture `fused-direction`); split authoring orders are
never silently reassembled. And status=gate (§5) kills the other half of
that incident: no rule the agent cannot see.

**The test set**: tart's T1–T6 battery (teaching-patch §T1–T6: stringified
fused array → coerced + taught + stored parsed; stringified edge array;
stringified object field; garbage refused; plain-string edge refused;
JSON-looking string-rule value stored verbatim) is the implementation
arc's contract test set for the coercion layer, re-expressed against the
I01 schema (terminal/`supports_new`/`supports`).

## 5. Status = gate, 1:1 both directions (R-051, L6)

One view family, no second validator: `status` SELECTs from the same law
views the phase gate sweeps (`v_claim_closure`, `v_decompose_remaining`,
`v_frontier_mass`, `v_frontier_open`, `v_unmined_sources` — I01 §3.17).
The PoC's asymmetric validator killed a run the model could not see
coming (status said `violations=0 bare_claims=0`; the driver's check
additionally enforced referencing and stopped the quest on K37 —
`2026-11-17-descent-observation.md` §incident C). kquest law: every gate
rule is a status field; every status field is a parity row (no
decorative fields — each remaining field names its consuming rule).

The parity table (`check-coverage.sh` verifies 1:1 BOTH directions
against the frozen canonical result lines in the `status` and
`quest_status` fixtures):

```parity
gate: closure_contract (L6: terminal ∨ derives_from ∨ open frontier) | status.bare_claims
gate: referencing (L6: every claim named by ≥1 evidence) | status.unreferenced
gate: terminal_exclusivity (claim carries terminal XOR derivations) | status.dual_arm_claims
gate: decompose_completeness (no unmined citable sources; v_unmined_sources) | status.decompose_remaining
gate: frontier_open_state (L4 queue; v_frontier_open) | status.frontier_open
gate: frontier_mass_floor (L4 mass; ENTRY 6 transition law reads v_frontier_mass) | status.frontier_mass
rule: cold_boot_reconstruction (L7; I04 §5.1 step 4 store-backed reads) | status.claims
rule: cold_boot_reconstruction (L7; I04 §5.1 step 4 store-backed reads) | status.evidence
gate: web_call_budget (L9; quests.web_call_budget) | quest_status.web_calls
gate: token_budget (L9; quests.token_budget) | quest_status.tokens
gate: spend_budget (L9; quests.spend_budget_usd) | quest_status.spend_usd
gate: one_active_writer (D5; I04 FM-16 launch gate + write-guard) | quest_status.writer
rule: quest_state_lifecycle (I02 lifecycle table; pause door D5) | quest_status.quest
rule: phase_terminal_contract (ENTRY 6 phase contract; loop turn boundary) | quest_status.phase
```

Three-zeros = the gate's closure verdict: `bare_claims=0
unreferenced=0 dual_arm_claims=0` (all three over `v_claim_closure`);
the decompose phase additionally requires `decompose_remaining=0`. Gate
WIRING (which phase checks which zero, transition law, mass floors) is
ENTRY 6; the parity LAW (the fields above are exactly what any gate may
sweep) is fixed here.

## 6. Refusal-locates (R-055)

A refusal that names the rule but not the location produced the PoC's
only unrecoverable class: three unanchored-span refusals, ~10.5 min, the
model shrinking the span monotonically without ever seeing WHERE the
break sat (`2026-11-17-arc-decompose-review.md` §Q3). The locating
refusals (frozen in fixtures; I11-proven "every one recovered in a single
retry, including a curly-vs-straight-quote catch" — descent-observation
§positive findings):

- **unanchored-span**: nearest whitespace-normalized fragments + the line
  junction (`span joins lines 10–11; single-line fragments: "…"`)
  — converts the unrecoverable class into a one-shot fix.
- **unknown-node**: the create-the-claim-first recipe + resolve-by-id-or-
  urn.
- **unknown-source**: `source_list shows the staged corpus` + resolve by
  C-id or `kb:src:` urn.
- **duplicate-label**: NAMES the existing claim (`K<n>`) — locate is
  dedup: the model attaches evidence instead of re-adding.
- **span-beyond-snapshot / offset-beyond-eof**: name the snapshot's actual
  bounds and the legal range.

## 7. Corpus, web, and budget at the boundary (R-052)

### 7.1 Budget enforcement (L9, I04 DR-09 as ruled)

Web calls are counted AT THE TOOL (each web call is a tool call — exact
counting, no rollup lag); token/spend budgets are turn-boundary rollups
over the ledger (I04 FM-17 — used counters are derived, never stored).
Lines are per-line config `{scope, value, mode ∈ advisory|hard}`, ADVISORY
BY DEFAULT (I04 DR-09 ruling). Advisory lines TEACH: every web tool
result appends the frozen echo `web_calls=<used>/<cap>` and
`quest_status` shows all three budget lines. Hard lines REFUSE: the
frozen `budget-exceeded` refusal (web fixtures) fires before the wire
when the web-call line is hard and exhausted; token/spend hard lines
refuse at turn boundaries (loop-side, I04). A budget stop routes to the
never-reportless finisher (ENTRY 6): every organic PoC budget/cap exit
was reportless (`arc-run-20261122T-quest2-arc-summary.md` §Organic
exits were all reportless).

### 7.2 Auto-indexing — no frozen-index trap (the C13 wall)

`web_fetch` with `save:true` writes the snapshot blob, the `sources` row
(content-addressed URN), AND the `quest_sources` membership row in one
transaction — the source is anchorable in the SAME session. The PoC's
structural descent-killer was a corpus table frozen at quest init: 5
parallel evidence calls against a correctly hand-registered C13 all
refused `unknown corpus source C13`, no re-ingest path existed, and the
model's belief that a later session could anchor was FALSE
(`2026-11-17-descent-observation.md` §incident B). kquest removes the
hand-registration shape entirely: the agent never writes corpus state;
fetch+save IS the registration. `duplicate-fetch` refuses re-fetching a
saved URL (fetch-once per user, D3) and teaches `source_read`.

### 7.3 Sliced reads + grep (the 78% lesson)

Corpus snapshots are read SLICED: `source_read` takes `offset`/`limit`,
capped per slice (`read_slice_cap_chars`, default 8,000 — I04 FM-22);
above the cap or without slices, the frozen `non-sliced-read` refusal
names the slice form. Whole-file reads were 78% of a 79,677-token final
context while the entire graph loop was 5.1%
(`2026-11-17-arc-decompose-review.md` §Q5) — "the graph surface is not
the context problem; corpus ingestion via full-file `read`s is".
`source_grep` locates the passage first (line numbers + context lines)
— the grep-then-slice pattern (`muse-20261119T-i17-tool-wedge.md`: the
grep tool class B wedge is why grep carries a deadline and the
pattern-required teaching). Retrieval-first: `retrieve` before any read
(I04 §7; the agent never names an embedding model — R-054, fixture
`model-name-refused`).

## 8. Subagent restricted-tool profiles (I04 DR-08's normative shape)

Profiles are config-data restrictions of the registered surface; the
profile IS the registration (an unregistered tool call lands in the
unknown-tool path, which teaches with the profile's legal list). No
recursion: no profile contains `subagent_spawn`. Day-one profiles:

- **`survey`** (read-only, the band-survey worker): status, mass,
  node_get, neighbors, search, list, paths, source_read, source_grep,
  source_list, retrieve. NO mutation tools, NO web tools, NO report
  tools, NO spawn/status, NO quest_status (writer state is the parent's
  concern). Exactly the shape the PoC's five-worker band-survey needed
  (K1–199 … K750–821, digests merged by the parent —
  `arc-run-20261122T-quest2-arc-summary.md` §3 item 7).
- **`operator`** (interactive attach): the FULL surface — same tools,
  same constraints, same audit as the orchestrator (L13); the
  restriction profile is empty by design; one-writer is enforced by the
  launch gate + write-guard (I04 DR-05/FM-16), not by the profile.

Spawn discipline is consumed from I04 (DR-10/FM-20): spawn returns
immediately; verification is a separate `subagent_status` call keyed by
run id; bands are checked at spawn (union = target range, pairwise
disjoint — fixture `band-overlap`).

## 9. Constraint-catalog EXTENSION — surface laws

Every new law → exactly one PRIMARY enforcement point. TOOL = a frozen
fixture text (this iteration's contract); LOOP = an I04 engine component;
SCHEMA/GATE = prior law (cited). Ids continue the I01 §5.1 / I02 §10 /
I03 §11 catalog (T- prefix).

| id | invariant | primary enforcement | implementing artifact / destination |
|---|---|---|---|
| T-CALL | every refusal names the violated rule AND the legal alternative; every tool description opens with its canonical call | TOOL: fixture texts are contract (check-fixtures parses them) | fixtures/**; DR-01 |
| T-COERCE | complex-typed args parse once at the boundary (only parseable `{`/`[` strings); the PARSED value is stored at every storage site (write-back); coerced successes carry the teach note | TOOL: node_add/node_set/edge boundaries | §4; DR-02; T1–T6 = implementation-arc tests |
| T-NAME | one container name per concept (`fields`); flat/nested collision refused | TOOL: field partition | DR-03 |
| T-SLICE | corpus reads are sliced by default; above the slice cap the refusal names the offset/limit form | TOOL: source_read cap | DR-04; ContextBudgeter accounting I04 |
| T-DEDUP | claim creation runs the exact+near candidate check and surfaces hub-mapped candidates; nothing auto-merged | TOOL: node_add (I03 family d is the executable contract) | DR-07; thresholds = config |
| T-NOMODEL | retrieval/query surfaces take no model; the registry is the only model path | TOOL: retrieve refuses the model field (I03 G-REG at the tool) | DR-08 |
| T-GATE | status fields = gate rules, 1:1 both directions; no invisible rule, no decorative field | TOOL+GATE share the law views (v_claim_closure family) | §5 parity block; check-coverage.sh; wiring ENTRY 6 |
| T-CAP | every listing/result surface carries a principled order + a cap that teaches continuation | TOOL: list/search/neighbors/paths/source_list caps | DR-09 |
| T-LOCATE | refusals locate: unanchored spans name fragments+junction; unknown ids name the recipe; duplicates name the existing node | TOOL: fixture texts | R-055; §6 |
| T-PROFILE | subagent surfaces are named profile restrictions; no recursion | LOOP+TOOL: registration IS the restriction (harness) | §8; DR-06 |
| T-BUDGET | web calls counted at the tool; advisory lines teach (frozen echo), hard lines refuse at the tool/turn boundary | TOOL (web echo/refusal) + LOOP (turn boundaries) | §7.1; I04 DR-09/FM-17 |
| T-AUDIT | every tool call lands a verbatim tool_calls row in the SAME transaction as the mutation; refusals included | TOOL: harness wraps execute | DR-10; I01 §3.15; I04 E-AUDIT |

## 10. Traceability — R-047–R-055 (machine-checked by check-coverage.sh)

| R-item | Status | Carried by | Destination |
|---|---|---|---|
| R-047 | DESIGNED | §2 inventory + `tools` block + 24 fixtures (canonical calls + frozen refusal texts, the ten named graph ops all present); node_add fused forms; DR-05/DR-09 | implementation contract tests → implementation arc |
| R-048 | DESIGNED | §3 teaching stack (canonical calls §3.1, dialect §3.2, flat-keys/one container §3.3, stray-hints §3.4, legal-fields §3.5, recipes §3.6, burst law §3.7, span-copy §3.8, frozen notes §3.9, numbers §3.10); DR-01/DR-03 | SKILL-side law text → ENTRY 6 |
| R-049 | DESIGNED | §4 coercion spec (boundary rule, write-back law, cold-verifier bomb citation, T1–T6 test set); DR-02 | implementation-arc tests |
| R-050 | DESIGNED | §3.3 one container name (`fields`); collision refusal (fixture `flat-nested-collision` on node_set); DR-03 | — |
| R-051 | DESIGNED | §5 parity table (1:1 both directions, machine-checked); v_claim_closure one-view law; three-zeros | gate wiring → ENTRY 6 |
| R-052 | DESIGNED | §7 corpus/web ops (source_read sliced + non-sliced-read refusal, source_grep, source_list; web_search/web_fetch budget + auto-indexing + duplicate-fetch); DR-04 | never-reportless finisher → ENTRY 6 |
| R-053 | DESIGNED | §2 report ops (report_draft structured sectioning + section-too-large "write in sections" + version-frozen; report_bind binding pass + ordinal/import/hash refusals); frozen on I02 §7/§9 law | re-synthesis routing → ENTRY 6 |
| R-054 | DESIGNED | §7.3 retrieve (hybrid, RRF; NO model parameter); fixture `model-name-refused`; I03 G-REG/D-DUP consumed; DR-08 | BM25 slot adoption → operator ruling with data (I03 DR-09) |
| R-055 | DESIGNED | §6 refusal-locates (unanchored fragments+junction, unknown-node recipe, unknown-source, duplicate-label names the node); DR-01 | — |

## 11. Deferrals and handoffs

| Concern | Destination |
|---|---|
| Tool IMPLEMENTATION (Fast::Completions::Tool subclasses), coercion layer, caps plumbing | implementation arc |
| SKILL/phase-prompt law text (burst law, span-copy, frontier queue opening, extract-as-you-read), phase contracts, gate wiring, stop rules, never-reportless finisher | ENTRY 6 |
| Tripwire predicates over refusal/error-class censuses (T-CALL's error-class ids feed them), churn/duplicate-need/storm tripwires, refusal-rate metrics | ENTRY 7 |
| Storage-layer named query objects the tools call, job/worker topology, operator console (lifecycle ops), SSE | ENTRY 8 |
| Band-survey prompt law, model routing | ENTRY 6 |
| tart subagent machinery | reference only (D1) |

## 12. Method note: what was verified vs assumed

- **Verified by reading**: every prior-law object named (constraints/views
  grepped in the I01–I03 DDL artifacts by check-fixtures.sh); every PoC
  note cited (paths exist; §-anchors quoted from the notes); tart
  graph.rb behaviors quoted from the current shared-repo source (caps at
  lines 192–195, the fused/container/coercion layers, the unknown-node
  recipe at ~line 1809); the fast-completions unknown-tool contract
  (`docs/reference/tools.md` §"no such tool").
- **Frozen as contract, not implemented**: refusal texts, canonical
  calls, notes, caps values. The implementation arc tests against them
  verbatim.
- **Assumed, not claimed**: nothing about provider emitter behavior
  beyond the recorded live evidence (the stringification defect is
  handled AT the boundary whatever the emitter does — T-COERCE is
  defensive by design).
