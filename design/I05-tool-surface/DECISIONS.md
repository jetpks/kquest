# I05 — tool-surface: decision records

Numbered records for iteration I05 (tool-surface). Status is DECIDED or
OPERATOR-RULING-NEEDED (with Options + Recommendation); nothing else is
silently decided. Prior law is never edited by this lane; no prior-law
amendment is proposed by this iteration (tools write through existing
I01–I03 schema law; I04's DR-12 amendment is already ratified into the
I01 DDL). DR numbers are this iteration's; prior-law records are always
qualified (e.g. I04 DR-09).

---

## DR-01 — Refusal dialect: rule-id + violation + legal alternative (the teaching refusal structure)

**Status:** DECIDED
**Decision:** Every frozen refusal is ONE line with three parts, in
order: `<RULE-ID>: <what was violated> — <the legal alternative /
canonical form>`. The rule-id is a stable, census-able token (it lands in
`tool_calls.error_class`, so refusal-class metrics and tripwires are
grep-able — ENTRY 7 consumes the census); the violation is named
concretely (the offending value or field, not a bare type check); the
alternative names the legal move, and where shape is the issue carries
the copy-shape example verbatim. Success-side notes mirror the dialect
(coercion note, bare note, cap-continuation note — DESIGN §3.9). No
scolding, no rule without its fix.
**Rationale:** Quest 2's pre-teaching refusals named rules but not
fixes: `supports_new must be a non-empty array of field objects` fired
287 times (class a, 90 sessions, still live at snapshot) because the
caller had passed a JSON-encoded string and the refusal never said so
(`arc-run-20261121T-quest2-failure-taxonomy.md` §1 class a, §verbatim
(a), §3). The composed teaching refusal that finally fired in the
adoption session carried all layers in one line and the agent echoed
the wording 3× afterward — self-teaching visible
(`arc-run-20261121T-quest2-teaching-patch.md` §adoption datum). I04
DR-09's ruling makes the alternative-naming LAW: refusals and caps that
name the legal alternative.
**Alternatives considered:** (a) terse PoC-voice refusals (42–76 ch) —
rejected: "terse to a fault — the one place more bytes (coordinates,
nearest line) would pay" (`2026-11-17-arc-decompose-review.md` §Q8);
(b) free-form prose refusals — rejected: unparseable, uncensus-able,
untestable; (c) error codes with a lookup table the model cannot read —
rejected: the refusal is the teaching surface; the model must be able
to act on it in the next call.

## DR-02 — Coercion write-back boundary: parse once, store the parsed value

