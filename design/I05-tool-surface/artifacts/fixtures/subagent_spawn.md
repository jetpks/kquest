## subagent_spawn

Spawn a profile-restricted child run over a DISJOINT numeric band of the
graph; returns IMMEDIATELY with a run id (verification is always a
separate subagent_status call — I04 DR-10/FM-20).

### canonical

```json
{"profile": "survey", "band": ["K1", "K199"], "brief": "survey derivation threads in this band for terminal coverage and bare claims"}
```

```text
subagent_spawn: run=run/7c1d profile=survey band=K1–K199 spawned (detached) — verify with {"tool":"subagent_status","run":"run/7c1d"}
```

### refusal: profile-unknown

```
REFUSAL: PROFILE-UNKNOWN: writer is not a declared profile for this quest — legal profiles: survey (read-only), operator (full surface); profiles are config, named per quest; a survey worker cannot mutate, fetch, or spawn
```

EVIDENCE: design/I04-agent-loop/DECISIONS.md §DR-08

### refusal: band-overlap

```
REFUSAL: BAND-OVERLAP: bands must be pairwise disjoint and cover the target range — yours overlaps K150–K199 with a sibling worker; re-partition (the merge detects gaps by band, so coverage must be exact)
```

EVIDENCE: design/I04-agent-loop/DECISIONS.md §DR-10
