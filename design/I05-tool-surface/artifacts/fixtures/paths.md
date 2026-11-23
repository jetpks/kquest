## paths

Derivation descent from one claim toward typed terminals (I01 Q1 shape);
refuses nothing but unknown starts and the depth belt.

### canonical

```json
{"node": "K1"}
```

### refusal: unknown-node

```
REFUSAL: UNKNOWN-NODE: <id> does not exist in this quest — resolve by K-alias or urn (kb:claim:…); if you meant a claim not yet created: create it first (node_add label=claim), re-submit, or wire later with edge_add
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/notes/2026-11-17-arc-decompose-review.md §Q6.1

### refusal: depth-cap

```
REFUSAL: DEPTH-CAP: derivation descent stopped at depth 128 — this chain does not bottom out within the budget; walk the tail with node_get/neighbors on the deepest node shown; terminal-only claims close chains
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/repos/tart/lib/tart/tools/graph.rb §PATHS_DEPTH_CAP line 195
