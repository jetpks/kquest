## node_add

Fused creation: a claim, an evidence span, or evidence + its claims
atomically (`supports_new`); runs the dedup candidate check before the
write; stamps urns (never supplied); the span is proven byte-present in
the snapshot blob BEFORE any write — a refusal creates nothing.

### canonical

```json
{"label": "claim", "text": "In Brinson, Hood & Beebower's study of 91 large U.S. corporate pension plans (1974-1983), long-term investment policy explained an average 93.6 percent of the variance of each plan's total return.", "terminal": {"type": "primary-empirical", "basis": "the study's own data (Table II)"}}
```

```json
{"label": "evidence", "src": "C13", "span": "explained on average fully 93.6 per cent of the total variation in actual plan return", "reading": "Investment policy (normal weights and market index returns) explained an average 93.6 percent of the variance in actual plan returns across 91 plans.", "supports_new": [{"text": "Long-term investment policy - normal asset class weights applied to passive benchmark returns - explained an average 93.6 percent of the variance of each plan's total return.", "terminal": {"type": "primary-empirical", "basis": "the study's own data"}}]}
```

### refusal: duplicate-label

```
REFUSAL: DUPLICATE-LABEL: a claim with this canonical text already exists in this quest (K12) — never re-add it; attach evidence to K12 instead, or reword a genuinely distinct finding; canonical: {"label":"claim","text":"…"}
```

EVIDENCE: schema-law (uq_claims_quest_canonical)

### refusal: duplicate-span

```
REFUSAL: DUPLICATE-SPAN: this exact span is already anchored in this quest (E7 on C13) — near-duplicate evidence attaches edges to the existing evidence node, never clones a row; canonical: {"label":"evidence","src":"C13","span":"…","reading":"…","supports":["K1"]}
```

EVIDENCE: schema-law (uq_evidence_quest_span)

### refusal: unanchored-span

```
REFUSAL: UNANCHORED-SPAN: span not byte-present in the snapshot blob of C13 — spans are VERBATIM, byte-for-byte from the slice you just read (never retyped, never re-flowed); nearest fragments: "return from various periodic-cum-threshold rebalancing strategies compared to a" | "buy-and-hold strategy is only 11 basis points and that the mean difference of"; span joins lines 10–11 — take a single-line fragment exactly as printed
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/notes/arc-run-20261121T-quest2-failure-taxonomy.md §1 class h

### refusal: span-beyond-snapshot

```
REFUSAL: SPAN-BEYOND-SNAPSHOT: span offsets 48112..48201 exceed the snapshot length 48000 of C13 — anchor inside the snapshot (0-based half-open character offsets into the snapshot blob, never into a chunk); read the slice first: {"tool":"source_read","src":"C13","offset":1,"limit":60}
```

EVIDENCE: schema-law (ck_evidence_span_bounded)

### refusal: agenda-source

```
REFUSAL: AGENDA-SOURCE: C5 is role=agenda — agenda sources are readable and retrievable but never anchorable or citable; anchor evidence only in role=citable sources (source_list shows roles)
```

EVIDENCE: schema-law (ck_evidence_citable)

### refusal: unknown-field

```
REFUSAL: UNKNOWN-FIELD: basis is not a field of claim — legal fields: text, terminal; basis belongs INSIDE terminal: {"type":…,"basis":…}; canonical: {"label":"claim","text":"…"}
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/notes/arc-run-20261121T-quest2-teaching-patch.md §preflight 2 hunk 4 (STRAY_HINTS)

### refusal: fused-shape

```
REFUSAL: FUSED-SHAPE: supports_new must be a non-empty array of field objects, e.g. "supports_new":[{"text":"…"}] — a JSON-encoded string is coerced when it parses; this one did not; canonical: {"label":"evidence","src":"C13","span":"…","reading":"…","supports_new":[{"text":"…"}]}
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/notes/arc-run-20261121T-quest2-failure-taxonomy.md §1 class a

### refusal: fused-direction

```
REFUSAL: FUSED-DIRECTION: supports_new lives on the EVIDENCE call — {"label":"evidence","src":"C13","span":"…","reading":"…","supports_new":[{"text":"…","terminal":{…}}]} creates claim+evidence+edge atomically (span proven before any write; failure creates neither); a claim-side call cannot name its own evidence; claim first only when wiring later with edge_add
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/notes/2026-11-17-descent-observation.md §incident A

### refusal: terminal-shape

```
REFUSAL: TERMINAL-SHAPE: terminal must be an object {"type":T,"basis":"…"} with T one of definitional-mathematical, primary-empirical, residual-uncertainty — a JSON-encoded string that parses is coerced and the PARSED object is stored (you will see "coerced terminal:string→object" on the success line); basis belongs INSIDE terminal
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/notes/arc-run-20261121T-quest2-teaching-patch.md §STRING-COERCION LAYER live-risk note 1 (the cold-verifier bomb)
