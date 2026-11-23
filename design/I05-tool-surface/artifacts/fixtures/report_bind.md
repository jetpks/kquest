## report_bind

The deterministic finalization pass (I02 §9): builds the citation index
(quest citable corpus, staging order), extracts inline ordinals `[^n]`,
binds each to a `report_citations` row, renders the footnote block,
scans the body for transcribed hashes, and flips the standing pointer —
all in one transaction; same body + corpus + manifest = same output,
byte-for-byte.

### canonical

```json
{"version": "draft"}
```

```text
report_bind: version 3 bound — citations=26 ordinals dense footnote block rendered standing=true
```

### refusal: ordinal-unbound

```
REFUSAL: ORDINAL-UNBOUND: citation [^27] does not resolve — the quest's citable corpus holds 26 sources (ordinals 1..26 by staging order) and the import manifest holds 0 more; cite inside that range, or stage the source first (web_fetch save:true) and re-bind
```

EVIDENCE: design/I02-cross-quest/DESIGN.md §9

### refusal: import-unmarked

```
REFUSAL: IMPORT-UNMARKED: [^31] resolves to a source outside this quest's corpus — out-of-corpus citations must ride the import manifest (minted by tooling at context assembly, never by the model); own-quest evidence or explicitly marked imports, never silent
```

EVIDENCE: design/I02-cross-quest/DESIGN.md §9

### refusal: hash-transcription

```
REFUSAL: HASH-TRANSCRIPTION: the body contains a kb: hash — the model never transcribes hashes; citations are local ordinals [^n] and the binding pass resolves them to urns; replace the hash with its ordinal and re-bind
```

EVIDENCE: design/I02-cross-quest/DESIGN.md §9
