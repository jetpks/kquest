## node_set

Field updates on one node: values flat at the top level or nested under
`fields:` (one container name); a nested null deletes an optional field;
a claim TERMINATES or DERIVES, never both.

### canonical

```json
{"node": "K24", "fields": {"text": "Long-term investment policy explained an average 93.6 percent of the variance of each plan's total return across the 91 plans studied (1974-1983)."}}
```

### refusal: unknown-field

```
REFUSAL: UNKNOWN-FIELD: newText is not a field of claim — legal fields: text, terminal; supply field values flat at the top level or nested under fields: (e.g. {"node":"<id>","text":"…"}); a key supplied both flat and under fields: must carry the same value
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/notes/arc-run-20261121T-quest2-teaching-patch.md §preflight 2 hunk 4 (STRAY_HINTS)

### refusal: flat-nested-collision

```
REFUSAL: FLAT-NESTED-COLLISION: text given twice (flat "a" and fields: "b") — supply it once, or make the two values identical; one value, one place: flat at the top level OR under fields:, never both
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/notes/arc-run-20261121T-quest2-teaching-patch.md §probe gate P5

### refusal: dual-arm

```
REFUSAL: DUAL-ARM: K37 has derives_from — a claim TERMINATES or DERIVES, never both; clear the derivation first (re-point the edge_add), or set the terminal on a claim that derives from nothing
```

EVIDENCE: design/I01-core-model/DECISIONS.md §DR-09

### refusal: stamped-field

```
REFUSAL: STAMPED-FIELD: urn is stamped by the tool — it is never supplied (kquest mints urns; the model never transcribes hashes); canonical: {"node":"K<n>","fields":{"text":"…"}}
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/repos/hermit-kb/quest/skills/quest/SKILL-claim-graph.md §claims

### refusal: unknown-node

```
REFUSAL: UNKNOWN-NODE: <id> does not exist in this quest — resolve by K-alias or urn (kb:claim:…); if you meant a claim not yet created: create it first (node_add label=claim), re-submit, or wire later with edge_add
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/notes/2026-11-17-arc-decompose-review.md §Q6.1
