# I04 — agent-loop: decision records

Numbered records for iteration I04 (agent-loop). Status is DECIDED or
OPERATOR-RULING-NEEDED (with Options + Recommendation); nothing else is
silently decided. Prior-law changes appear ONLY here as patch proposals —
no file under design/I01/I02/I03 is edited by this lane.

---

## DR-01 — Provider seam: gateway OpenAI-wire first, dialects as data, no vendor SDKs

**Status:** DECIDED (D1 law; record fixes the seam's shape)
**Decision:** The loop's only model transport is `Fast::Completions`
(`POST {base}/chat/completions`, SSE streaming, fiber-native). The default
provider row is the operator's local gateway on the PLAIN OpenAI arm — no
dialect declared, no API key required (the gem sends `authorization` only
when a key is present). Every other provider is a config row carrying a
dialect DECLARATION over the gem's closed 14-key vocabulary (`:zai`,
`:deepseek`, `:fireworks` ship; customs declared from config data at boot —
unknown keys/values raise `ArgumentError` at declaration time, so a
dialect defect fails at boot, not on the wire). No vendor SDK is linked,
ever; a cloud API is admitted only if it speaks the OpenAI wire or a
declared dialect of it. ProviderSeam is the only component that sees
`base_url`/`api_key_ref`; the loop below it addresses models by config,
never by URL.
**Rationale:** D1 ratified the posture; the gem's dialects-as-data design
(docs/reference/dialects.md — "the consumer declares, the codec obeys")
makes provider variation CONFIG, not code, which is what "cloud-ready
without vendor SDKs" concretely requires. The PoC's endpoint-discovery +
smoke-probe discipline (`GET /v1/models`, then a 1-token POST) becomes the
seam's health check.
**Alternatives considered:** (a) per-provider adapter classes — rejected:
duplicates the gem's dialect layer and forks retry/telemetry economics;
(b) vendor SDKs behind a facade — rejected by D1 outright; (c) gateway-only
day one with no cloud rows modeled — rejected: the seam would need a second
design pass the moment the first cloud model is routed (the PoC's own arc
ran local → OpenRouter → OpenAI within one quest).

## DR-02 — Retry policy layering: the gem's immediate retry below, the loop's jittered classes above; wedge guards are deadlines

**Status:** DECIDED
**Decision:** Four failure classes (retryable / terminal / wedge-guard /
budget-guard — the enum in failure-modes.tsv) and four layers: L0 = the
gem's bounded IMMEDIATE creation retry (pi's trigger set, never after 2xx,
`max_retries` per provider row); L1 = RetryGovernor jittered exponential
backoff (`sleep = rand · min(cap, base · 2^attempt)`) with per-class caps
and a FRESH SEED per attempt; L2 = phase-attempt accounting
(`engine.phase_attempt_cap`, default 3 — the PoC's discovered `RETRY_CAP=3`
default) on `phases.attempt_no`; L3 = escalation to a ledgered quest pause
for operator-visible conditions. Wedge-class modes are NOT retried — they
are made structurally impossible by deadlines with bounded escalation
(I17's verified TERM→grace→liveness→KILL pattern, worst case
`timeout + ~17 s`). Nothing after a 2xx is ever retried (the gem salvages;
the loop persists the salvage and its usage).
**Rationale:** The gem already owns the transport-adjacent retry with
exactly pi's semantics; re-implementing it in the loop would fork the
economics. The loop's additions are exactly what the gem deliberately does
not do: backoff, per-class policy, phase accounting, and pause
escalation. The PoC paid for the wedge lesson (five ACTIVITY_TIMEOUT
kills in 7h — muse-20261119T-i17) and for unbounded retry (identical-body
replays under seed-0); deadlines + fresh seeds are the two structural
fixes.
**Alternatives considered:** (a) loop-level retry only, gem `max_retries:
0` — rejected: loses the creation-phase retry the gem implements
correctly (immediate, connection-pooled); (b) fixed-interval backoff —
rejected: synchronized retry storms across sessions are the classic 429
amplifier; (c) retrying wedge-class modes — rejected: a wedge is a missing
deadline, and retrying a hang just moves the hang.

