# I03 — retrieval: DECISIONS

Decision records for iteration I03 (retrieval), cross-referenced from
`DESIGN.md` and the artifacts. Law: BRIEF §4 D4 (embeddings day one,
modular), §3 L10 (derived-ness), D10 (spend ledger), D2 (queries behind
the storage seam); catalog §C R-028–R-037. Prior law consumed read-only:
I01 (chunks/claims/frontier, `usage_events`, tenancy), I02
(`v_canonical_claims`, DR-16 growth slot, DR-15 additive-keys precedent).
Verified facts cited from `notes/design-research-verified-facts-20261122.md`
(no re-research); PoC grounds cited from space `20261110-knowledge-builder`.

Conventions: **Status** is DECIDED or OPERATOR-RULING-NEEDED (the latter
carries **Options** + **Recommendation** for ratification). Prior-iteration
records are always qualified (I01 DR-05, I02 DR-16); bare DR numbers are
this file's own.

## DR-01 — The registry is the only model path; registry rows are global config; usage_events.model is an audit echo

**Status:** DECIDED
**Decision:** `embedding_models` is the single model authority: one row per
model DEPLOYMENT (identity `(provider, wire_name)` — the same wire model
at two providers is two rows), slug → generated-table name, dims + metric
pinned at registration, wire/batch parameters as data. It carries no
`user_id` (the I01 chunk_strategies posture: model deployments are
code-versioned config identical for all tenants). Jobs address models by
`model_id` FK; queries by registry id; the single sanctioned exception to
"no model name" is the GENERATED per-model table name itself, which is
registry-derived data. `usage_events.model` (I01) keeps storing the wire
name — it is an audit ECHO of what was called (a record for cost
forensics), never an access path; nothing joins on it to pick a model.
**Rationale:** D4 verbatim ("registry of models → registry-generated
per-model pgvector tables"); an inline model string anywhere in query text
would make A/B, retire, and re-embed generation tracking unauditable —
the registry row is the join point for "which table, which dims, which
spend rows". Global (not per-user) because model deployments are shared
infrastructure; per-user model sets would multiply identical rows and
complicate cost rollups for zero isolation benefit (credentials, the only
per-tenant concern, are references resolved app-side).
**Alternatives considered:** (a) per-user registry rows — rejected:
identical deployments duplicated per tenant, cost rollups fragment;
(b) a model-name enum in code — rejected: register/retire/A-B would be
code changes, violating R-029's data-operation law; (c) dropping
`usage_events.model` since it duplicates the registry join via
`embed_jobs` — kept: the ledger row is the CALL's own record (I01 DR-14
granularity); a failed call that never gets a job row still needs its
model string, and cost forensics should not require the job chain.

## DR-02 — One table per model (registry-generated), not a single wide table

