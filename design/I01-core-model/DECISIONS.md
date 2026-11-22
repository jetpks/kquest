# I01 — core-model: DECISIONS

Numbered decision records for the core-model design. Status is DECIDED or
OPERATOR-RULING-NEEDED (options + recommendation attached; the artifact
ships the recommendation as working default until ruled). Every record names
alternatives considered. Structure is machine-checked by
`artifacts/check-coverage.sh`.

Grounds-mandated records: URL canonicalization rules (DR-03), URN scheme
parameters (DR-02, DR-06), canonical_text normalization (DR-05), frontier
mass persistence shape (DR-10), usage-ledger granularity (DR-14) — plus
records discovered mid-design (DR-07, DR-08, DR-12, DR-17, DR-18, DR-20).

---

## DR-01 — Tenancy: explicit user_id on every domain row, coherence by composite FK

**Status:** DECIDED
**Decision:** Every domain table carries `user_id NOT NULL`. Coherence
(the row's user equals its owner's user) is enforced by composite FKs to
`(id, user_id)` unique keys: quest-scoped tables pin `(quest_id, user_id) →
quests(id, user_id)`; evidence additionally pins the source; tool_calls pin
the session; usage_events pin session→phase→quest→user. Config/registry
tables (`chunk_strategies`, later the embedding registry) are global and
carry no user_id — they are code-versioned config, not tenant domain data.
**Rationale:** R-001 phrases tenancy as a LAW on every domain row; making
it a real schema law (not a convention) means cross-tenant wiring is
structurally impossible (probe C14) and the future access/visibility layer
(R-025) has one column to key on everywhere. Composite FKs are the only
pure-schema mechanism.
**Alternatives considered:** (a) derive user via join through quest, no
user_id column — rejected: the law becomes unenforceable at write time and
row-level scoping needs joins everywhere; (b) PostgreSQL RLS policies —
rejected for the core model: policies are runtime configuration, not
portable DDL law, and hide the tenancy from the schema reader; (c)
user_id only on top-level tables with trigger checks — rejected: triggers
are the DR-09-rejected mechanism class.

## DR-02 — Source URN: preimage construction and truncation pinned

**Status:** DECIDED
**Decision:** `kb:src:` + first 10 base58 (Bitcoin alphabet) characters of
`sha256( utf8(canonical_url) || utf8(lowercase-hex(sha256(snapshot_bytes))) )`.
No separator between the parts; the digest suffix is fixed-length (64 hex
chars), so preimage ambiguity would require a canonical_url ending in hex
of matching shape — harmless under SHA-256 (distinct preimages map to
distinct pseudorandom digests; a contrived collision is an identity, not a
confusion). Truncation at 10 base58 chars ≈ 58 bits — collision-safe at any
realistic corpus scale. Format enforced by `ck_sources_urn_format`; per-user
dedup by `uq_sources_user_urn`. Not parameterized: constants live in code;
a scheme change is a new namespace, not a config knob.
**Rationale:** the URN note's open question "hash/truncation specifics"
answered with one construction the whole system can re-derive; the seed
re-derives every URN through this exact algorithm in SQL (pure-SQL base58,
verified against a python reference) and fails the load on mismatch.
**Worked test vector** (normative):
`canonical_url = "https://example.org/a"`, snapshot text `"hello\n"` →
`snapshot_sha256 = 5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03`,
preimage `"https://example.org/a5891b5…6fbe03"` →
`kb:src:HQVXDAv8PP`.
**Alternatives considered:** (a) separator byte between URL and digest —
no separator is safe given fixed suffix length, and no separator char is
illegal everywhere in URLs; (b) Crockford base32 (case-insensitive
ergonomics) — +2 chars, no consumer needs it; (c) full digest (no
truncation) — unusable in prose; (d) parameterized length — configuration
surface for zero benefit.

## DR-03 — URL canonicalization rules for canonical_url