## DR-03 — Spend recording at the call site (R-046): a telemetry-sink recorder with structural completeness

**Status:** DECIDED
**Decision:** SpendRecorder registers as a `Fast::Completions` telemetry
sink (`Client.new(telemetry: [recorder])`). The gem's terminal invariant —
EXACTLY ONE `on_completion_end` XOR `on_completion_error` per completion,
creation retries INSIDE the completion, tool execution OUTSIDE it — makes
"one usage_events row per API call" structural rather than conventional.
Rows: kind `llm`, model as served, input/output tokens from the final
Message's `Usage`, `cost_usd` from provider pricing config (NULL = local),
chain session→phase→quest→user total by I01's pinned FKs. Failures record
zero-token rows; mid-stream salvages record the salvaged partial's usage
(FM-15); dialects that cannot stream usage (`supports_usage_in_streaming:
false`) produce zero-rows plus a config-time warning (FM-25). The embedding
call site (I03 DR-07/J-SPEND) records `kind='embedding'` rows through the
same ledger with THIS entry's retry classes (FM-23). Budgets read rollups
over the ledger, never stored counters (L10).
**Rationale:** D10/R-014 make spend a ledger, and I01 §3.16 already ruled
"retries and failed calls each record their own row". The telemetry seam is
the only place where every completion is guaranteed to pass exactly once
with its usage in hand — a rescue-ladder recorder would miss error paths
the sink contract covers structurally (including consumer-block raises).
**Alternatives considered:** (a) reading `Message#usage` after `Chat#step`
in the LoopDriver — rejected: misses every raise-out path (salvage,
StreamError, cancellation) that still spent tokens; (b) gateway-side
accounting — rejected: the gateway is a shared operator asset, not a
kquest ledger, and local models bypass none of the need; (c) per-attempt
rows inside a gem retry — rejected: the gem reports one usage per
completion; attempts that die before a body carry no usage and are already
inside the completion's record.

## DR-04 — Pause mechanics: pause-reconfigure-resume; steer-while-running REJECTED (D5)

**Status:** DECIDED (D5 law; record fixes delivery mechanics)
**Decision:** Steering reaches a quest ONLY through pause. Sequence:
operator pause request → ledgered lifecycle event `active → paused` (I02's
legal transition) → SessionSupervisor delivers at the next TURN BOUNDARY
when the in-flight turn can bank, else cancels it (`Chat#cancel`:
`CancelledError`, NO phantom terminal, the half-streamed turn never
appended, committed mutations survive — L7) → steering payload lands as
durable config → `paused → active` → a NEW session cold-boots and re-reads
config (prompt assembly reads live config; nothing is injected into a
running session). Phase attempt numbering continues across the pause
(PoC precedent: banked phase-86 → phase-87).
**Rationale:** D5 rejected steer-while-running on first-hand experience.
The PoC's own swap record shows the concrete race: the tender had to be
stopped BEFORE the driver because its restart "would have raced the swap"
(arc-run-20261122T-llm-trading-v3-launch.md §Pause). The gem's cancel
discipline (docs/how-to/cancel-a-running-chat.md) is the safe mid-turn
primitive precisely because it leaves no half-turn in history and no
phantom terminal — the audit stays truthful across a pause.
**Alternatives considered:** (a) mid-turn steering via an injected user
message — rejected: D5, and it mutates the context the writer is currently
depending on; (b) steering queue read at turn boundaries (no pause) —
rejected: a queued steer changes model/config under a live session's feet
with no ledgered lifecycle event, which is steer-while-running with extra
steps; (c) kill-and-restart instead of pause — rejected: loses the bank
boundary and the ledgered paused state; the PoC's boundary banking
survives kills, but pause is cheaper and auditable.

## DR-05 — One-writer enforcement point: the launch gate + reaper + write-guard

