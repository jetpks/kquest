# I02 — cross-quest: DECISIONS

Numbered decision records for the cross-quest design. Status is DECIDED or
OPERATOR-RULING-NEEDED (options + recommendation attached; the artifact
ships the recommendation as working default until ruled). Every record names
alternatives considered. Structure is machine-checked by
`artifacts/check-coverage.sh`. I01's records are cited as "I01 DR-xx"; bare
DR-xx references are this file's.

Grounds-mandated records: cross-quest canonicalization scope (DR-02),
merge-reversibility mechanics (DR-05) — plus records discovered mid-design
(DR-09, DR-13, DR-15).

---

## DR-01 — Canonical hub ownership: per-user rows, global URN identity

**Status:** DECIDED
**Decision:** `canonical_claims` rows carry `user_id NOT NULL` exactly like
sources (I01 DR-01 posture): one hub per user, deduped within it by
`uq_canonical_claims_user_text`. The URN is the unsalted content hash of the
canonical text (DR-03), so two users' hubs CAN hold rows with the same URN
(different ids, different membership) — global identity is the URN string,
not a global row. Visibility grants (DR-14) are the only cross-user read
path, exactly as D6 phrases it for sources.
**Rationale:** D6 makes sharing an access layer over owner-scoped rows; a
globally-owned hub table would be the first non-tenant domain table in the
system and would force an authz model before ENTRY 8 exists. Per-user rows
keep the tenancy law uniform (every domain row answers "whose is this"),
while the shared URN keeps "same claim" meaningful across users the moment
a grant makes it visible.
**Alternatives considered:** (a) global canonical claims owned by nobody —
breaks the tenancy law and makes the first merge a global mutation any user
could propose; (b) per-user URNs (salting the hub hash with the owner) —
destroys the cross-user "same text ⇒ same identity" property the sharing
door needs; (c) hub rows only materialized cross-user (single-user quests
keep quest-scoped claims only) — the hub must exist per-user for dedup
WITHIN a user's quests, which is the primary case (lineage, grafts).

## DR-02 — Cross-quest canonicalization scope: exact canonical-text, same-user, near-dup as slot

**Status:** OPERATOR-RULING-NEEDED
**Decision:** ship exact canonical-text matching, same-user, with near-dup
as the designated slot (working default until ruled): a quest claim merges
with a canonical claim iff their `canonical_text` values are BYTE-EQUAL
(the I01 DR-05 generated normalization — so "exact" is exact-on-normalized:
raw whitespace variants collapse in the core model before the hub ever
sees them). `match_kind='exact'`. Near-duplicates (different wording, similar meaning)
are `match_kind='near_dup'` with a similarity score — the DESIGNATED SLOT:
schema surface exists now, candidate generation lands with the embedding
registry (ENTRY 3, R-036). Merges are same-user only (M-TEN schema law);
cross-user merges are deferred behind visibility grants and need both a
ruling and ENTRY 8 authz.
**Rationale:** exactMatch is the D3 word; the frozen normalizer answers the
"normalized?" question without a second normalization to drift; near-dup
without embeddings would be a hand-rolled similarity nobody validated;
cross-user merges change the trust model (whose operator approves?) and so
are a ruling, not a default.
**Options:**
- **A — exact canonical-text only, same-user (recommended, shipped).**
  Zero false merges; every approved merge is mechanically verifiable; the
  near-dup door is designed but dark until ENTRY 3.
- **B — exact + alias tables (operator-asserted synonyms merge).** More
  recall; introduces human-asserted equivalence with no mechanical check —
  the hub stops being auditable by text equality alone.
- **C — normalized folding beyond DR-05 (casefold, punctuation strip).**
  More dedup yield; silently merges claims whose difference is load-bearing
  ("net of costs" vs "gross of costs" survives, but "US equities" vs
  "global equities" variants would not); violates the exactMatch wording.
- **Cross-user dimension:** defer (recommended — grants + authz first) vs
  allow-now (hub rows become shared objects with two-user consent surfaces
  that do not exist yet).