**Status:** DECIDED
**Decision:** Each registered model gets its own generated table
`emb_<slug>` with a TYPED `vector(<dims>)` column and an hnsw index with
the metric's opclass. The table is created at registration from the
template in `schema-i03.sql` (the generator's contract) and dropped at
retire. Two concrete instantiations ship as fixtures: `emb_bge_m3_1024`
(vector(1024), the D4 first registration) and `emb_minilm_ab_384`
(vector(384), the A/B challenger).
**Rationale:** typed dims make a wrong-dimension insert a TYPE refusal
(check-constraints probe E09) — in a single wide table with
`vector(2000)` padding or untyped `vector`, wrong-dims data would be
silently pad-truncated or accepted, corrupting cosine at write time.
Per-model tables also give each model its own hnsw index (ann indexes do
not span heterogeneous metric spaces), isolate retire to one DROP, and
make cost/per-model row counts a table scan. The registry's
`table_name` column + CHECK (`emb_<slug>` derivation) keeps the mapping
honest in data.
**Alternatives considered:** (a) one wide table `embeddings(model_id,
embedding vector)` — rejected: untyped vector columns can't carry an hnsw
index per model (one index, one opclass), dims errors stop being type
errors, retire requires destructive deletes instead of a DROP; (b) one
table per TARGET family with model columns — rejected: same typing
problem, plus retire/A-B becomes column surgery; (c) storing vectors as
`float4[]`/jsonb with app-side distance — rejected: loses pgvector's
operators and ANN entirely (D4 chose pgvector deliberately); (d) pgvector
halfvec (16-bit) — a per-model registration choice the template can
substitute later (registry row gains a precision column), not a day-one
need.

## DR-03 — The generated-table contract: the template is the law; rows pin model, status, job, tenancy, and exactly one target

**Status:** DECIDED
**Decision:** The registrar emits EXACTLY the template DDL in
`schema-i03.sql` (substitutions: slug, model uuid, dims, opclass). Every
generated row pins: the model id as a CHECK LITERAL (rows cannot migrate
between models); `model_status='active'` via composite FK to
`(id, status)` (the retire gate — probe E07); the producing job
(`job_id`, tenancy-pinned — cost totality: every vector has a job);
target tenancy via three conditional composite FKs over `(id, user_id)`
(cross-user vector rows structurally impossible — probe E13); and
exactly one of chunk_id/claim_id/need_id with `target_kind` matching
(probes E10–E12). `UNIQUE NULLS NOT DISTINCT (target_kind, chunk_id,
claim_id, need_id)` makes re-embed REPLACE, never duplicate (probe E14) —
NULLS NOT DISTINCT is load-bearing (two of three target columns are NULL
on every row; default NULLS-distinct uniqueness would never collide).
`embedded_text` captures the exact wire input (DR-12).
**Rationale:** the template makes "registry rows → generated tables" a
contract, not a convention: the schema's fixture tables and the
check-constraints positive control are both hand-instantiated from it, so
the contract is executed twice in the gate battery. CHECK-literal model
pins are the schema-only way to make a generated table answerable to
exactly one registry row.
**Alternatives considered:** (a) model_id FK without the status pin —
rejected: retire could strand live vectors claiming validity; (b) a
`target_id` + `target_kind` polymorphic pair without per-target FKs —
rejected: loses tenancy pinning and write-time target existence (the I01
DR-09 rule keeps cross-table laws out, but tenancy is exactly the thing
composite FKs CAN express); (c) uniqueness on (model_id, target columns)
relying on the table being per-model — equivalent to the chosen key;
the chosen key also guards within-table duplicates if a future generation
reuses ids.

## DR-04 — Retire means gone: drain jobs, drop the table, flip the pair

**Status:** DECIDED (operator ruling 2026-11-22: **A — gone/drain/drop**)
**Ruling (operator, recorded verbatim):** "if we're retiring an embedding
model, we're unlikely to be able to generate new embeddings using it
with which to search, so keeping the table has no value."
**Decision (as designed — the ruling confirms the shipped shape):** Retire is an op SEQUENCE with a schema-enforced
outcome: drain or cancel pending/running jobs → DROP the generated table
(vectors die with the model) → set `status='retired'` + `retired_at`
(pair law, probe E15). The generated tables' active-status pins make the
flip refuse while any vector exists (probe E07); job LEDGER rows
deliberately survive retire (plain FK, no status pin — audit history is
never delete-on-retire). The registry row survives with its table_name
for history. The seeded retired model (nomic-s1-768: failed backfill,
table absent, pair set) shows the legal terminal state.
**Rationale:** a retired model's vectors are reproducible only by
re-calling a provider that may no longer serve the model — keeping them
queryable invites silently stale similarity answers (the exact honesty
failure the ENFORCED level exists to prevent). Cost of the gone-semantics:
re-adopting the model re-embeds from scratch (L10: everything derivable
is rebuildable — embeddings derive from (target, model), so nothing is
lost that cannot be regenerated, only spend is).
**Options:** (A) retire = gone (drop table; the proposal above) —
cheapest, honest, L10-covered; (B) `frozen` status: no NEW embeds
(vector rows pin 'frozen'), vectors remain readable for A/B retention
and post-mortem dedup archaeology — costs a third status in every
generated table + registry, and stale-vector risk is mitigated only by
discipline; (C) keep vectors, no bookkeeping — rejected outright
(orphaned unregistered tables).
**Recommendation (pre-ruling):** (A) day one (matches the fixture and
schema as shipped); add (B) as an ADDITIVE status (new rows + a third
CHECK value) when a real A/B workflow asks to keep a retired leg
readable — the registry makes that a data+DDL migration, not a redesign.
**Post-ruling note:** (A) RATIFIED. (B) remains the recorded additive path
should an A/B retention workflow ever want frozen readability.
**Alternatives considered:** delete-only-in-batches retire — same
semantics as (A) with more failure modes; CASCADE from the registry row —
rejected: retire must be a deliberate op sequence (live jobs drained
first), not an accident of FK graph.

## DR-05 — Embedding targets: chunk text, claim canonical_text, frontier need-text; evidence readings EXCLUDED

**Status:** DECIDED
**Decision:** Embed exactly three text families: chunks (`chunks.text`),
claims (`claims.canonical_text` — the I01 DR-05 generated normalizer, so
the near-dup leg keys on the same normalized form the exact leg
compares), and frontier needs (`frontier_entries.need`, including CLOSED
history — re-entry comparisons read them). Agenda sources' chunks ARE
embedded (agenda is readable/retrievable by I01 law; only ANCHORING is
refused there). Evidence readings are structurally excluded:
`ck_emb_<slug>_kind` admits only the three kinds (probe E10).
**Rationale:** each embedded family has a named consumer: chunk vectors
feed corpus retrieval (the dense leg), claim vectors feed
dedup-by-construction and the hub's near-dup seam (R-036), need vectors
feed semantic internal resolution and mechanical relevance (R-037).
Evidence READINGS have no consumer: retrieval enters evidence through
the span text, which lives in the snapshot blob and its chunks; the
reading is an interpretation label attached to a span, not a retrieval
key. Embedding all readings would roughly double corpus embed spend
(E:K ≈ 2:1, the PoC metabolism — R-018) with no query family consuming
the vectors. Exclusion at the CHECK level (not convention) means a
future "readings are retrievable" change is a schema decision, not a
quiet data addition.
**Alternatives considered:** (a) embed readings too, for a future
contradiction-search surface — rejected: no consumer; revisit as an
additive fourth kind with a named query family if contradiction search
ever wants them; (b) embed claims' RAW text instead of canonical_text —
rejected: dedup must see what the exact leg compares (same-text-different-
whitespace would split across the two legs); (c) embed quest topics —
rejected for the same no-consumer reason (topic questions are the QUERY
side of mechanical relevance, embedded per query, not stored corpus).

## DR-06 — Embed spend accounting: one usage row per completed embed job; corpus-level backfill attribution

**Status:** DECIDED (operator ruling 2026-11-22: **A — per-quest jobs**)
**Ruling (operator, recorded verbatim — REVISIT TRIGGER for ENTRY 7):**
"per quest jobs, but for the record, i don't really like this either.
supported embeddings models are really the house's decision, which is
why B exists as an option, but a 'house quest' is pure jank borne of too
strict requirements. the only reason we're going with A right now is
because the cost tracking isn't tied to consequences — it's purely
reporting, and in that regard, it has value. If I know that Quest Foo
costs $20 to re-embed and Quest Bar costs $0.40, that's useful
information. If we were using this to enforce budgets/quotas, we'd
have to revisit the design here."
**Decision (amended at ratification to enforce A in schema):**
Every COMPLETED embed job links exactly ONE `usage_events` row of kind
'embedding' — schema law in BOTH directions: `ck_embed_jobs_usage_kind`
(probe E08, usage⇒embed∧complete) and `ck_embed_jobs_complete_spend`
(probe E21, complete∧embed⇒usage — added at judge F1, which proved the
completed⇒spend direction was claimed but unenforced), tenancy-pinned
through the additive `uq_usage_events_id_user` (probe E18);
`input_tokens` = the job's batch totals; cost from the provider, NULL for local models (the I01 DR-14
class). Failed/partial jobs carry NO usage link — partial spend is
reconciled once, at completion (a failed-and-billed attempt still gets
its own ledger row per I01 DR-14; it just isn't the JOB's linked total).
Because the I01 usage chain session→phase→quest→user is TOTAL, every
embed job must run inside a session of a phase of a quest — so embed jobs
carry `quest_id`/`phase_id`, and under the ruled option A ALL embed jobs
are quest-scoped by law (`ck_embed_jobs_scope`, probe E22 — tightened at
ratification from claim/need-only to every embed job). The corpus-level
BACKFILL is no longer an open question: a re-chunk/re-embed generation or
model swap runs as explicit per-quest jobs (one job per (strategy,
quest)), so every spend row lands on the quest whose corpus was
re-embedded.
**Rationale:** embedding spend is real spend (D10) and corpus maintenance
is spend without a natural quest — the two laws (chain totality, honest
attribution) pull against each other for backfills. Day one the tension
is dissolved by making chunk-family embed jobs quest-scoped in practice
(their idem keys name strategy + quest; the fixture's re-embed generation
attributes to the quest whose corpus it re-embeds), but a future
cross-quest corpus sweep needs a ruling.
**Options:** (A) every embed job names a triggering quest; backfills
split per quest (one job per (strategy, quest)) — chain stays total, no
schema change; costs job-row fan-out for corpus-wide sweeps (the fixture
does this today); (B) a user-level "corpus maintenance" pseudo-quest per
user (house quest) that owns backfill jobs and their spend — one row of
bookkeeping per user, spend visibly separated from research spend; needs
an I01-visible convention (a quest with a marker) rather than a schema
change; (C) relax the chain: allow usage_events with NULL quest — an I01
AMENDMENT (usage_events.quest_id NOT NULL → nullable + pairing laws);
rejected by the proposal because it breaks the D10 chain that budget
rollups read.
**Recommendation (pre-ruling):** (A) now (it is what the fixture
exercises; honest attribution per quest, zero schema motion). If
corpus-wide sweeps become a real workflow, adopt (B) as a convention +
config; (C) only if (B) proves too heavy, and then as a formal I01
amendment decision record.
**Post-ruling note:** (A) RATIFIED and now SCHEMA-ENFORCED
(`ck_embed_jobs_scope` refuses quest-less embed jobs — probe E22). Per
the operator's ruling text above: attribution REOPENS if cost tracking
ever gains CONSEQUENCES (budgets/quotas) — ENTRY 7's budget design must
cite this record; option (B) house-quest remains the recorded fallback,
option (C) remains a formal I01 amendment.
**Alternatives considered:** cost-NULL housekeeping rows outside the
ledger — rejected: D10 says every embedding call is accounted; hiding
maintenance spend is the opposite of the ledger's purpose.