**Status:** OPERATOR-RULING-NEEDED
**Decision:** ship Option A (conservative + tracking-param strip) as the
working default; `sources.url` preserves the URL as fetched so no
information is lost and any later rule can re-derive from the row.
**Options:**
- **A — conservative + tracking strip (recommended).** Lowercase scheme and
  host; drop default port (:80/:443); drop fragment; percent-encoding
  normalization (decode unreserved, uppercase hex for reserved); remove
  dot-segments; sort query parameters; strip a fixed tracking-param list
  (`utm_*`, `fbclid`, `gclid`, `msclkid`, `mc_cid`, `mc_eid`, `ref`,
  `ref_src` — list is config, not code). NO www-stripping, NO http→https
  rewriting, NO wholesale query removal.
- **B — aggressive identity normalization.** A plus www→apex and http→https
  folding. More dedup (same page fetched via both schemes collapses) at the
  cost of false merges when a site actually serves different content per
  scheme/host-form.
- **C — no normalization.** url = canonical_url; URNs differ per fetch URL
  variant; dedup burden moves entirely to retrieval.
**Recommendation:** A. The failure mode of B (silent identity merge of
distinct content) violates the anchoring discipline for a dedup win that
matters mostly for crawl-scale corpora, not user-scale; C gives up the
"same snapshot ⇒ same ID everywhere" property the hub depends on. The seed
demonstrates A (url carries `?utm_source=newsletter`, canonical_url does
not).
**Rationale:** canonical_url feeds the content-addressed URN (DR-02), so
its rules decide when two fetches collapse to one source identity; that is
an operator-visible policy choice about false-merge risk versus dedup
yield, not an implementation detail — hence the ruling request. Shipping a
working default keeps every later artifact buildable while the question is
open.
**Alternatives considered:** the options above ARE the considered
alternatives; ruled dimensions are www/scheme folding and tracking-list
contents.

## DR-04 — Blob keys: stored columns, GENERATED from the content hash

**Status:** DECIDED
**Decision:** `sources.snapshot_blob_key`/`raw_blob_key` are STORED
generated columns: `'blobs/sha256/' || substr(sha256_hex, 1, 2) || '/' ||
sha256_hex` (content-addressed, sharded prefix; filesystem via Shrine day
one, S3-class later = config swap, D8). L10 satisfied by construction: the
key is a pure function of the hash the row already carries, so keys can
never drift and are rebuildable. Session transcripts use positional keys
(`sessions/<uuid>/transcript.jsonl`) — they are append-only logs, not
content-addressed evidence.
**Rationale:** R-002/AC7 name blob keys on sources; deriving them in DDL
keeps the stored explicit key AND the derived-ness law — no separate
"key template" state to keep in sync.
**Alternatives considered:** (a) no key column, resolve via a template at
the storage seam — rejected: AC7 wants keys on sources, and a template is
hidden state; (b) fully random keys — loses content addressing and
rebuildability; (c) sha-prefixed flat keys without sharding — fine at
fixture scale, directory-entry limits at S3/filesystem scale.

## DR-05 — canonical_text: PoC normalization as a GENERATED column

**Status:** DECIDED
**Decision:** `claims.canonical_text` = `btrim(regexp_replace(normalize(
text, NFC), '[ \t\n\r\f\v]+', ' ', 'g'), ' \t\n\r\f\v')` — exactly the PoC
schema's `normalize: nfc, collapse_ascii_ws_runs: true, strip: true`
(bracket class is ASCII-only: verified that NBSP U+00A0 does NOT match in
this database, so only ASCII whitespace collapses). Uniqueness
(`uq_claims_quest_canonical`) is enforced on the generated value, so raw
whitespace variants collide at write time.
**Rationale:** normalization is law, and law lives in the schema where
expressible — an app-side normalizer can drift or be bypassed; a generated
column cannot.
**Alternatives considered:** (a) app-computed canonical_text stored as a
plain column — bypassable, two writers can disagree; (b) normalization at
query time (functional index) — can't enforce uniqueness on read paths
cleanly and hides the rule; (c) full Unicode whitespace folding — would
DEVIATE from the proven PoC semantics (NBSP-sensitivity retained).

