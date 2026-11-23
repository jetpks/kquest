## edge_add

Ordered typed edge: `derives_from` claim→claim (a wired claim carries no
terminal — clear via node_set first).

### canonical

```json
{"from": "K1", "type": "derives_from", "to": "K37"}
```

### refusal: unknown-node

```
REFUSAL: UNKNOWN-NODE: <id> does not exist in this quest — resolve by K-alias or urn (kb:claim:…); if you meant a claim not yet created: create it first (node_add label=claim), re-submit, or wire later with edge_add
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/notes/2026-11-17-arc-decompose-review.md §Q6.1

### refusal: duplicate-edge

```
REFUSAL: DUPLICATE-EDGE: K1 derives_from K37 already exists — derivation lists are ordered sets, never repeated; view the current list with node_get K1
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/repos/tart/lib/tart/tools/graph.rb §insert_edge (edge already exists)

### refusal: self-derivation

```
REFUSAL: SELF-DERIVATION: a claim never derives from itself (K37 → K37) — derivations bottom out at typed terminals or open frontier, not cycles; wire the claim to what GROUNDS it
```

EVIDENCE: schema-law (ck_claim_derivations_no_self)

### refusal: wrong-endpoint

```
REFUSAL: WRONG-ENDPOINT: derives_from requires a claim target, got evidence — wire claim-to-claim; evidence links to claims through node_add label=evidence (supports/contradicts), not edge_add
```

EVIDENCE: design/I01-core-model/DESIGN.md §3.10