**Alternatives considered:** the options above ARE the considered
alternatives; the ruled dimensions are matching breadth (exact vs alias vs
folding) and merge scope (same-user vs cross-user).
**Recommendation:** A + cross-user deferred. The failure mode of B/C
(silent identity merge of distinct claims) is the same class DR-03 Option B
was rejected for in I01; the yield question can be revisited with real
embedding scores on record (ENTRY 3 gives the data to rule with).

## DR-03 — Canonical claim URN: unsalted content hash (cashing I01 DR-06's re-addressing promise)

**Status:** DECIDED
**Decision:** `kb:cclaim:` + first 10 base58 chars of
`sha256(utf8(canonical_text))` — no salt. Quest claims keep their
quest-salted URNs forever (I01 DR-06); a merge NEVER rewrites a claim URN.
"The hub re-addresses on merge" is realized as: the canonical row holds the
global identity, and `v_canonical_members` (live approved merge events) is
the address mapping. Uniqueness is per-user on both text and URN.
**Rationale:** at the hub the row IS global-within-owner, so the reason I01
DR-06 salted (two quests may hold the same canonical claim pre-merge)
disappears; an unsalted hash makes "same canonical text ⇒ same hub URN"
true for every user simultaneously — the property cross-user sharing (and
eventual cross-user merges) keys on. Re-writing quest claim URNs on merge
would break every transcript, tool_call, and citation that ever named one
(L8 audit law); membership is immutable bookkeeping instead.
**Worked test vector (normative):** canonical text "Momentum profits
persist after controlling for market beta in the fixture literature." →
`kb:cclaim:CNXkEaVj1Z` (re-derived by seed-i02 self-verification for every
canonical row; the seed run is the executable proof).
**Alternatives considered:** (a) salt with the FIRST member's quest id —
stable but arbitrary (depends on merge order) and not derivable from text
alone; (b) sequential hub ids (cclaim:1, cclaim:2) — not content-addressed,
not cold-boot stable, leaks merge order into identity; (c) rewrite quest
claim URNs on merge — rejected above (audit-breaker).

## DR-04 — Merge event model: one row per lifecycle, propose-only audit in the row