## DR-07 — fast-embeddings consumer contract: pure OpenAI embeddings wire, batch discipline from the registry row

**Status:** DECIDED
**Decision:** fast-embeddings (implementation arc entry 0, D9; the
fast-llm `completions` gem's "fast & focused" posture applied to
`POST {base}/embeddings`) speaks the OpenAI embeddings wire PURE:
`{model, input: [texts...]}` → `{data: [{embedding, index}...]}`, no
streaming (the wire has none), no dialects, no extensions ever (D4).
kquest consumes it ONLY through the registry: request `model` = the
registry row's `wire_name`, `base` = the row's `endpoint`, credentials
resolved from `api_key_ref` app-side (a reference like
`env:OPENROUTER_API_KEY`, never a secret — ENTRY 8/R-079). Batch
discipline is the registry row's data: the job runner slices by
`batch_max_texts` and enforces `input_max_chars` admission (a text over
the cap is split or refused BEFORE the call — never silently truncated
by the provider). Retries/timeouts are the agent loop's retry classes
(ENTRY 4, R-039); the call site records spend (R-046). The gem never
sees kquest concepts (targets, jobs, scoping).
**Rationale:** the verified-facts note §1 concluded the OpenAI shape is
the de-facto interchange and it is dense-only; extending the wire for
sparse would fork every provider. The registry columns make batch policy
per-deployment data (providers differ in batch caps), so the gem stays
wire-pure and kquest stays model-agnostic.
**Alternatives considered:** (a) a dialects map like completions —
rejected: the embeddings wire has no meaningful provider dialects to
carry (verified-facts §1); (b) batch policy in gem config — rejected:
two consumers of one deployment would drift; the registry is the single
config point (D4); (c) kquest calling providers directly — rejected:
loses the one transport with retry/telemetry economics shared with
completions.