**Status:** DECIDED
**Decision:** String-coercion at type boundaries WITH write-back (R-049):
parse ONCE at each complex-type parameter boundary — only Strings whose
stripped form starts `{`/`[` AND parse (`JSON::ParserError` leaves the
value untouched; the refusal voice is unchanged) — every downstream
invariant validates the PARSED value, and the PARSED value is what the
call STORES at every storage site (node creation, fused entries,
node_set writes). Coerced successes carry the frozen teach note
(`coerced <what> — the tool-call layer stringified a complex value;
nest it under fields: to avoid`). Coerce-for-validation-only is
FORBIDDEN (T-COERCE). Split authoring orders are never silently
reassembled; the fused-form DIRECTION is fixed structurally (evidence-
side fusion canonical; claim-side `supports_new` refused with the
inverse named — the descent-observation incident A consumed).
**Rationale:** The cold-verifier bomb: tart's first coercion layer
validated a parsed COPY of a stringified `terminal` and stored the
original String — the creation SUCCEEDED, the raw string reached the
store, and the trusted tier's boundary check died LATE (`bad terminal
type` at the next phase launch). A refusal that fires at a boundary
about a value the model demonstrably sent correctly — or a gate that
dies late on a planted string — is audit pollution with a delayed
fuse (`arc-run-20261121T-quest2-teaching-patch.md` §STRING-COERCION
LAYER live-risk note 1; fixed upstream by the write-back at the storage
boundary, `coerce_field_value` in the current graph.rb with the
phase-117 regression note in-source). kquest makes the fix the spec.
The stringification defect itself is live provider behavior (the
05:09:57–05:11:16 sequence: three burns, then the model restructuring
under `fields:` where the emitter stays native — teaching-patch §class
evidence).
**Alternatives considered:** (a) refuse all stringified complex values —
rejected: refuses provably-correct content; measured cost 3 calls ≈ 50 s
per incident, and the model cannot stop its own emitter; (b)
coerce-for-validation-only (tart's first cut) — rejected: the bomb;
(c) coerce everywhere a String appears — rejected: T6 — a string-rule
field whose VALUE looks like JSON stays a string, stored verbatim
(teaching-patch §T1–T6 battery).

## DR-03 — Container-naming law: one name per concept (fields)

**Status:** DECIDED
**Decision:** One container name per concept (R-050): nested field values
go under `fields:` — the single container name for every tool that
accepts one (node_add, node_set). Flat-at-top-level remains the primary
shape (every key outside the tool's reserved set is a field value); a
key supplied both flat and nested must carry the same value (collision
refusal, frozen). `set:` does not exist in kquest.
**Rationale:** tart's `set:`/`fields:` split — `node_add` nested under
`fields:`, `node_set` under `set:` — was a defect generator living in
the shared repo: the teaching example showed only the flat form, so the
refusal never demonstrated the container it names; quest-2's class-d
`{"op":"node_set","node":"K92","fields":{…}}` refusal was exactly this
confusion (`arc-run-20261121T-quest2-failure-taxonomy.md` §shared-repo
harness defect, class (d) `fields` ×7). The unification (commit 83f1362,
probes P1–P6 green, `/set:` occurrences → 0 in session) is adopted
(`arc-run-20261121T-quest2-teaching-patch.md` §CONTAINER UNIFICATION
LAYER).
**Alternatives considered:** (a) keep two names for backward
compatibility — there is no backward compatibility to keep (D7: no PoC
migration path); (b) flat-only (no container at all) — rejected: the
live recovery path for the stringification defect IS `fields:`-nesting
(the emitter stringifies only top-level complex values), so the
container must exist and be taught by the coercion note.

## DR-04 — Sliced-read defaults: offset/limit values and the slice cap

**Status:** DECIDED
**Decision:** `source_read` takes `offset` (1-based line) and `limit`
(lines), DEFAULT limit 60 lines, hard cap 8,000 chars per slice
(`read_slice_cap_chars`, carried from I04 FM-22); a read that would
exceed the cap — or an unbounded read of a long snapshot — is refused
with the frozen `non-sliced-read` text naming the slice form and the
grep-first pattern. `offset` beyond EOF is refused with the actual line
count and the legal range. Grep-then-slice is the canonical reading
discipline (source_grep locates; source_read extracts); retrieval-first
sits above both (DESIGN §7.3; I04 §7 policy).
**Rationale:** The 78% lesson: corpus file reads were ≈62,260 of a
79,677-token final context (78%) while the entire graph loop was 5.1%;
S1 loaded ~122K chars before its first write; the ONE observed sliced
re-read (limit=20 offset=1, 1.4K chars) "is the pattern that should
have been the default" (`2026-11-17-arc-decompose-review.md` §Q5). I04
adopted the 8,000-char cap as the config default (FM-22); this record
fixes the tool-side values and refusal. The 60-line default mirrors the
PoC's observed `[59]`-style line-range pattern.
**Alternatives considered:** (a) char-based slices instead of lines —
rejected: spans are proven byte-exact against lines the model just SAW;
line slices keep the span-copy discipline local (the anchor is in the
slice you read); (b) advisory-only (never refuse) — rejected: the
refusal IS the teaching (I04 DR-09: advisory lines teach, and the
teaching shape here is the refusal naming the slice form — the line is
config data `{scope: read_slice, value, mode}`, toggleable per the
ruling; mode=hard is the shipped default for this line because its
crossing is silent context blowout, the exact class the lesson is
about); (c) larger default slices — rejected: 8,000 chars ≈ 2K tokens
keeps read→extract interleaving visible to the ContextBudgeter.

## DR-05 — Unknown-tool response: in-band error + the session's legal-tools list

**Status:** DECIDED
**Decision:** An unknown tool name finalizes as that call's in-band
error result — the gem's fixed voice `no such tool: <name>` VERBATIM
(the gem contract, never altered) — and the harness APPENDS the
session's legal-tools list so the refusal teaches: `… — this session's
legal tools: <legal-tools>; call one of those (the tool name IS the
operation; there is no op key)`. For subagent sessions the list IS the
profile's restricted surface (DR-06). 3 consecutive unknown-tool calls
escalate to a wedge-guard alert (a stuck model, not a bad call — I04
FM-12's `unknown_tool_alert_at`, default 3).
**Rationale:** One tool per operation (D2) retires tart's `op`-key
dispatch and its defect classes structurally (quest-2 class b: `unknown
op nil` ×38, one assistant message with 5 op-less calls; invented ops ×7
— taxonomy §1 class b, class i) — but the model can still name a
nonexistent tool, so the failure mode needs a teaching shape. The gem
already gives the in-band contract ("nothing executes for it" —
fast-completions `docs/reference/tools.md`); the list-appending is
I04 FM-12's required behavior, frozen here.
**Alternatives considered:** (a) silently ignore unknown tools —
rejected: silent no-ops are the anti-teaching; (b) fuzzy-match the name
to the nearest legal tool and run it — rejected: executing a call the
model did not make is worse than refusing one it did; (c) keep an
`op:`-key dispatch with a legal-op list in the refusal — rejected: the
defect classes above are the evidence against the shape.

## DR-06 — Profile restriction mechanics: registration-is-restriction, no recursion

**Status:** DECIDED
**Decision:** A subagent's tool surface is a NAMED PROFILE — a
config-data restriction of the parent session's registered surface —
and the profile IS the registration: the ToolHarness registers exactly
the profile's tools into the child's `Chat#with_tools`; an unregistered
tool call lands in the unknown-tool path, which teaches with the
profile's own legal list (DR-05). No profile contains `subagent_spawn`
or `subagent_status` (no recursion; one level of nesting). Day-one
profiles are `survey` (read-only: status, mass, node_get, neighbors,
search, list, paths, source_read, source_grep, source_list, retrieve)
and `operator` (the full surface — L13 parity: same tools, same
constraints, same audit; restriction is empty BY DESIGN; one-writer is
the launch gate's job, not the profile's). Profiles are declared per
quest-local config, so a future phase can name a wider profile without
code changes (the I04 DR-08 shape, made normative here).
**Rationale:** Restriction-by-registration is the only shape that cannot
be talked around (prompt-discipline restrictions are the class of law
the PoC repeatedly proved fragile — the dedup search-cap law was blown
through ~8× with the law in context, `arc-run-20261122T-llm-trading-
midarc.md` §4). The band-survey workers that produced the one complete,
intervention-free report needed exactly the survey shape: parallel,
context-free, read-only
(`arc-run-20261122T-quest2-arc-summary.md` §3 item 7). Recursion stays
excluded: spend attribution and deadline accounting stay legible at one
level (I04 DR-08's rationale, consumed).
**Alternatives considered:** (a) full parent surface + prompt
instructions — rejected (the fragile class above); (b) code-defined
per-purpose subsets — rejected: config data survives quest-local law
changes without code edits; (c) nesting to depth 2 — rejected: no
measured need, doubles the wedge/accounting surface (I04 DR-08
alternatives, adopted).

## DR-07 — Dedup-by-construction wiring at node_add (thresholds flagged for ruling)

**Status:** OPERATOR-RULING-NEEDED (wiring DECIDED; the near-leg
threshold VALUES need the operator)
**Decision:** Wiring (DECIDED): claim creation (`node_add` label=claim)
runs the I03 dedup candidate check BEFORE the write — exact leg
(canonical-text byte-equality, the `uq_claims_quest_canonical`
normalizer) and near leg (cosine neighbors in the registry's claim
vectors, user-scoped) — and the ANSWER surfaces hub-mapped candidates
with the frozen note (`dedup candidates: [K<m> (near_dup, cosine …)] —
attach evidence to the existing claim or reword if genuinely distinct;
nothing is auto-merged`). An EXACT duplicate is refused (the frozen
`duplicate-label` text names the existing claim — refusal-locates).
Near-dups NEVER refuse (a growth signal, I03 DR-13). This retires the
PoC's search-first model discipline: no SKILL cap law ("one search per
candidate claim; fragment sweeps forbidden") can hold — synthesis blew
through it ~8× with 78 single-word searches, 0 mutations
(`arc-run-20261122T-llm-trading-midarc.md` §4), and the phase-16
SCATTER storm (hundreds of 1–2-word searches, 2 mutations in 7.5 min —
§2) is the earlier evidence class. The check the model cannot skip
replaces the law the model cannot keep.
**Rationale:** The PoC's measured failure mode is not bad dedup intent
but UNENFORCEABLE dedup discipline: the search-cap law sat in context
from the boot read and was still violated ~8× in one phase (78
single-word searches, 0 mutations), and the phase-16 SCATTER storm
(hundreds of 1–2-word searches over the session's OWN claim texts,
2 mutations in 7.5 minutes) is the same class
(`arc-run-20261122T-llm-trading-midarc.md` §4, §2). A tool-side check
is the structural remedy class the PoC repeatedly proved is the only
one that holds (I11's refusal-with-locations, I17's deadlines, I20's
mass floors — all tool/driver-side, all effective where SKILL laws
were not).
**Thresholds (OPERATOR-RULING-NEEDED):** near-leg top-k and similarity
floor are TOOL CONFIG. I03's fixture values (k=5, floor 0.6) are
methodology-limited — calibrated against the deterministic synthetic
fixture encoder, not a real registry model (I03 DR-15). The floor gates
a BEHAVIOR (candidate surfacing) not a hard edge, so a provisional
default is safe; the operator should rule the shipped defaults.
**Options:**
- **(A) Adopt k=5, floor=0.6 as shipped config defaults** with an
  implementation-arc recalibration step against the real registry
  model (bge-m3 via OpenRouter) recorded as a required calibration
  task.
- **(B) Ship config rows with NO default** (per-quest values only) —
  refuses nothing, surfaces nothing until configured; safe but the
  guard is off for every quest that does not set it.
- **(C) Defer the near leg entirely until the arc calibrates** — exact
  leg only (canonical-text byte-equality) day one; loses the
  embeddings-era rationale (I03 DR-13 alternative (c), rejected there).
**Recommendation:** (A). The exact leg is schema law regardless; the
near leg's cost is one vector query per claim creation; a provisional
floor that over-surfaces candidates is a teach-note nuisance, while
under-surfacing loses growth-slot data. Recalibration is a config
change, not a design change.
**Alternatives considered:** (a) auto-refuse near-dups — rejected:
blocking would re-create the merge-gate load I02 DR-16 ruled out
(I03 DR-13 alternative (b)); (b) keep the search-cap SKILL law and add
teaching — rejected on the PoC evidence above; (c) run the check AFTER
the write and warn — rejected: dedup-by-construction means BEFORE
(R-036/I03 D-DUP; an after-the-fact warning re-creates the clone-then-
reconcile shape the exact leg refuses).

## DR-08 — Retrieval tools without model names: the registry is the only path at the tool surface

**Status:** DECIDED
**Decision:** `retrieve` (and every future retrieval surface) takes NO
model parameter: the hybrid legs (dense via the registry's generated
table, PG FTS over `chunks.search_tsv`), RRF fusion (K=60), and
per-user scoping are resolved by kquest behind the registry (I03 G-REG,
DR-01 there). A call that supplies a model field is refused with the
frozen `model-name-refused` text. `usage_events.model` is an audit
echo, never an access path.
**Rationale:** R-054 + I03 law: the registry is the only model path;
no model string in query text (check-coverage greps model strings out
of I03's queries — the same law mechanically). The agent's job is to
name WHAT to find; HOW it is embedded is registry config (register/
retire/A-B without code changes, D4).
**Alternatives considered:** (a) accept-and-ignore a model parameter —
rejected: silent acceptance teaches the wrong shape and invites
model-name smuggling into prompts; (b) expose per-leg weights to the
agent — rejected: RRF fusion weights are config, not agent-tunable
(leg-swap correctness is rank-based and must stay provider-configured).

## DR-09 — Listing/result caps: principled order + caps that teach continuation

**Status:** DECIDED
**Decision:** Every listing/result surface carries a PRINCIPLED ORDER
(id ascending, staging order, mass order — deterministic, L15) and a
CAP whose crossing TEACHES continuation instead of silently truncating:
the frozen cap-continuation note `(capped at <n> rows — resume with
after:"<last-id>"; ordering is principled, never shuffled)`. Shipped
caps (config defaults, tart's proven values adopted): search 20 rows /
120-char snippets, list 50 rows, neighbors 50 aliases, paths depth 128,
source_list 50 rows. Result-size caps for mutation answers ride the
I04 ToolHarness result caps; read tools carry their own.
**Rationale:** L15: "what the agent never saw" is measurable — a cap
with a continuation token keeps the blind spot queryable, never silent.
tart's caps are the measured, exemplary sizes: `status` 65 ch, `search`
60 ch, `node_add` answers 107–413 ch — "no graph op is chatty"
(`2026-11-17-arc-decompose-review.md` §Q8); the ONE observed sliced
re-read shows the slice pattern pays. Caps are config data (I04 DR-09's
per-line shape).
**Alternatives considered:** (a) no caps — rejected: unbounded listings
are the context-blowout class; (b) caps with silent truncation —
rejected: silent truncation is the frozen-index trap's shape (a lagging
view the agent trusts); (c) random or relevance-shuffled listing order
— rejected: principled order is the L15 law and the continuation token
depends on it.

## DR-10 — Tool-call transaction shape: audit row in the mutation transaction

**Status:** DECIDED
**Decision:** Every mutating tool runs its mutation + its `tool_calls`
audit row (args/result VERBATIM — refusals included, `ok`/`error_class`
shape-checked) + the transcript append in ONE transaction: a refused
call writes its refusal as the call's own audit row and NOTHING else; a
successful mutation and its audit row commit together or not at all.
Read tools record their rows outside mutation transactions (nothing to
roll back). The refusal's rule-id (DR-01) is the `error_class` value —
the census surface ENTRY 7 tripwires read.
**Rationale:** I01 §3.15 ruled the shape ("the wrapper writes the row in
the same transaction as the mutation — ENTRY 5 tool harness") and I04
E-AUDIT pinned it to the ToolHarness; this record fixes the tool-side
contract. The PoC's refusal census ran on exactly this verbatim shape
(taxonomy methodology: "read-only parse of all session transcripts" —
in kquest the same census is one query over `tool_calls.error_class`).
L7 falls out: committed mutations survive killed sessions because
there is no in-memory-only state anywhere in the tool path.
**Alternatives considered:** (a) audit rows written after commit —
rejected: a crash between mutation and audit row loses the audit half
of double-entry; (b) audit only mutations, not reads — rejected: L8 is
"every tool call recorded verbatim"; read paths matter for replay and
blind-spot measurement; (c) a separate audit service consuming an event
stream — rejected: same-transactionality is the point (I04 E-AUDIT).