## DR-06 — Claim URN: quest-salted content hash

**Status:** DECIDED
**Decision:** `kb:claim:` + first 10 base58 chars of
`sha256( utf8(quest_uuid_string) || utf8(canonical_text) )`. Deterministic,
cold-boot stable, no coordination; the same canonical claim in two quests
gets two distinct URNs until the hub merge (which mints/re-addresses —
ENTRY 2). Claim-to-claim citation RENDERING is ENTRY 2 (R-026) territory.
**Rationale:** D3 makes the quest the hermetic build unit pre-merge;
quest-salting makes the quest-scope of claim identity explicit in the URN
itself instead of relying on the referencing context.
**Worked test vector (normative):** quest
`b0000000-0000-4000-8000-000000000001`, canonical text "A t-statistic is
the ratio of an estimated coefficient to its standard error." →
`kb:claim:J9KJrkkdQj`. The seed re-derives every claim URN through this
algorithm and fails on mismatch.
**Alternatives considered:** (a) unsalted global content hash — pre-wires
the hub's global identity before merge semantics exist and would collide
two quests' identical claims into a shared URN while rows remain
quest-scoped; (b) PoC-style human slugs (`urn:kb:<quest>:claim:<slug>`) —
readable but unstable under text edits and locale-limited; aliasing is a
tool-layer concern (ENTRY 5), not an identity concern.

## DR-07 — Citable-only anchoring via the anchorable discriminator FK

**Status:** DECIDED
**Decision:** `sources.anchorable` is a generated boolean
(`role = 'citable'`) participating in composite UNIQUE keys; `evidence`
carries `source_anchorable` CHECK-forced TRUE and references sources
through `(source_id, user_id, source_anchorable, snapshot_char_count)` —
so an agenda source simply has no matching unique key row and the FK
refuses (probes C02, C24). `conflict_sources` uses the 3-column variant.
The decompose-gate exclusion lives in `v_unmined_sources` SQL
(`role = 'citable'`).
**Rationale:** R-003 demands agenda exclusion "by schema, not surgery"
(the C43 lesson, bitten twice). The discriminator-FK pattern is the
standard pure-SQL conditional foreign key: write-time, zero triggers,
zero runtime policy.
**Alternatives considered:** (a) partial unique index + FK to it —
PostgreSQL does not allow FKs to partial indexes; (b) inheritance/partition
per role — splits one concept across two tables; (c) BEFORE INSERT
trigger — rejected mechanism class (see DR-09); (d) tool-time only —
precisely the "surgery" R-003 forbids.

## DR-08 — Pinned snapshot_char_count makes offset bounds write-time law

**Status:** DECIDED
**Decision:** `evidence` and `chunks` carry `snapshot_char_count`, pinned
by composite FK to the source's value; CHECKs then enforce
`span_end ≤ snapshot_char_count` (and chunk equivalents) at write time
(probes C03, C17). Byte-exact substring equality stays tool-time (blob
bytes live in object storage).
**Rationale:** L1's offsets law has a cheap schema half (bounds) and an
expensive half (byte proof against blob bytes). Pushing the cheap half
into DDL means out-of-range offsets can never exist even briefly; the
pinned copy cannot drift because the FK rejects mismatched values.
**Alternatives considered:** (a) plain FK + no pinned copy, bounds checked
tool-time — offsets could exceed the snapshot with the schema watching;
(b) storing snapshot text in PG for CHECK-able equality — violates D8
(unbounded content → blobs); (c) triggers re-reading sources — rejected
mechanism class.

## DR-09 — Cross-table laws stay out of the DDL: tool-time + phase-gate