## DR-08 — Lexical-leg substrate: a GENERATED tsvector column + GIN on chunks

**Status:** DECIDED
**Decision:** The FTS leg reads `chunks.search_tsv`, a GENERATED ALWAYS
tsvector column (`to_tsvector('english', text)`) added additively by
schema-i03.sql, with a GIN index. English is the day-one config (fixture
corpus is English); the config choice is data, swappable per deployment.
**Rationale:** GENERATED makes the lexemes derive from chunk text at
write time — no writer can drift them (L10), and the leg's law is visible
IN the DDL rather than in every query's expression. GIN serves
tsquery recall (the verified-facts §2 posture: PG FTS matching
infrastructure is the day-one lexical leg; its ranking weakness is why
DR-09's slot exists).
**Alternatives considered:** (a) an expression index
`USING gin (to_tsvector('english', text))` with no column — touches
chunks not at all, but then the leg's normalization lives in the index
expression and every query must repeat the exact expression to hit the
index (drift-prone at the query seam); (b) a shadow `chunk_fts` table —
a second writable copy of derived data (drift risk + join burden), the
thing L10 exists to avoid; (c) `tsvector` as a plain column written by
the chunk job — a writer could forget or diverge from text. Chosen: the
generated column — one definition, zero writers, index-served.
The additive column is a touch on a frozen TABLE but not on a frozen
FILE (see DR-11).

## DR-09 — BM25 slot disposition: defer-with-FTS day one; slot designed, engine data-gated

**Status:** DECIDED
**Decision:** Day one the lexical leg is PG FTS (ts_rank). BM25 (IDF + TF
saturation + length normalization) is a DESIGNATED SLOT with its query
shape pinned: the lexical leg EMITS (doc_id, rank); swapping in BM25
changes how rank is computed INSIDE the leg; RRF consumes ranks only, so
fusion does not change (DESIGN §7.1). Two occupants, chosen when data
justifies — the adoption trigger: lexical-leg misses on identifier-style
queries (author-year citations, venues, percentages — kquest's query
profile per the verified-facts note §2) showing up in ENTRY 7 relevance
metrics. Occupant 1: ParadeDB `pg_search` (real BM25 + hybrid in one
index, v0.27.0, PG 15–18; AGPL-3.0 — acceptable under
licenses-as-threats for private self-host; ops costs:
shared_preload_libraries + background worker, one ParadeDB index per
table, standby REINDEX-after-promotion caveats). Occupant 2: hand-rolled
SQL BM25 — GIN/tsvector recall, then BM25-rerank a few hundred candidates
from a `ts_stat`-derived term-stats table (IDF maintained on corpus
change); no extension, no preload, no license question; corpus-stats
maintenance is ours.
**Rationale:** ts_rank has no corpus statistics — common terms rank like
rare terms — and BM25 is the IR baseline specifically strong on exactly
kquest's rare-term/identifier queries; but adopting an engine before
there is a measured miss is speculative ops cost (pg_search's preload +
worker) or speculative maintenance (a stats table nobody has validated).
The D4 ruling already designated the slot; this record pins the swap
surface so the eventual decision is local to one leg.
**Alternatives considered:** (a) adopt pg_search now — rejected:
AGPL acceptable but ops costs (preload, per-table index, standby caveats)
unjustified without a measured FTS failure; (b) adopt hand-rolled BM25
now — rejected: builds the stats-maintenance surface before evidence;
(c) external engines (Elasticsearch, Meilisearch, RediSearch) — rejected
in the verified-facts note §2 (ratified): index-sync burden is what
choosing Postgres was meant to avoid.

## DR-10 — Chunking default and re-chunk generations: para-800 day one; re-chunk = new strategy version; embed jobs carry the strategy for chunk generations

**Status:** DECIDED
**Decision:** The day-one default chunking strategy is paragraph-aligned
para-800 (target 800 chars, no overlap — the I01 fixture default, R-005
config row). Re-chunk NEVER mutates chunks in place: it is a NEW
chunk_strategies version row + new chunk rows; old generations are
retained (I01 §3.5/§3.6 law; the fixture's para-400 coexistence).
Chunk-family EMBED jobs carry `strategy_id` so each strategy generation's
vectors are a coherent set, and their idem keys name (model, strategy,
scope) — a re-chunk generation therefore composes as: new strategy → new
chunk job → new embed job, with old vectors retained until their model
retires or a cleanup pass drops them. Embedding is READ-ONLY over chunks
(`chunks.text` consumed exactly as stored): the L1 verbatim+offsets law
is preserved end-to-end because nothing downstream rewrites chunk text
or offsets.
**Rationale:** chunks are derived from (blob, strategy) — L10 says
anything derivable is rebuildable, and a generation model (new version
row, old retained) is what makes "rebuildable" non-destructive and
auditable. Carrying the strategy on chunk-family embed jobs is what lets
a re-embed target exactly one generation (a wrong pairing is refused —
probe E19) and lets the rebuild-diff duty (DR-12) compare old vs new
inputs per generation.
**Alternatives considered:** (a) overlap in the default strategy — a
tunable the config row carries (`overlap_chars`); 0 day one because
verbatim-substring chunks with overlap create near-duplicate CHUNK
vectors that crowd the dense leg's top-k; revisit with real-model
retrieval quality data (ENTRY 5/7); (b) deleting old-generation chunks on
re-chunk — rejected: orphans evidence-adjacent history and violates the
retention posture; (c) one embeddings-table-per-strategy — rejected:
strategy is a scoping column/idem-key component, not a typing dimension
(DR-02 typed per MODEL, which is where typing matters).

## DR-11 — Additive touches on frozen I01 tables: four composite UNIQUE keys + the generated search_tsv column

**Status:** DECIDED
**Decision:** schema-i03.sql adds, strictly additively (no column
semantic changes, nothing removed): `uq_chunks_id_user`,
`uq_claims_id_user`, `uq_frontier_id_user` (target-tenancy composite-FK
targets for the generated tables — probe E13), `uq_usage_events_id_user`
(spend-tenancy target — probe E18), and the `chunks.search_tsv`
GENERATED column + GIN index (DR-08). These ship in the I03 schema file;
the I01 FILES are untouched (byte-identical — check-coverage proves both
prior directories clean).
**Rationale:** the I02 DR-15 precedent: prior-law tables gain
composite-FK targets via the LATER schema file precisely because the
earlier file is frozen. I02 DR-15 anticipated this class of addition and
DROPPED `claims (id, user_id)` as then-unneeded; I03 needs it back — the
generated tables pin claim tenancy, so the key returns here (recorded,
not silently). The generated column is a larger class of touch than a
unique key (it adds a stored attribute), justified because GENERATED
STORED columns cannot drift from their derivation (L10) and the
alternative (expression index, DR-08a) pushes the law into every query.
**Alternatives considered:** (a) propose an I01 amendment adding these
keys to schema.sql — rejected for this iteration: the additive pattern
achieves the schema law without touching ratified files; folding the keys
into I01's file is a cosmetic consolidation the driver/operator can do
at any later ratification; (b) skip tenancy pinning, filter user_id at
query time only — rejected: cross-user vector rows would be writable
(the probe E13 exists because the write path matters, not just reads);
(c) expression index instead of the column (see DR-08).

## DR-12 — embedded_text: capture the exact wire input; audit + the rebuild-diff duty

**Status:** DECIDED
**Decision:** Every generated-table row stores `embedded_text`, the
EXACT text sent over the wire for that vector. It is derived state
(reproducible from the target row) captured at write time for two duties:
(1) audit — the usage ledger records tokens, not text; debugging a wrong
embedding without its input is guesswork; (2) rebuild diffing — a
re-embed/re-chunk generation byte-compares old vs new `embedded_text` to
DETECT TARGET-TEXT DRIFT (a target whose text changed after embedding
stale-vectors the corpus; the diff makes staleness visible instead of
silent). The seed self-verifies both directions: every vector re-derives
byte-identically from its `embedded_text`, and every `embedded_text`
byte-matches its target's CURRENT text.
**Rationale:** L10 tension acknowledged: storing derivable text
duplicates the target's content. Resolved by the duties — the copy is
the WRITE-TIME WITNESS of what was embedded, which the target row cannot
provide after the fact (claims' canonical_text is stable, but chunk
re-chunk generations and future target edits make "what was actually
embedded" a question only the witness row answers). Storage cost is the
text length per vector row, bounded by `input_max_chars`.
**Alternatives considered:** (a) no capture — rejected: loses the drift
detector and the audit trail (a rebuild job could not tell regeneration
from re-embedding); (b) a content hash instead of full text — cheaper,
but useless for debugging and the drift report loses the diff itself;
(c) capturing input_tokens/offsets instead — same problems as (b).

## DR-13 — Dedup-by-construction: a tool-side check the model cannot skip; candidates mapped onto hub entries

**Status:** DECIDED
**Decision:** Claim creation runs a TOOL-SIDE candidate check BEFORE the
write (the executable contract is queries-i03.sql family d): an exact
leg (canonical-text byte-equality against the user's claims — the I02
M1 surface) and a near leg (cosine neighbors in the registry's claim
vectors, user-scoped, top-k under a floor), both legs per-user (the hub
is per-user, D3/D6). The check RETURNS candidates mapped onto
`v_canonical_claims` entries with `match_kind ∈ {exact, near_dup}` —
near_dup rows are the I02 DR-16 growth slot's data: surfaced to the
creating tool, adjudicated in quests, NEVER auto-merged (the hub is
derived; nothing is adopted, nothing refused). Thresholds (top-k=5,
similarity floor) are TOOL CONFIG, calibrated against the real registry
model in ENTRY 5 (the fixture's 0.6 floor is methodology-limited,
DR-15).
**Rationale:** the PoC's dedup search-cap law ("one search per candidate
claim; fragment sweeps forbidden") was a SKILL law that synthesis phases
blew through ~8× (arc-run-20261122T-llm-trading-midarc §4: 78
single-word searches, 0 mutations, the law in context from the boot read
and never re-read; the §2 phase-16 SCATTER storm and the quest-2
failure-taxonomy census are the earlier evidence class) — when a law is
provably unable to serve the goal, models self-rescue by switching
source. The structural fix is a check the model cannot skip because the
TOOL runs it (retiring the cap law, R-036's "replaces
model-discipline search-first"). The candidate result carries hub
identity so near-dup adjudication reads the same view the exact leg
compares — one dedup surface, two legs.
**Alternatives considered:** (a) keep the search-cap SKILL law and add
teaching — the PoC evidence says teaching alone fails; (b) block writes
on near-dup (auto-refuse) — rejected: near-dup is a GROWTH signal
(divergent wording of a real finding is often the frontier working),
blocking would re-create the merge-gate load I02 DR-16 ruled out;
(c) exact-leg only (no vectors) — rejected: the near-dup family is the
entire reason embeddings landed day one (D4, I02 DR-16's "embeddings
era").

## DR-14 — Mechanical relevance: topic questions vs need-text; the question carrier is ENTRY 6's phase contract

**Status:** DECIDED
**Decision:** Relevance for mass (R-037, muse-20261120T-i20) is computed,
not self-assigned: each OPEN need-text is embedded (one query-vector per
need via the query seam) and scored against the quest's TOPIC QUESTIONS
(best-question alignment = min cosine distance over the question set —
"crude-but-constant beats refined-but-drifting for a stop-law currency").
The question set is the DECOMPOSE OUTPUT (the operator's staged
questions — in the fixture corpus they live in the agenda note s5); the
CARRIER SHAPE is `phases.result` jsonb on the decompose phase, whose
schema is ENTRY 6's phase contract (R-063) — the fixture stands the
questions in a temp table and marks the carrier as the deferral.
Consumption: the ENTRY 6 stop law may take `mechanical_relevance ×
uncertainty` in place of the self-assigned product when configured — a
currency swap that is config, not schema (frontier's `relevance` column
stays as the PRIOR; the mechanical score is the audited override).
**Rationale:** the topic is written down (the operator's questions); a
constant mechanical scale with zero self-assignment is exactly what a
stop-law currency needs (the I20 muse argument, cited verbatim in
DESIGN §10). Deferring the carrier schema to ENTRY 6 keeps I03 from
inventing phase-contract jsonb shapes that ENTRY 6 owns.
**Alternatives considered:** (a) a questions TABLE now — rejected: one
more migration surface for a carrier ENTRY 6 will spec anyway
(phases.result is already jsonb, already pinned by composite FKs);
(b) embedding the need against the quest TOPIC string only — weaker
anchor than the decomposed questions (the topic is one sentence; the
questions are the actual agenda); (c) replacing frontier.relevance in
schema — rejected: prior + audited override beats destructive swap
(history and comparability survive).

## DR-15 — Fixture-vector methodology: deterministic sha256 hashing-trick vectors; proves the machinery, NEVER model quality

**Status:** DECIDED
**Decision:** Every vector in seed-i03.sql (and every query vector in
queries-i03.sql) is SYNTHETIC and deterministic: a hashing-trick encoder
(`pg_temp.synth_vec`) tokenizes text (lowercase, ≥3-char tokens minus a
stoplist that drops shared fixture boilerplate), gives each token a
pseudo-random direction derived from sha256(token ‖ block), sums and
normalizes. Similar fixture texts share vocabulary ⇒ nearby vectors;
identical texts ⇒ byte-identical vectors (cosine distance exactly 0 —
asserted, family a4); disjoint vocabularies ⇒ near-orthogonal. The seed
SELF-VERIFIES the determinism claim: every stored vector re-derives
byte-identically from its `embedded_text` (executed, not asserted in
prose), and every `embedded_text` byte-matches its target's current
text.
**Rationale:** the prototype must run offline, byte-reproducibly, and
with KNOWN ground truth (which fixture is "near" which) so the query
families can assert ordering facts — a real embedding model gives none
of those. Hashing gives all three plus the similar-texts-nearby property
the five families need.
**Limits, stated honestly:** this is a LEXICAL encoder with no semantic
component — no synonymy, no paraphrase beyond shared tokens; similarity
MAGNITUDES are not calibrated to any real embedding model; the dedup
floor (0.6) and family thresholds are fixture-tuned constants, NOT
transferable policy. What it proves: the query machinery — pgvector
operators, hnsw-backed search paths, RRF fusion arithmetic, per-user
scoping, dedup candidate generation and ordering, mechanical-relevance
alignment, and every schema constraint. What it does NOT prove: anything
about a real model's quality. Threshold calibration against the real
registry model (bge-m3) is ENTRY 5's job (DR-13; catalog N4).
**Alternatives considered:** (a) recorded vectors from a real model —
rejected: not reproducible from artifacts, no ground truth, and silently
implies quality claims; (b) random vectors keyed by row id — rejected:
destroys the similar-text property the dedup/relevance families assert;
(c) counter-based vectors (one-hot per text) — exact-match only; no
gradation for near-dup ordering.

## DR-16 — hnsw index parameters: pgvector build defaults; ef_search is query-seam config

**Status:** DECIDED
**Decision:** Generated tables build their hnsw index with pgvector's
defaults (m=16, ef_construction=64); `ef_search` (default 40) is a
QUERY-TIME setting owned by the query seam (the named query objects of
D2/ENTRY 8), not schema. Recall can be traded per query via `SET LOCAL`
inside the query object when data justifies it.
**Rationale:** build-time parameters are a per-deployment tuning surface
with real maintenance cost (reindex); pgvector's defaults are the
documented safe point, and at kquest's early corpus scale (10³–10⁶
chunks) defaults are not the bottleneck — ranking quality is. Keeping
ef_search at the seam means ENTRY 8's query objects can tune recall per
query family without touching generated DDL (which is registry-driven).
**Alternatives considered:** (a) tuning m/ef_construction per metric in
the template — speculative before load data exists; the registry could
grow index-parameter columns later as an additive change;
(b) ivfflat instead of hnsw — rejected: hnsw has no build-time
list-generation parameter to get wrong (ivfflat's `lists` depends on
corpus size at build time, exactly the thing re-embed generations churn);
(c) brute-force exact scan day one — viable at fixture scale but leaves
the ANN path unproven, and the prototype exists to prove the machinery
that will run in production.

---

## Operator-ruling summary

| DR | Flag | Question for ratification |
|---|---|---|
| DR-04 | DECIDED (operator 2026-11-22) | Retire = gone/drain/drop (A); frozen-readable (B) stays the recorded additive path |
| DR-06 | DECIDED (operator 2026-11-22) | Per-quest jobs (A), schema-enforced (probe E22); REVISIT TRIGGER: reopens if budgets/quotas are ever enforced (ENTRY 7 must cite) |

## Proposed prior-law amendments

None. I01 and I02 files are byte-identical after this run (check-coverage
verifies both directories against the worktree HEAD). The additive keys
and the generated column on frozen tables ship in schema-i03.sql under
the I02 DR-15 precedent (DR-11 records the reasoning); folding them into
the I01 file remains available to the operator as a cosmetic
consolidation at any later ratification, proposed here as a note, not a
patch: if desired, move the four ALTER … ADD UNIQUE statements and the
search_tsv column block from schema-i03.sql into a future I01 amendment
commit — no semantic change would be involved.
