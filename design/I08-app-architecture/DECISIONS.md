# I08 — app-architecture: DECISIONS

> Decision records for the hosting entry. Prior-law decisions are cited,
> never re-ruled; the records below decide only what this entry owns.
> Judgment calls that belong to the operator are flagged
> OPERATOR-RULING-NEEDED with Options + Recommendation.

## DR-01 — Slice boundaries: six domain slices + root app; the Engine is not a slice

**Status:** DECIDED (derived from BRIEF §2/§6 + D8; the mapping itself has
no judgment residue)
**Decision:** Six slices, one per HTTP-serving subsystem —
`slices/corpus` (Corpus), `slices/retrieval` (Retrieval), `slices/graph`
(Graph), `slices/quest` (Process), `slices/reports` (Product),
`slices/watch` (Assurance surfaces). Root `app/` keeps the substrate
shell (auth, home/dashboard mount, healthcheck). The Engine — I04's ten
components — lives in `lib/kquest/engine/`, NOT a slice: it has no HTTP
surface, its only host process is the quest worker, and slices only read
its durable output and drive its lifecycle through quest/steering
actions. Retrieval is a slice of its own (not folded into corpus)
because the registry/embed-job/hybrid-query surface is operator-facing
(register/retire/A-B pages) and independently consumed by the retrieve
tool; Assurance is a slice (`slices/watch`) because the SSE transport +
alert queries are a coherent non-domain surface adopting a coherent
substrate.
**Rationale:** D8 adopt-don't-rebuild pins the root-app half; the
subsystem list in BRIEF §2 is ratified, so the slice map is a projection,
not a new cut. Keeping the engine out of the slices preserves the I04
§5.4 rule that operator and orchestrator launches compete for ONE gate
in ONE process class — a slice that could host a loop would re-create
the steer-while-running race D5 killed.
**Alternatives considered:** (a) one slice per BRIEF layer (§6) — rejected:
the six app/UIS layers don't map 1:1 to HTTP surfaces and would strand
Engine and tool surface; (b) engine-as-slice with actions for
pause/spawn — rejected: HTTP-hosted loop control is exactly the racing
surface D5 forbids; (c) no slices (everything in root app) — rejected:
the substrate's own structure scales by slices, and R-073 asks for the
map.

## DR-02 — Worker process model: one quest worker per ACTIVE quest + one job worker