**Status:** DECIDED
**Decision:** The PoC laws that need to see OTHER rows — closure
satisfy_one (terminal ∨ derives_from ∨ open frontier), terminal XOR
derives_from, evidence edge_min (≥1 edge), conflicts ≥2 floor — are NOT
expressed as triggers/constraint triggers. They live in the constraint
catalog with two enforcement points: tool-time (the fused atomic graph ops
refuse at the call — L5) and phase-gate (boundary sweeps over
`v_claim_closure` and Q1V).
**Rationale:** PostgreSQL CHECKs cannot contain subqueries; constraint
triggers CAN but reintroduce hidden write-path magic the PoC deliberately
moved away from (write-time refusal at a named tool surface, refusal text
as spec). The catalog keeps every law visible with a named enforcement
point and destination artifact; the DDL keeps only laws a single row can
prove about itself (plus FK/UNIQUE across rows).
**Alternatives considered:** (a) DEFERRABLE constraint triggers for each
law — works mechanically, rejected for transparency and refusal-quality
(a trigger error is not a refusal that teaches); (b) app-level sweep only,
no tool-time refusal — the PoC's I08 lesson: boundary-only discovery is
the failure mode, not the fix.

## DR-10 — Frontier persistence: one table + retained history; mass snapshotted on phases