**Status:** DECIDED
**Decision:** `merge_events` holds ONE row per (quest claim, canonical
claim) lifecycle with the full timeline as columns: state (candidate →
proposed → approved | rejected; approved → reversed), justification
(nonempty, at proposal), proposed_session_id (nullable, quest-pinned),
decided_by/decided_at/decision_note, reversed_by/reversed_at/reversal_note.
Named CHECKs enforce the audit pairings (undecided rows carry no decision;
decided rows must name their operator; reversal needs its own operator and
a nonempty note); `uq_merge_events_active_per_claim` keeps one ACTIVE
lifecycle per quest claim. Forward-only transitions per row are a workflow
law at the merge ops layer (catalog M-TR, ENTRY 5).
**Rationale:** R-019 asks for what/when/which session/justification — a
single self-describing row makes every merge auditable with one SELECT and
keeps "propose-only, operator-approved" as schema law (an approved row
cannot exist without decided_by — the discipline's named example). Separate
proposal/approval/reversal tables would need joins to answer "what happened
here" and would split the state machine across three uniques.
**Alternatives considered:** (a) three event tables (proposals, decisions,
reversals) — more normalized, worse audit story, three constraint surfaces
for one lifecycle; (b) mutable state on the canonical claim side (member
list column) — loses per-member history and makes reversal a rewrite;
(c) separate reversal rows referencing the approved row — append-only
purity, but then "active" membership needs NOT EXISTS logic a partial
unique cannot express, weakening the one-active law.

## DR-05 — Merge-reversibility mechanics: state flip on the row; re-merge is a new row; zero graph mutation

**Status:** DECIDED
**Decision:** reversal = UPDATE of the event row: approved → reversed, plus
reversed_by/reversed_at/reversal_note (all three required). Membership is
the set of rows with state='approved' (`v_canonical_members`), so a
reversal drops membership WITHOUT deleting history and without touching any
quest claim or canonical row. Re-merging after reversal or rejection is a
NEW candidate row — permitted because only ACTIVE lifetimes are unique.
The canonical claim row survives reversal with empty membership (audit
value; minting history is visible).
**Rationale:** D3 says reversible; the cheapest reversibility that keeps
the audit trail intact is a state flip on the event that caused the
membership. Deleting the event would falsify history (an approval DID
happen); compensating rows (reversal events) weaken the one-active
partial-unique to a query-time convention. No graph data is copied at
merge, so none needs restoring at reversal — reversibility is trivial
BECAUSE merges are pure bookkeeping (DR-07).
**Alternatives considered:** (a) delete the approved event on reversal —
audit hole, exactly what R-019's "merge events" record exists to prevent;
(b) compensating reversal rows — one-active law degrades to a view
convention (rejected in DR-04c); (c) full two-phase merges (staging table,
apply-on-commit) — the staging IS the candidate/proposed states already.

## DR-06 — Terminal reconciliation at approval: adopt-first-member; refuse on type divergence

**Status:** OPERATOR-RULING-NEEDED
**Decision:** adopt-first-member terminals with refusal on type divergence
(working default until ruled): the canonical claim's terminal_type/basis
are adopted from its FIRST approved member. A subsequent exact member
whose terminal_type DIVERGES is refused at approval by the merge op
(cross-table law → catalog H-TERM, ENTRY 5/6). Divergent basis wording is
allowed (the type is the load-bearing part).
**Rationale:** two byte-equal claims disagreeing on their TYPED terminal is
strong evidence they are not the same claim (or one terminal is wrong) —
auto-merging would launder the disagreement into the hub silently. But
"refuse" vs "merge-and-flag" is an operator-visible policy about yield vs
safety, and terminals are new enough that no precedent exists.
**Options:**
- **A — refuse on terminal-type divergence (recommended, shipped as the
  catalog rule).** The conflict surfaces to the operator as a rejected
  proposal with the divergence named; nothing silent.
- **B — merge and keep first, flag divergence on the canonical row.** More
  yield; the hub then holds a terminal some members dispute — a
  conflict-ledger entry (I01 conflicts table is quest-scoped; hub-level
  conflicts do not exist yet and would need a home).
- **C — no terminal on canonical claims at all (hub is text+membership
  only).** Simplest; loses the hub's only typed claim about the world and
  the reconciliation question moves to every consumer.
**Recommendation:** A. It composes with the existing refusal-that-teaches
discipline (L5) and keeps the hub mechanically clean; B is the natural
upgrade path if divergence turns out common once real data flows — and the
ENTRY 7 conflict-adjudication work (R-068) would be its home.
**Alternatives considered:** the options above ARE the considered
alternatives; the ruled dimension is the approval behavior on terminal-type
divergence between byte-equal claims.

## DR-07 — Evidence reconciliation: no copies; canonical evidence is a view over members

**Status:** DECIDED
**Decision:** merges never touch evidence. A canonical claim's evidence
base is the union of its member quest claims' evidence (via
`v_canonical_members` ⋈ evidence_edges), computed where needed. Hub rows
carry no evidence columns.
**Rationale:** L11 (the graph is the asset) applies to the hub too: copying
evidence would fork the anchoring chain (which quest's evidence row is
authoritative?) and give reversibility a restoration problem (DR-05 relies
on merges being pure bookkeeping). Union-over-members keeps every span's
return address intact and makes cross-quest corroboration a query, not a
migration.
**Alternatives considered:** (a) copy member evidence to hub-owned evidence
rows — no quest to scope them to (evidence is quest-scoped by D3); a
"hub quest" is a reification with one row; (b) re-anchor evidence to the
canonical claim id — breaks the evidence_edges FK shape and the tenancy
law for cross-user members; (c) materialized union table — derived data
(L10 violation) with an invalidation problem.

## DR-08 — Quest lifecycle: audited transition ledger; stopped is resumable, complete is terminal

