## frontier_add

Pose a claim on the scored work queue: need (NAMES the underlying study —
authors, year, venue), uncertainty and relevance 1–5 (5 = no primary
grounding / load-bearing). The queue is computed-order
(uncertainty × relevance desc) — never re-add what is already open.

### canonical

```json
{"claim": "K1", "need": "the Brinson, Hood & Beebower (1986, Financial Analysts Journal) study the guide cites", "uncertainty": 4, "relevance": 5}
```

### refusal: frontier-re-add

```
REFUSAL: FRONTIER-RE-ADD: K1 already has an OPEN frontier entry — the frontier is a queue, not a log: do not re-add; take the top open entry (mass order, see list/mass), resolve it, frontier_close it; closed history never blocks a later round
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/notes/arc-run-20261121T-quest2-teaching-patch.md §preflight 2 hunk 5

### refusal: duplicate-need

```
REFUSAL: DUPLICATE-NEED: this need is already open in this quest ("primary empirical evidence on asset allocation impact vs stock selection" on K2) — needs are distinct strings (duplicate needs corrupt mass ranking); attach more evidence to the existing entry's claim, or close it and re-pose with a different need
```

EVIDENCE: schema-law (uq_frontier_need)

### refusal: score-range

```
REFUSAL: SCORE-RANGE: uncertainty and relevance are integers 1–5 — 5 = no primary grounding / load-bearing; need NAMES the underlying study (authors, year, venue), it is never a placeholder
```

EVIDENCE: schema-law (ck_frontier_uncertainty)

### refusal: unknown-node

```
REFUSAL: UNKNOWN-NODE: <id> does not exist in this quest — resolve by K-alias or urn (kb:claim:…); if you meant a claim not yet created: create it first (node_add label=claim), re-submit, or wire later with edge_add
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/notes/2026-11-17-arc-decompose-review.md §Q6.1