**Status:** DECIDED (specifies the home I01 DR-12 pinned)
**Decision:** Enforcement point = the SessionSupervisor's LAUNCH GATE, a
transactional pre-insert check: refuse any session start (orchestrator
attempt or operator attach) while another session of the quest has
`ended_at IS NULL` AND its owning worker is live (worker liveness from the
job runner's worker registry — ENTRY 8 hosts it; never pidfiles, the PoC's
repeatedly-broken artifact). **Serialization (pinned at judge F2 — a
plain pre-insert check is a TOCTOU):** the gate transaction first takes
`SELECT … FOR UPDATE` on the quests row, then runs the liveness check
and insert — the row lock serializes concurrent launches for the same
quest (the second racer blocks until the first commits its session row,
then sees the holder and refuses). In-transaction row locking is NOT
what I01 DR-12 rejected (it rejected an advisory-lock ENFORCEMENT HOME
in schema — runtime state as durable law); this is gate-transaction
mechanics. Alternative recorded: an xact-scoped advisory lock (equivalent
here; the quest-row lock is simpler and needs no extra note).
Flagged for ratification confirmation with the F2 fix. The refusal names
the holder session and
driver. The REAPER stamps `ended_at` on orphaned sessions (worker gone) at
cold-boot scan and periodically, which re-opens the gate — this is the
cold-boot restart path. Defense-in-depth: the ToolHarness write-guard
rechecks the gate before every mutation batch. NO schema constraint and NO
advisory lock — both were ruled out by I01 DR-12 (a partial unique blocks
L7 cold-boot; advisory locks are "runtime state, not durable law;
invisible to ops").
**Rationale:** I01 DR-12 explicitly deferred "the orchestrator's launch
path + reaper" to this entry; this record specifies that path without
reopening the schema question. Worker-registry liveness is the honest
crash signal (a dead worker's registry entry disappears with it), unlike
heartbeat columns (new schema) or pidfiles (the PoC repaired stale
pidfiles in at least three separate incidents).
**Alternatives considered:** (a) partial unique index on unfinished
sessions — REJECTED by I01 DR-12 (L7 conflict; not reopened); (b)
Postgres advisory lock on quest_id — REJECTED by I01 DR-12 (runtime
state, invisible to ops); recorded here because it was this lane's initial
lean; (c) heartbeat column on sessions (prior-law amendment) — rejected
as unnecessary: worker liveness is a job-runner fact, and the reaper plus
the registry cover crash detection without new schema.

## DR-06 — Transcript-ceiling policy: refuse vs truncate vs swap (size-correlated empty completions)

**Status:** OPERATOR-RULING-NEEDED
**Decision:** The ceiling is a real, measured provider property (deaths at
496,294 B and 496,578 B, 284 B apart, both empty-completion —
arc-run-20261122T-llm-trading-v3-launch.md §Post-resume ground truth +
size-ceiling evidence). It is CONFIG per provider row
(`transcript_ceiling_warn_bytes` default 450,000 — the PoC's SIZE-CEILING
tripwire value; `transcript_ceiling_hard_bytes` default 496,000). WHAT
happens at the thresholds needs an operator ruling (below); the loop-side
invariants hold regardless: early warning refuses NEW corpus ingestion and
banks at the next turn boundary; the hard ceiling ends the session at a
boundary; a live transcript is NEVER truncated mid-flight (L8 audit
integrity); a successor session cold-boots from durable state, optionally
compacted.
**Rationale:** The PoC's own ceiling episode ended in exactly this ruling
shape — "Pending operator ruling if the ceiling confirms: (a) finish the
quest on glm via or-relay (model switch back), vs (b) stay local and
engineer around the limit (e.g. driver-side transcript
truncation/summarization before ~450 KB, or
empty-completion-at-size → retryable). No action taken" — and when the
ceiling confirmed, the EXECUTED ruling was (a), the model swap, via
pause-reconfigure-resume. This is a routing/economics call (local churn
tax vs remote spend), not a loop-mechanics call, so it stays with the
operator; DR-06 fixes the detection and the never-truncate-mid-flight law
now.
**Options:**
- **(A) Swap at the wall (the PoC's executed ruling):** when a provider's
  hard ceiling is hit, pause and route the remainder to a large-window
  model (per ENTRY 6 routing config). Clean, proven; costs remote spend
  and a pause cycle.
- **(B) Compact-and-continue:** at the warn threshold, summarize/compact
  the transcript (keeping verbatim audit blobs intact) and continue on the
  same provider. No remote spend; new machinery (compaction correctness,
  a new failure class), and compaction of a working session risks losing
  in-context state the model relies on.
- **(C) Refuse-and-report:** treat the ceiling as a hard stop; the quest
  pauses for operator disposition with a loud condition. Simplest; risks
  reportless quests (the PoC's reportless-stop failure mode) unless the
  ENTRY 6 finisher discipline catches it.
**Recommendation:** (A) as the default policy, with (B)'s warn-threshold
ingestion-refusal (already law) making (A) rare; revisit (B) only if a
future local engine makes remote spend unacceptable. The PoC's executed
ruling is the only option with live evidence.
**Alternatives considered:** mid-flight truncation — rejected outright (L8:
the transcript is the audit log; silently shrinking it under a live model
is fabrication-adjacent); "retryable empty-completion-at-size" alone —
rejected as a policy: it treats the symptom (each retry re-climbs to the
same wall) and the PoC measured exactly that (session 6 died in the band
like #4/#5).

## DR-07 — Seed default: random per request, fill-if-absent, explicit wins (L14) — plus the gem patch proposal

**Status:** DECIDED (L14 law; the gem patch is the recorded consequence)
**Decision:** Every completion request carries a seed drawn fresh at
random per request, fill-if-absent: if the caller supplies an explicit
seed, it wins (deterministic replay/tooling); otherwise ProviderSeam
injects a fresh random Integer. EVERY retry carries a fresh seed (an
identical body+seed re-attempt is the FM-03 replay mechanism — made
structurally impossible, not merely discouraged). The dedup guard
(I01's canonical-text uniqueness) is the write-time complement: a guard
refusal mutates the body at turn 1, breaking replay determinism at the
source. The served seed is audited per call (DR-12 amendment proposes
`usage_events.seed`).
**Substrate gap + exact patch proposal** (destination: implementation arc
entry 0, gems — the gem is read-only during design): `Protocol.build_request`
emits a CLOSED parameter set with no `seed` (lib/fast/completions/protocol.rb),
and `Client#stream` takes no seed kwarg. Proposed minimal extension,
mirroring the existing `temperature` pattern verbatim (§9.7 "only when
explicitly set"):
```ruby
# Protocol.build_request: new kwarg seed: nil
params[:seed] = seed unless seed.nil?
# Client#stream: new kwarg seed: nil, forwarded to build_request
```
**Delivery path (named at judge F1 — a bare kwarg is dead code on the
Chat path):** `Chat#step` calls `@client.stream` with a FIXED kwarg set
(model/messages/instructions/tools/thinking/max_tokens — no temperature,
no seed; lib/fast/completions/chat.rb), so a Client-level kwarg never
reaches the wire through the mandated turn primitive. kquest's
ProviderSeam — which already constructs the Client (DESIGN §2.3) — wraps
it in a **ProviderSeam-owned Client decorator** (a subclass whose
`#stream` fill-injects the per-request seed before delegating; nil →
random Integer, explicit seed wins). No Chat surface is proposed — the
Chat owns conversations, not sampling. Mechanism choice flagged for
ratification: (a) this decorator (judge recommendation; kquest-side
code, no Chat change) vs (b) widening the gem patch to a Chat-level
seed/temperature surface (implementation arc entry 0 scope decision).
Wire note: the OpenAI wire accepts an optional `seed` integer; the gem's
parameters-verbatim posture means no dialect work is needed (an
engine that ignores it ignores it). Interim posture until the patch
lands: the SAME decorator injects a jittered temperature per request —
`Client#stream` forwards temperature to `build_request` when set, the
one sampling lever that CAN reach the wire through `Chat#step`'s fixed
kwargs — so FM-01/FM-03 protection degrades to temperature-jitter +
dedup-guard — recorded in the design (§8), not hidden.
**Rationale:** L14: the engine pins `DEFAULT_SEED = 0` and identical
(body, sampling params) replays byte-identically at ANY temperature —
proven at temperature 2.0 (gateway-20261118T-sampling.md). The operator's
recorded ruling ("absolutely randomize the seed. we're trying to build a
knowledge base, not an eval suite around a knowledge base builder")
ordered fill-if-absent so explicit seeds still win; this record implements
that ruling as law and names the one substrate change it needs.
**Alternatives considered:** (a) gateway-side injection (as the PoC's
sampling band was deployed) — rejected: injected values are applied after
the client logs its request, so the audit record would disagree with the
wire; kquest's cost honesty needs the loop to know the seed it sent;
(b) temperature-only divergence — falsified by the PoC note (replay
survives any temperature); (c) time-derived seeds (e.g. epoch) — rejected:
correlated across concurrent sessions; a fresh random Integer per request
is the honest fill; (d) `raw_stream` with hand-built bodies to smuggle a
seed — rejected: raw_stream is the proxy surface (no accumulation, no tool
interpretation); using it would re-implement the Chat.

## DR-08 — Subagent tool-surface restriction: the read-only survey profile, no recursion

**Status:** DECIDED
**Decision:** A subagent's tool surface is a NAMED PROFILE — a config-data
restriction of the parent session's registered surface, enforced by the
ToolHarness (the profile IS the registration; an unregistered tool call
lands in the gem's in-band "no such tool" path, and the harness's refusal
teaches with the profile's legal list — FM-12). Day-one profile `survey`:
status, search, list, paths, sliced reads, graph export reads — read-only.
NO mutation tools, NO web fetch, NO subagent spawn (no recursion, one
level of nesting only). Profiles are declared per quest-local config, so
a future synthesis phase can name a wider profile without code changes.
**Rationale:** The PoC's band-survey workers (quest 2 v4) needed exactly
this shape: parallel, context-free, read-only surveys whose digests merge
into the parent. Restriction-by-registration (not by prompt discipline)
is the only shape that cannot be talked around, and the gem's unknown-tool
contract gives it an in-band, teaching failure mode for free. Recursion is
excluded because spend attribution and deadline accounting stay legible
at one level (the PoC's wedge #3 was already a spawn-adjacent monitoring
failure at ONE level).
**Alternatives considered:** (a) full parent surface + prompt instructions
to behave — rejected: prompt-discipline restrictions are the class of law
the PoC repeatedly proved fragile; (b) code-defined per-purpose tool
subsets — rejected: config data survives quest-local law changes without
code edits (the SKILL-law pattern); (c) allow nesting to depth 2 —
rejected: no measured need, doubles the wedge/accounting surface.

## DR-09 — Context budget: hard vs advisory lines (the 78% lesson)

**Status:** OPERATOR-RULING-NEEDED
**Decision:** The context-budget policy lines are split hard/advisory, but
WHICH lines are hard is an operator economics call (below). Loop-side
facts this record fixes: the transcript ceiling line is per-provider
config (DR-06); whatever is ruled HARD is enforced at TURN BOUNDARIES
(refuse/bank/route), never mid-turn; whatever is ruled ADVISORY is enforced
by teaching (refusals and caps that name the legal alternative), never by
silent truncation.
**Rationale:** The measured lesson (2026-11-17-arc-decompose-review.md
§Q5): corpus ingestion was 78% of a 79,677-token context while the entire
graph loop was 5.1% — so the lines that matter are the READ lines, not the
tool-result lines. But hard ceilings have a proven failure mode: the
PoC's hard budget/phase caps produced reportless stops ("Organic exits
were all reportless", arc-run-20261122T-quest2-arc-summary.md §2). Making a
line hard trades silent context blowouts for visible strandings; that
trade belongs to the operator, with the ENTRY 6 never-reportless finisher
as the backstop either way.
**Options:**
- **(A) All-hard:** slice caps, transcript ceiling, result caps, and
  per-source session slicing all refuse. Maximum predictability; maximum
  stranding risk; the most operator interrupts.
- **(B) All-advisory:** teaching refusals everywhere, no hard stops below
  the provider's own context error. Cheapest in interrupts; re-opens the
  78% blowout class the lesson is about.
- **(C) Mixed (recommended):** HARD = token-spend cap, web-call cap,
  transcript ceiling (FM-02/FM-17 — the lines whose crossing is silent
  failure or real money); ADVISORY-with-teaching = read-slice caps and
  result-size caps (the lines whose crossing is waste, not failure), with
  StreamWatch signals feeding ENTRY 7.
**Recommendation:** (C). Hard only where the PoC proved the crossing is
silent or costly (reportless stops, ceiling deaths, spend); teaching
everywhere the fix is behavioral (sliced reads, extract-as-you-read).
**Alternatives considered:** a single global context budget knob —
rejected: the 78%/5.1% split shows the lines are orthogonal (reads vs
tools); one knob cannot teach and enforce at once.

## DR-10 — Subagent spawn discipline + band-survey codified

**Status:** DECIDED
**Decision:** (1) Spawn discipline (wedge #3 law): every spawn is a
command that RETURNS IMMEDIATELY; verification is ALWAYS a separate
command keyed by run id against the run registry; a missing tool result
never implies a dead child. (2) Band-survey is the codified synthesis
survey pattern: N survey-profile workers (DR-08) over DISJOINT numeric
bands of the graph (the observed shape: five workers, K1–199 … K750–821),
each returning a bounded band digest; disjointness and coverage of the
target id range are checked at spawn (union = range, pairwise disjoint);
the parent merges digests under ContextBudgeter accounting. Child runs
are sessions (I01 DR-13 makes the D10 chain total by construction) with
run deadlines (`subagent_timeout_s` default 1800).
**Rationale:** Both halves are PoC-proven, not speculative: the wedge #3
incident (arc-run-20261122T-llm-trading-v3-launch.md §Incident ledger) is
the spawn discipline's origin, and the band-survey is the one survey
pattern that produced a complete, intervention-free report (quest 2 v4,
arc-run-20261122T-quest2-arc-summary.md §3 item 7) where the digest
alternative was operator-rejected as "census without context". tart's
subagent core (lib/tart/subagents — run registry, profiles, detached
runs) is the prior art cited per D1; none of it is imported.
**Alternatives considered:** (a) foreground/blocking spawns — rejected:
the parent's turn wedges on the child (exactly wedge #3's shape);
(b) single-session mega-survey — rejected: it is the 78% blowout with a
synthesis prompt (the cache-wall note's "mega-synthesis" failure);
(c) digest/summary-first surveys — operator-rejected in the PoC with the
recorded phrase above.

## DR-11 — Prompt-echo prohibition: live config reads, audit-column identity

**Status:** DECIDED
**Decision:** Phase/session prompts never carry model or provider
identity strings, nor any config value whose audit home is a column;
identity and config provenance live ONLY in the audit columns
(`sessions.model`, `usage_events.model`, provider rows). Prompt assembly
reads LIVE config at session start and at phase boundaries (the
live-re-readable channel, R-060/ENTRY 6); a config change mid-quest never
edits a running session's context — it lands through pause (DR-04).
**Rationale:** The PoC's model-swap census needed three independent
signals to prove sessions hit the new endpoint because "the lone
`glm-5.3-flash` string in the transcript is the ledger's `quest.model`
provenance echoed into the phase prompt" (arc-run-20261122T-llm-trading-
v3-launch.md §Resume). An echoed config string is stale-on-arrival
misinformation that costs audits real time; the audit columns are
authoritative by construction.
**Alternatives considered:** (a) echoing the model id "for the model's
awareness" — rejected: no measured benefit, proven audit cost;
(b) verifying swaps by transcript string search — rejected: this record
removes the string; the census signals (connection counters, usage rows,
socket ownership) are the verification.

## DR-12 — Prior-law amendment proposal: usage_events cache/reasoning/seed columns

**Status:** OPERATOR-RULING-NEEDED
**Decision:** PROPOSED (as a patch record — design/I01-core-model is NOT
edited by this lane): extend `usage_events` with three additive columns so
the loop's measurable laws have a home in the D10 ledger:
```sql
-- proposed additive patch to I01 artifacts/schema.sql (usage_events):
ALTER TABLE usage_events
  ADD COLUMN cache_read_tokens  integer NOT NULL DEFAULT 0
    CONSTRAINT ck_usage_cache_read  CHECK (cache_read_tokens  >= 0),
  ADD COLUMN cache_write_tokens integer NOT NULL DEFAULT 0
    CONSTRAINT ck_usage_cache_write CHECK (cache_write_tokens >= 0),
  ADD COLUMN reasoning_tokens    integer NOT NULL DEFAULT 0
    CONSTRAINT ck_usage_reasoning   CHECK (reasoning_tokens    >= 0),
  ADD COLUMN seed                integer
    CONSTRAINT ck_usage_seed_range CHECK (seed IS NULL OR seed >= 0);
```
Carriers: cache_read/cache_write from the gem's `Usage` (the prefix-cache
economics of FM-24 become measurable, not folklore); reasoning_tokens
(thinking-model cost honesty); seed (L14 audit: which seed served which
call — makes replay-loop diagnosis a query). All four are additive,
nullable-or-defaulted, and touch no existing constraint.
**Rationale:** The gem already reports all of these
(lib/fast/completions/types.rb `Usage`), and this iteration's policies
(cache-wall routing, seed-law verification) read them per call; without
columns the data is discarded at the call site. D10's spirit ("every LLM
call accounted") argues for keeping what the wire gives us.
**Options:**
- **(A) Amend as proposed** (4 additive columns): full cost honesty; a
  small I01 amendment + re-run of its DDL/probe battery.
- **(B) Cache columns only** (drop reasoning/seed): covers the strongest
  economic case (FM-24); leaves L14 audit to transcript parsing.
- **(C) No amendment**: zero prior-law churn; cache-wall and seed audits
  rely on deriving from transcripts (L10 permits derivation, but the
  derivation is a nontrivial parser, and the seed is not in the
  transcript at all without the DR-07 patch also landing).
**Recommendation:** (A). The columns are additive, the gem supplies the
values at the exact call site that already writes the row, and two of
this iteration's laws (FM-24 measurability, L14 audit) otherwise depend
on fragile derivations.
**Alternatives considered:** a separate `llm_call_details` side table
keyed by usage_events — rejected: splits the ledger's single-row
completeness and adds a join to every budget rollup; dropping
cache-token recording entirely and treating the cache wall as
unmeasurable — rejected: it would leave FM-24's threshold
provider-config with no way to calibrate.

## DR-13 — Streaming protocol consumption: adopt the gem's dispatch wholesale; hooks for audit; never re-implement

**Status:** DECIDED
**Decision:** The loop uses `Chat#step` as the only turn primitive and the
gem's event stream as the only observation surface. It does not
re-implement request building, SSE parsing, tool-argument streaming, batch
execution, or retry classification. Loop-owned concerns attach at the
gem's designed seams: telemetry sinks (SpendRecorder, StreamWatch),
`before_tool_call`/`after_tool_result` hooks (ToolHarness audit + guards),
and the registered tool classes (ENTRY 5). The gem's tolerance decisions
are adopted as law: dropped chunks stay dropped-and-counted (FM-14),
malformed args finalize to the loud marker (FM-11), salvage partials are
audit (FM-15), cancellation never fabricates a terminal (FM-19).
**Rationale:** The gem's contracts are fixture-pinned (byte-faithful wire
parity; I61/I06 specs) and its failure discipline is the product of the
same PoC lessons this iteration consumes. A parallel implementation would
fork every one of those guarantees. The one place the gem lacks a needed
feature (seed) is escalated as a patch proposal (DR-07) rather than a
workaround re-implementation.
**Alternatives considered:** (a) kquest-side dispatch over `raw_stream`
(full control of the request body, seed included today) — rejected:
re-implements accumulation, tool-args streaming, salvage, and batch
semantics to gain one field; the honest path is the patch; (b) wrapping
`Client#stream` directly and hand-rolling the tool batch — rejected:
duplicates Chat's concurrency/join/cancel discipline (the hardest-won part
of the gem, per its D5/D7/D8 spec annotations).