**Status:** DECIDED
**Decision:** `quest_lifecycle_events` records every quest.state transition
with (from, to, actor, occurred_at); the legal pair set is a named CHECK:
active↔paused, active/paused→complete, active/paused→stopped,
stopped→active, complete/stopped→archived. complete→active is illegal —
continuations are new quests (R-022). The PoC's phase-cap restart
(llm-trading v4: MAX_PHASES stop, relaunch) is why stopped→active exists.
Keeping `quests.state` in sync with the ledger is the lifecycle op's
transaction (catalog Q-SYNC, ENTRY 6); the ledger is the record, not an
enforcement of the column.
**Rationale:** R-022's law needs an auditable state machine, not just the
I01 column CHECK; a transition table with the legal pairs as schema is the
state-diagram-as-law. Resuming a STOPPED quest is a proven operator pattern
(budget exhaustion with work remaining); re-opening a COMPLETE quest never
is (re-synthesis adds report versions; new questions get new quests —
R-022's own sentence).
**Alternatives considered:** (a) no ledger, tool-enforced transitions —
unauditable, and the archive gates lose their home; (b) ledger rows as the
ONLY state (no quests.state column) — requires a join to read state
everywhere and fights the frozen I01 schema; (c) allow complete→active —
contradicts R-022 directly.

## DR-09 — Archive gates: once-only + completed-verification FK pin + frozen counts

**Status:** DECIDED (discovered mid-design)
**Decision:** three schema gates on archive rows: `uq_quest_lifecycle_
archive_once` (partial unique); `fk_quest_lifecycle_verification` — a
composite FK over (phase id, quest id, 'verification', 'complete') using
literal DEFAULT+CHECK columns, so the pinned phase must be a verification
phase in 'complete' state; and `ck_quest_lifecycle_archive_counts_pair` +
nonneg CHECKs pinning claims/evidence/frontier_open counts at freeze (the
drift detector's baseline). Graph-mutation refusal itself is tool-time
(Q-IMM): a pinned-state composite FK on graph rows would make the archive
transition itself unrepresentable (children pin 'active'; the parent UPDATE
to 'archived' orphans them — the mirror of why I01 DR-08 works only for
IMMUTABLE parent values), and triggers are the I01-DR-09-rejected class.
**Rationale:** the working discipline requires proving the schema half with
a named probe: these three are exactly the parts of archive-immutability
that single rows can prove (once-ness, the verification gate, the
fingerprint), each bitten by named probes (X16–X21). The rest is stated as
law, catalogued, and drift-detectable forever via the pinned counts
(queries X1).
**Alternatives considered:** (a) pinned quest_state columns on graph tables
+ composite FK — kills the archive transition (analysis above); (b)
DELETE-from-writable-slot pattern (children FK a slot row deleted on
archive) — same orphan problem in the other direction; (c) archive as
separate frozen-copy tables — duplicates the whole schema per state and
makes "archived" a different database shape; (d) constraint triggers —
rejected mechanism class (I01 DR-09).

## DR-10 — Report versioning: rows about views; standing as a partial-unique flag; bodies content-hashed blobs

**Status:** DECIDED
**Decision:** `report_versions` = the version chain (per-quest dense seq,
synthesis-phase + writer-session lineage with a phase-KIND literal pin,
model, bound state); the body is an object-storage blob at
`reports/<quest>/v<n>.md` with `body_sha256` (D8 placement, matching I01
§6's reservation). The standing-artifact pointer is the `standing` boolean
under a partial unique index (one per quest); supersession never deletes.
Re-synthesis = a new synthesis ROUND (new phases row, new session, new
version, different model) over the same graph.
**Rationale:** L11 — reports are views; the durable asset is the chain of
versions + the graph they project. A standing pointer as a quests column
would be an I01 ALTER for a value derivable from the versions table; the
partial unique keeps "at most one" as schema law while the flip stays a
single-row UPDATE in the finalization transaction (atomic by construction).
Content-hashed bodies give the R-024 hygiene a mechanical check target
(synthesis contexts can be scanned against the hash set).
**Alternatives considered:** (a) standing_report_version_id on quests —
frozen-schema ALTER for derived state; flip becomes a two-table
transaction; (b) ordered-latest convention (max seq = standing) — cannot
express "re-synthesized but NOT promoted" (operator review before standing
flip is the realistic flow); (c) bodies in PG — violates D8 (unbounded).

## DR-11 — Stale-artifact hygiene: synthesis contexts are constructed, never inherited

**Status:** DECIDED
**Decision:** the law: prior report versions NEVER enter a new synthesis
session's context (R-024, the artifact-inheritance defect where v2
restructured v1's report because report.md sat in cwd). Mechanism: the
synthesis tool surface assembles context from exactly three inputs — the
graph (claims/evidence/edges via queries), the corpus (chunks/sources), and
the agenda docs — with NO report-body read affordance at any layer the
session can reach; the finalization/rendering path is the only reader of
report bodies. Superseded versions keep standing=false forever; the flip to
standing happens only at finalization of a BOUND version.
**Rationale:** the PoC fixed this environmentally (move the artifact away
before spawn; "runbook law") — an environmental fix is one forgotten `mv`
from recurrence. The structural kill is removing the READ PATH, not the
file; kquest's tool surface (ENTRY 5) makes that precise: no tool the
synthesis session can call returns report-body bytes. The seed models the
target state (v1 exists, unbound and non-standing; v2 bound and standing;
the chain visible as the stale inventory).
**Alternatives considered:** (a) runbook rule (PoC fix) — proven fragile;
(b) per-session cwd scrubbing at spawn — substrate-level, survives only
until a substrate change; (c) encrypting old bodies — absurd overhead for
an ordering problem.

## DR-12 — Citation binding pass: deterministic index + import manifest + footnote format

**Status:** DECIDED
**Decision:** ordinals are LOCAL and positional: 1..N map to the quest's
citable corpus ordered by (quest_sources.added_at, source_id) — the
citation index; ordinals beyond N are imports, assigned via the import
manifest carried on the synthesis phase's `result.imports` (ordinal, source
URN, origin quest — tool-minted, model-never-sees-hashes). The binding pass
parses `[^n]` tokens from the body, writes one `report_citations` row per
ordinal (uq per version), and renders the footnote block as
`[^n]: <urn> — <title>, <canonical_url>, fetched <YYYY-MM-DD>` (+ an
`[IMPORT from quest <uuid>]` suffix on imported lines). fetched_at = I01
DR-21's fetch-completion timestamp at date granularity — that I01 deferral
is discharged here. Determinism: same body + corpus + manifest ⇒ byte-equal
citations and footnotes (re-derived and asserted in the seed and in
queries B1).
**Rationale:** design-citation-urns (PoC) fixed the model-transcribes-
hashes problem with local ordinals; kquest's addition is making the
ordinal→source mapping itself deterministic and cold-boot stable (the PoC's
C-index was a per-corpus file; ours is a total order on quest_sources) and
giving imports a first-class slot instead of a special case. (added_at,
source_id) is a total order that recomputes identically after any crash
(L7) and never renumbers when sources are added later (append-only).
**Alternatives considered:** (a) order by source URN — stable but
meaningless to humans and re-orders when canonicalization rules change;
(b) order by first use in the body — depends on model output, so binding
would be circular; (c) per-SECTION ordinals — finer locality, more surface
for off-by-one transcription, no evidence of need at report scale;
(d) fetch-time-ordered index — fetched_at is mutable-adjacent (refetches)
and not quest-scoped.

## DR-13 — Import citations: two reference columns, citable-only both, same-user origin

**Status:** DECIDED (discovered mid-design)
**Decision:** `report_citations` carries TWO nullable source references:
`source_id` (in-corpus; conditional citable-only FK WITH the tenancy pin,
identical in shape to evidence's) and `imported_source_id` (import;
citable-only FK over (id, anchorable) WITHOUT a tenancy pin — the new
`uq_sources_id_anchorable` key exists for this). `ck_report_citations_
resource_exactly_one` forces exactly one; imports must carry
`import_source_quest_id`, same-user by composite FK. Unmarked out-of-corpus
citations are refused by the binding pass (tool-time; the schema cannot
see quest_sources membership from the citation row).
**Rationale:** imports are the sanctioned cross-quest (and, via visibility,
cross-tenant) read — the tenancy pin MUST be absent on that arm or bob's
public source could never be cited by alice's report. But dropping the pin
on a single shared column would also drop it for in-corpus citations; two
columns keep each arm exactly as strict as its law requires, and the
exactly-one CHECK keeps the shapes disjoint. Origin stays same-user (I01
§7 posture: lineage is same-user; cross-user graft is the sharing layer's
later problem) — when cross-user origins arrive they ride a ruling + a
relaxed FK, recorded here.
**Alternatives considered:** (a) one source_id column, plain FK, tenancy
dropped everywhere — weakens the law for the 99% in-corpus case;
(b) polymorphic (kind, id) columns without real FKs — rejected mechanism
class (DR-01 pattern); (c) imports as a separate table — splits the
footnote rendering and the binding pass across two tables for one
distinction a CHECK carries fine.

## DR-14 — Visibility: workspaces + one grant mechanism with exactly-one shapes

**Status:** DECIDED
**Decision:** `workspaces` (slug-named, creator) + `workspace_members` many-
to-many; `resource_grants` as the ONE sharing mechanism: exactly one
resource column (source_id XOR canonical_claim_id, each a composite FK that
pins ownership), exactly one grantee (user XOR workspace XOR public flag).
Private = no row. Effective scope per resource = public > workspace >
shared (view `v_resource_visibility`). Future kinds (reports, quests) are
additive columns in the same table with the same exactly-one law.
**Rationale:** R-025 demands one mechanism serving sources now and
canonical claims later — a single table with per-kind nullable FK columns
keeps FK integrity (each column a real reference) while the exactly-one
CHECKs prevent the polymorphic mush of a (kind, id) pair. Workspaces are
the minimal group primitive the "workspace door" names; nothing else in
the system needs to know they exist except the visibility query family.
**Alternatives considered:** (a) per-resource grant tables (source_grants,
canonical_claim_grants, …) — N identical tables, N visibility queries;
(b) a (resource_kind, resource_id) polymorphic column pair — no FK
integrity, the exact shape DR-01-style laws exist to avoid; (c) visibility
SCOPE columns on sources/canonical_claims (ALTERs on frozen tables) for
private/shared/public with a separate grants table for targets — two
mechanisms where one suffices; absence-as-private avoids the ALTER.

## DR-15 — The four additive unique keys on frozen I01 tables

**Status:** DECIDED
**Decision:** `schema-i02.sql` opens with four ALTER TABLE … ADD CONSTRAINT
… UNIQUE statements — `claims (id, user_id)`, `sources (id, anchorable)`,
`phases (id, quest_id, kind)`, `phases (id, quest_id, kind, state)` — and
nothing else touches I01 tables. These are new unique KEYS (indexes) only:
no columns added, no semantics changed, no I01 file edited; they are the
composite-FK targets this iteration's cross-table pins require (merge
tenancy pin, cross-user citable-only import pin, synthesis-phase lineage
pin, archive verification gate pin). No I01 amendments are proposed by this
iteration.
**Rationale:** the boundary allows ALTERs where a DR justifies them; unique
keys are strictly additive (any query true before is true after) and are
the house pattern for conditional/pinned references (I01 DR-07/DR-08 built
theirs at table-creation time; these tables were frozen before the pins
existed).
**Alternatives considered:** (a) no pins — the four laws (M-TEN's cross-user
arm, Q-VER, R-SEQ's phase-kind lineage) degrade to tool-time checks;
(b) replica join-key tables — the same indexes plus sync obligations;
(c) propose I01 file amendments to add these keys inline — unnecessary:
ADD CONSTRAINT achieves the target without touching read-only files.