**Status:** DECIDED
**Decision:** Single `frontier_entries` table; closed rows never deleted
(they carry `closed_at` + `closure_type`); per-phase mass is persisted as
`phases.frontier_open`/`phases.frontier_mass` boundary snapshot columns
(paired by `ck_phases_mass_pair`), not as a separate history table. Live
mass reads from `v_frontier_mass`.
**Rationale:** phase rows are already an append-only, per-round timeline —
attaching the boundary snapshot to them gives mass history, decay queries,
and floor checks with zero new tables and zero deletion paths; a separate
`frontier_mass_history` table would duplicate the phase timeline's key
space. (I20's shadow instrumentation becomes structural.)
**Alternatives considered:** (a) separate mass-history table — rejected as
duplicate timeline; (b) recompute mass from frontier history at query time
only — leaves no durable per-phase record of what the transition law
actually saw (mass floors must be auditable against the state that drove
them); (c) mass on the frontier rows themselves (entry-level snapshotting)
— wrong grain, mass is a queue property.

## DR-11 — Frontier ordering: the PoC order, owned by a view, matched by an index

**Status:** DECIDED
**Decision:** The one listing order is `uncertainty*relevance DESC,
claim_seq ASC, entry_id ASC` (PoC `order: uncertainty*relevance DESC,
claim ASC`, tiebreak made total). `v_frontier_open` owns it; partial index
`idx_frontier_open_order` matches it. Callers (tool layer) apply caps.
**Rationale:** L15 demands principled ordering on every listing surface —
principled means defined once; a view + matching index keeps every reader
consistent and the order explainable in one place.
**Alternatives considered:** (a) order in each caller's query — drift
factory; (b) rank column maintained on write — derived data (L10 violation)
plus write-path contention; (c) float mass — u,r are integers 1..5; integer
mass is exact, ordered, and sum-safe.

## DR-12 — One OPEN frontier entry per claim (schema); one ACTIVE WRITER per quest (deferred to ENTRY 4)

**Status:** DECIDED
**Decision:** Two different uniqueness laws, two different homes. (1)
Re-posing a currently-open claim is refused by partial unique index
`uq_frontier_open_per_claim` (`WHERE state = 'open'`) — kills the PoC
class-f re-add storm at the storage layer while leaving closed history and
future re-entry rounds free. (2) One-active-writer-per-quest (D5) is NOT a
schema constraint here: a partial unique on unfinished sessions would also
refuse the cold-boot successor session (killed sessions leave unfinished
rows until reaped — L7 conflict). It is enforced by the orchestrator's
launch path + reaper, specified in ENTRY 4 (R-043).
**Rationale:** the two laws look symmetric but fail differently under kill
semantics; the schema takes the one that cannot be violated legitimately.
**Alternatives considered:** (a) partial unique index on sessions
`WHERE ended_at IS NULL` — blocks cold-boot resume (L7 violation, the
whole reason it is rejected); (b) advisory locks — runtime state, not
durable law; invisible to ops.

## DR-13 — Sessions always belong to a phase attempt (phase_id NOT NULL)

**Status:** DECIDED
**Decision:** `sessions.phase_id` is NOT NULL and pinned to the quest by
composite FK. Work that precedes the first "real" phase (interactive
briefing, topic decomposition) runs as decompose round 1, attempt 1.
**Rationale:** D10's ledger chain session→phase→quest→user must be TOTAL —
a nullable phase would punch a hole in cost attribution exactly for the
human-in-the-loop sessions that are most interesting to attribute.
**Alternatives considered:** (a) nullable phase_id with NULL-propagating
ledger rows — cost rollups silently lose the briefing; (b) a synthetic
"phase 0" kind — more enum surface for the same effect; decompose round 1
already is the initiation phase in the ENTRY 6 shape.

## DR-14 — Usage ledger granularity: one row per API call

**Status:** DECIDED
**Decision:** `usage_events` gets exactly one row per LLM/embedding API
call (not per request batch, not per token bucket, not per session): kind,
model, input_tokens, output_tokens, cost_usd nullable (NULL = local/free;
seeded example present). Retries and failed-but-billed attempts each get
their own row. The chain columns (session, phase, quest, user) are pinned
by composite FKs; budget checks are rollups over this table (L10: used
counters are never stored).
**Rationale:** the call is the atomic billing event every provider reports;
any coarser grain loses the retry/failure economics ENTRY 7's closure-cost
metrics need; any finer grain (per-chunk) is provider-invisible.
**Alternatives considered:** (a) per-session aggregates — loses retry
economics and model swaps mid-session; (b) per-request rows with token
arrays — nested data nobody queries without unnesting anyway; (c) also
storing cumulative spend on quests — derived (L10) and racy under
concurrent sessions.

## DR-15 — UUID primary keys + per-quest claim ordinal (quest_seq)

**Status:** DECIDED
**Decision:** uuid PKs (`gen_random_uuid()`) everywhere; claims additionally
carry `quest_seq` (dense per-quest ordinal, UNIQUE) — the K-alias source
and the frontier ordering's `claim ASC` key. Alias minting and any
model-facing "K12" rendering are tool-layer concerns (ENTRY 5).
**Rationale:** uuids are graft/merge-safe (no renumbering when ENTRY 2
copies or merges across quests — the PoC's per-store integer ids forced
re-keying on `--from-corpus`) and insertable without coordination;
quest_seq keeps the human/agent-facing ordering stable and cheap.
**Alternatives considered:** (a) bigserial ids — global sequence contention
and renumbering pain at graft time; (b) random base58 short ids as PK —
same graft benefits as uuid with worse index locality and no native type;
(c) urn AS primary key — hashes make terrible clustered keys and identity
would then be mutable if the scheme ever versions.

## DR-16 — Edges as two typed tables with position ordering

**Status:** DECIDED
**Decision:** `evidence_edges` (evidence→claim, relation
supports/contradicts, ordered by position) and `claim_derivations`
(claim→claim, ordered by position) — separate tables, no polymorphic edge
table. Positions are unique per (source node, relation) —
`uq_evidence_edges_positions`, `uq_claim_derivations_positions` — mirroring
the PoC's ordered `edge_out` arrays.
**Rationale:** the two edge classes have different endpoints, different
laws (edge_min applies to evidence only; exclusion applies to derivations
only), and different canonical queries; one table would need nullable
endpoints + CHECK labyrinths and still couldn't express either law cleanly.
**Alternatives considered:** (a) single `edges` table with kind + nullable
from/to — weaker typing, laws become CHECK soup; (b) adjacency arrays on
the node rows (PoC shape) — set semantics awkward in SQL, position
updates rewrite rows, and cross-row FK integrity disappears; (c) JSONB
edge lists — unqueryable by the canonical queries without unnesting
everything.

## DR-17 — Conflicts: junction table for sources; ≥2 floor at tool-time

**Status:** DECIDED
**Decision:** `conflict_sources` junction (PK `(conflict_id, source_id)`
gives distinctness + FK integrity; agenda sources refused via the
citable-only discriminator FK). The ≥2 floor is enforced by the
conflict-creation path (detector-owned tool code), because SQL cannot
count children in a CHECK, and sweep-checked at phase boundaries.
**Rationale:** R-010 says "≥2 distinct by construction" — the construction
is code; the schema keeps what rows exist honest (FKs, uniqueness, roles)
and the floor lives where the construction lives.
**Alternatives considered:** (a) `source_ids uuid[]` array with a
cardinality CHECK — loses referential integrity (no array FKs) and
distinctness needs non-CHECK-able logic anyway; (b) constraint trigger
counting children — rejected mechanism class (DR-09); (c) denormalized
source_count column + CHECK ≥2 — drifts, and CHECK can't prove it equals
the junction.

## DR-18 — quest_sources: quest corpus membership is an explicit junction

**Status:** DECIDED (discovered mid-design)
**Decision:** A quest's corpus is the explicit `quest_sources` set (staged
seeds, agenda docs, quest fetches, from_corpus inheritance). The decompose
gate (`v_unmined_sources`/`v_decompose_remaining`) is defined over it.
**Rationale:** D3/D6 make sources per-USER, not per-quest — without
membership, "unmined sources" is undefined (a user's whole library?) and
corpus inheritance (R-021) has nothing to copy. The C43 agenda-exclusion
lesson also lands here: the gate filters role inside the view.
**Alternatives considered:** (a) quest-scoped sources (PoC shape) —
contradicts D3 fetch-once-per-user sharing; (b) derive membership from
evidence citations — unmined sources would be invisible to the gate that
exists to mine them; (c) a jsonb source list on quests — no FK integrity.

## DR-19 — Enumerations as text + CHECK IN (…)

**Status:** DECIDED
**Decision:** Every enum (source role, terminal type, frontier state,
closure type, phase kind/state, session mode/driver, quest
state/provenance, usage kind, edge relation) is `text` with a named CHECK
constraint, not a PostgreSQL enum type.
**Rationale:** adding a value later (e.g. the I21 pooled-estimate terminal
type) is a one-line constraint swap instead of ALTER TYPE choreography;
CHECK names appear verbatim in refusal messages (probe C13 greps them);
text dumps/loads across PG versions without enum_oid hazards.
**Alternatives considered:** (a) native enum types — type changes are
painful, and labels-in-refusals are worse; (b) lookup tables with FKs —
real overhead (join per read) for closed vocabularies that change with
design iterations, not data.

## DR-20 — Metabolism constants as config defaults, carried by quests.process_config

**Status:** DECIDED
**Decision:** The measured constants (DESIGN §9) are CONFIG DEFAULTS
(implementation reads them from app config; quests may override via
`process_config` jsonb), never hard-coded thresholds in drivers. This
iteration fixes the names, values, and provenance; ENTRY 6's stop-rule
catalog (R-059) consumes them.
**Rationale:** R-018 asks for the constants as config defaults — the
measured numbers are defaults with provenance, overridable per quest as
live-rereadable steering (R-060), and the core model's job is to name and
carry them, not to enforce them.
**Alternatives considered:** (a) a `config_entries` key-value table now —
scaffolding with no consumer until ENTRY 6; (b) constants baked into DDL
(CHECKs on ratios) — metabolism is steering, not law; wrong layer.

## DR-21 — Source timestamps: fetched_at is fetch completion; published_at is page-claimed

**Status:** DECIDED
**Decision:** `fetched_at` = when the fetch completed server-side (NOT the
Exa-serve/proxy time); `published_at` = what the page claims (nullable —
often unknowable). Whether `fetched_at` (and which timestamp) rides the
human-facing footnote line is a rendering decision deferred to ENTRY 2
(R-026), which owns footnote format.
**Rationale:** two different facts that the PoC conflated in one open
question; separating them now costs nothing and prevents the ledger from
inheriting a proxy artifact as provenance.
**Alternatives considered:** (a) also store proxy-served-at — provider
detail, add when a consumer exists (ENTRY 3 pipeline); (b) published_at
NOT NULL — most pages do not state it honestly or at all; forcing it
invites fabrication.