**Status:** DECIDED (operator ruling 2026-11-23: **A — for now, with a
recorded REVISIT TRIGGER**)
**Ruling (operator, recorded verbatim):** "A for now, but i want to
revisit this later." → The per-active-quest worker model ships day one;
the process-model question REOPENS at the operator's discretion (the
natural trigger: enough concurrent active quests that process count or
memory pressure becomes measurable — the record's option B/C tradeoffs
stay live).
**Decision:** TWO worker process classes. (1) The **job
worker** — the adopted substrate shape (`bin/worker.rb`; async-job redis
processor) — one process, dequeueing corpus pipeline jobs
(fetch/chunk/embed) across all users. (2) The **quest worker** — one OS
process per ACTIVE quest, booted on `active`, exited on leaving `active`
— hosting the engine (phase runner, launch gate, watcher, reaper, run
registry). Concurrency across quests is process-level (N active quests =
N processes); concurrency within a quest is the engine's own
single-writer discipline (D5: one active writer per quest, so a pool
inside a quest is meaningless).
**Rationale:** The launch gate makes the quest worker's identity the
liveness signal (I04 DR-05: worker liveness from the registry; a dead
worker's entry disappears with it). One process per active quest gives
the crash blast radius the reaper expects (a killed worker orphans
exactly one quest's sessions), makes the transcript watcher's in-process
byte tail honest (it tails the same process's blobs), and matches the
PoC's per-quest driver process. A shared worker pool would make worker
death multi-quest and the run registry multi-tenant in-process — more
state, worse blast radius, no benefit while the one-writer law holds.
The substrate explicitly ships no managed worker topology and defers
the hosting decision to each project — this record is kquest's answer
for the operator to rule on.
**Options:**
- **(A) One quest worker per active quest + one job worker (proposed).**
  Blast radius = one quest; registry/liveness simplest; process count
  scales with active quests (fine: quests are operator-initiated and
  few); the PoC precedent is exactly this shape.
- **(B) A fixed pool of K quest workers, each holding several quests.**
  Cheaper processes, but worker death orphans several quests at once,
  the in-process run registry/watcher tail spans quests, and D5's
  one-writer law forces cross-quest serialization inside each worker
  anyway.
- **(C) A single global quest worker (async concurrency inside).**
  Simplest ops, worst blast radius; the transcript watcher tails
  transcripts it does not own; the PoC's own tender-race lesson argues
  against one process mixing quests.
**Recommendation:** (A).
**Alternatives considered:** embedded loop in the web app (falcon
action spawns phases) — rejected outright: the web process must never
host writer sessions (D5 + the deploy shape's process separation);
advisory-lock-based multi-quest workers — rejected: I01 DR-12 already
rejected advisory locks as an enforcement home.

## DR-03 — SSE event envelope: the substrate's shape, adopted unchanged

**Status:** DECIDED (D8: the transport is exactly what the substrate is
for)
**Decision:** One redis stream per quest
(`kquest:sse:quest:<uuid>`, `XADD … MAXLEN ~ 5000`) + one per-user
global stream (`kquest:sse:user:<uuid>`) for cross-quest alerts. Entry
fields exactly two: `type` (event name from the DESIGN §3.2 catalog) and
`data` (single JSON object) — the ticker pair's idiom
(`app/actions/ticker/publish.rb`). The redis `ms-seq` entry id rides the
SSE `id:` line; `Last-Event-ID` resume via `Template::SSE.entry_bound`
(exclusive start bound), backlog-then-live-tail with the
subscribe-first/backlog race discipline and 15 s heartbeats —
`app/stream_action.rb` + `lib/template/sse/fanout.rb` adopted wholesale.
Gating in `#handle` before `render_stream` (substrate law) against
`v_resource_visibility`.
**Rationale:** The transport is production-proven in the substrate with
exactly the properties the quest-watch successor needs (resume, replay,
fan-out, heartbeats). A new envelope would buy nothing and forfeit D8.
MAXLEN 5000 (vs the ticker's 1000) is the only tuning: quests run for
days and the boundary-event volume (a phase per ~45 min plus per-tool
events) needs a reconnect window measured in hours, while the PG
ledgers remain the history — the stream is a tail, not a store.
**Alternatives considered:** (a) one global stream with per-quest
filtering — rejected: every client pays every quest's traffic and the
MAXLEN window shrinks per-quest; (b) PostgreSQL LISTEN/NOTIFY — rejected:
redis is already required (job queues) and the substrate's fan-out
(Async::Queue per subscriber) exists; (c) richer envelope (per-field
redis stream entries, no JSON) — rejected: the substrate frames
`data` as one JSON field and SSE payloads are heterogeneous by event
type; JSON carries the shapes the catalog pins per event.

## DR-04 — Redis's exact role: job queues + SSE streams + worker-registry liveness

**Status:** DECIDED (two-thirds is substrate law; the third is pinned to
prior rulings)
**Decision:** Redis carries exactly three uses. (1) **Job queues**: the
async-job redis processor (`config/providers/job_queue.rb`; Inline in
test) with the shared Delegate construction — the corpus pipeline's
queue. (2) **SSE streams**: per-quest and per-user streams as XADD/XREAD
fan-out (DR-03) — pub/sub semantics via redis STREAMS and blocking XREAD
(the substrate's dedicated-connection pattern), not PUB/SUB channels.
(3) **Worker-registry liveness**: heartbeat keys
`kquest:worker:<uuid>` with TTL 3× the 10 s heartbeat (value JSON
`{pid, kind, host, boot_at, quest_id?}`) — read by the launch gate
inside its gate transaction (I04 DR-05). Redis holds NO durable domain
state: nothing a redis flush loses is anything the system cannot
reconstruct from PG (L7); liveness is runtime state by the I01 DR-12
posture, which is exactly why it lives here and not in a schema column.
**Rationale:** The substrate requires redis for the SSE transport and
the job processor; I04 DR-05 requires a worker registry whose entries
disappear with dead workers — a TTL key IS that semantic, with no
reaper-of-the-reaper to build and no pidfile class of staleness bugs
(the PoC's repeatedly-broken artifact). Tenancy of the liveness keys is
per-worker, not per-quest, so the gate's check answers "is the worker
that holds this session alive" directly.
**Alternatives considered:** (a) worker liveness in PG (a heartbeat
column) — rejected twice over: I04 DR-05 rejected new schema for
liveness, and a column can go stale exactly like a pidfile; (b) PG
advisory locks as liveness — rejected: I01 DR-12's ruling (runtime state
is not durable law; invisible to ops); (c) redis PUB/SUB for events —
rejected: no replay, no Last-Event-ID resume; streams are the
substrate's proven shape.

## DR-05 — Steering console interaction law: pause → interactive session → resume; menus present, never enforce

**Status:** DECIDED (this is ratified law wired, not a new ruling: D5,
I04 DR-04/DR-05/DR-06, I06 SR-16, I07 DR-06/DR-08, the standing lesson)
**Decision:** The steering console implements I04 DR-04 exactly: pause
request → ledgered `active → paused` → delivery at the next turn
boundary (bank, else `Chat#cancel` — FM-19) → steering payload lands as
durable config (`process_config`, `model_config`, budget columns,
law overlays — re-read at session start + every phase boundary, I06
§6.2) → `paused → active` → fresh worker, cold-boot session, attempt
numbering continues. Every runtime-decision menu the design accumulated
(DESIGN §5.1: the transcript-ceiling menu A/B/C exactly as I04 DR-06
was ruled, retry-cap, finisher-phase budget, slow-stall-unattended,
verification-failed rework, graph_invalid stop-loud, briefing caps,
divergence findings, model-qualification overrides) is PRESENTED with its
evidence; the operator picks; the choice is recorded in the existing
ledgers (lifecycle events, config provenance); NOTHING auto-enforces —
no menu pre-selects, no timeout chooses, the unattended window PAUSES
(SR-19), it never decides. Config controls are structurally disabled
while a quest is `active` — the console cannot express
steer-while-running (D5's rejection, enforced by the UI's own shape).
**Rationale:** The standing lesson (third occurrence, now design-phase
law): when a policy call is really a runtime operator call, design the
evaluation/pause surface, not binding policy. The PoC evidence chain —
the tender race (why steer-while-running is unsafe), the executed
ceiling ruling (what the operator actually chose when the menu opened),
the WEB_BUDGET_RAISE precedent (what a recorded raise looks like) — all
lands in this one surface.
**Alternatives considered:** (a) queued steering read at turn
boundaries without pause — rejected by I04 DR-04 as
steer-while-running with extra steps; (b) auto-resume after a
presented menu times out — rejected: it would be the system choosing
(against the DR-06 ruling verbatim: "the operator decides"); (c) a
separate admin-only API bypassing the console — rejected: one writer
per quest means one door for steering, and the console is it (L13:
same tools, same constraints, same audit).

## DR-06 — The `ladder_passes` durable carrier: adopt the I07-named table as a schema patch at arc entry 2

**Status:** DECIDED (I07 judge-F8 deferred the shape here with the
enforcement posture already ruled — this record adopts, it does not
re-rule)
**Decision:** Adopt the named shape (DESIGN §10 DDL): `ladder_passes
(id, model, rung ∈ {probe,smoke,partial,full}, serving_stack, passed_at,
evidence_ref, passed_by)`, UNIQUE (model, rung, serving_stack,
passed_at). It is NEW schema, not a prior-law amendment, and this entry
writes no SQL (Grounds): the DDL is a decision-record patch proposal
landing at implementation-arc entry 2 with the I06 TSVs. The enforcement
half stays exactly as I07 ruled: day one the rule is REVIEWABLE — the
routing-map editor cites `ladder_passes` ids per model per phase kind,
human-checked at config time, the override recorded (who/why), never
blocked; a `quests.model_config` → `ladder_passes` FK is OPTIONAL and
OFF day one (the ladder is an eval framework, not binding policy — I07
DR-06 as ruled).
**Rationale:** I07 §7's law: a model's rung is a property of (model,
serving stack, date), never a permanent title — the table's uniqueness
key IS that sentence; `evidence_ref` + `passed_by` keep the record a
citable artifact (the routing config cites evidence, I06 §7). The
operator-override-recording posture is the ratified DR-06 ruling, so
the carrier is a citation surface, not an admission gate.
**Alternatives considered:** (a) store rung passes in
`process_config`/`model_config` JSON — rejected: unqueryable, unciteable
per (model, rung, stack, date), and config rows are quest-scoped while
qualification is user/global-scoped; (b) files/dirs per candidate (the
PoC fleet-ladder shape) — rejected as the PRIMARY carrier (PoC data is
D7 fixtures-only) though `evidence_ref` may point at preserved rung
transcripts; (c) defer the carrier to the arc with no shape — rejected:
I07 judge-F8 named this entry as the decider; deciding the shape now is
what was deferred HERE.

## DR-07 — Dev/prod parity posture: same seven parts; the substrate's environment switches are the only differences

**Status:** DECIDED (the substrate's own switches define the posture)
**Decision:** Dev and prod run the same seven moving parts (app, quest
worker, job worker, postgres+pgvector, redis, object storage, gateway —
the gateway being the one part dev may omit, direct :3000). The ONLY
behavioral switches are the substrate's own `Hanami.env?` gates —
Shrine memory storages in test/filesystem otherwise
(`app/attachment_uploader.rb`), Inline job processor in test/redis
otherwise (`config/providers/job_queue.rb`) — plus credentials source
(local master.key vs env master key, inert credentials in prod per the
Containerfile) and force-ssl/host-authorization (on in prod,
`config/settings.rb` defaults off in dev). Same schema (`hanami db
prepare`), same redis keys, same stream keys, same worker binaries, same
falcon topology. The object storage is a filesystem in BOTH dev and
prod day one (D8: S3-class later = editing one storages assignment).
**Rationale:** The PoC's files→Postgres and bash→jobs replacement was
predicated on parity being achievable at all (BRIEF §1: the web app
replaces the substrate, never the discipline). Every prod-only code
path is a place where "it worked in dev" stops being evidence; the
substrate was distilled to keep exactly this set of switches small and
named. Supervision (how prod KEEPS the processes running) is the one
genuine judgment call, split out to DR-08.
**Alternatives considered:** (a) docker-compose dev (all services
containerized) — recorded as an operator option, not the default: the
substrate's `bin/dev` + local services is the fastest inner loop and
the Containerfile already proves the prod image builds; (b) staging
environment as a third posture — deferred: nothing in the design needs
a third environment; a staging deploy is a hosting choice, not an
architecture difference.

## DR-08 — Production process supervision: falcon service blocks vs containers vs OS-level units

**Status:** DECIDED (operator ruling 2026-11-23: **A**)
**Ruling (operator, recorded verbatim):** "A but we should already have
a job system bundled in hanami-base." → Confirmed A. The job half is
NOT new machinery: the job worker IS the bundled hanami-base job
system (config/providers/job_queue.rb + the async-job redis processor
+ bin/worker.rb) adopted as-is per D8. The operator's note is recorded
as a SUBSTRATE expectation: if hanami-base is to carry a fuller
managed job topology (supervision, retries, scheduling), that is
hanami-base-space work, flagged to the build phase — kquest's design
adopts what is bundled and adds no job machinery of its own.
**Decision:** Supervise BOTH worker classes as falcon
`service` blocks in `falcon.rb`, alongside the web service: the same
supervisor, the same config file, restart semantics for free, and the
`Async` reactor both workers already run on is falcon's native
runtime. The quest worker's supervisor block boots a launcher loop that
keeps exactly one worker process per ACTIVE quest (a tiny loop over the
lifecycle ledger — the same query that boots workers on `active`),
rather than one static service per quest (falcon services are static
config; quest workers are dynamic).
**Rationale:** One supervisor to operate, one file that names the whole
topology, and the Containerfile image already runs under falcon's
world. The launcher-loop sub-decision keeps quest-worker churn (boot on
active, exit on pause) out of the supervisor's config surface.
**Options:**
- **(A) falcon service blocks + a quest-worker launcher loop
  (proposed).** Matches the substrate's topology idiom; no new
  supervisor software; `falcon host` restart semantics for all three
  process classes.
- **(B) Full containerization (Containerfile per process class under an
  orchestrator).** Strongest isolation and the most standard ops story;
  adds an orchestrator to the required-parts list (R-077 lists none) and
  a second way to run things (parity cost).
- **(C) OS-level units (launchd/systemd).** Familiar; splits the
  topology definition across supervisor config + falcon.rb; macOS-local
  (launchd) mismatches a likely linux prod host.
**Recommendation:** (A), with (B) explicitly left open — the
Containerfile pattern is in-tree and a container move later is a deploy
change, not an architecture change (the binaries are identical).
**Alternatives considered:** no supervision at all (manual restarts) —
rejected: the reaper story presumes worker death is *eventual and
noticed*, and unattended multi-day quests cannot rely on an operator
restarting a crashed job worker; a supervisor is the minimum ops the
never-reportless law implies.

<!-- Decision-record index: DR-01..DR-08. OPERATOR-RULING-NEEDED: DR-02,
     DR-08. -->
