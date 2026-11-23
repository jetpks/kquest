## source_read

SLICED snapshot reads: offset/limit line slices of the immutable snapshot
blob, capped at 8,000 chars per slice (read_slice_cap_chars); whole-file
reads of long snapshots are a context-budget error, not thoroughness.

### canonical

```json
{"src": "C13", "offset": 1, "limit": 60}
```

### refusal: non-sliced-read

```
REFUSAL: NON-SLICED-READ: whole-snapshot reads are a context-budget error, not thoroughness — read in slices: {"tool":"source_read","src":"C13","offset":<line>,"limit":<lines>} (cap 8000 chars/slice); grep first to locate the passage (source_grep), then read the slice that contains it
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/notes/2026-11-17-arc-decompose-review.md §Q5 (78% of a 79,677-token context was corpus reads)

### refusal: unknown-source

```
REFUSAL: UNKNOWN-SOURCE: C99 is not in this quest's corpus — resolve by C-id or source urn (kb:src:…); source_list shows the staged corpus; a source saved this session is anchorable immediately (web_fetch save:true registers it)
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/notes/2026-11-17-descent-observation.md §incident B

### refusal: offset-beyond-eof

```
REFUSAL: OFFSET-BEYOND-EOF: offset 5000 is past the snapshot's 4321 lines — valid range 1..4321; re-anchor with source_grep, or read from offset 1
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/notes/arc-run-20261121T-quest2-failure-taxonomy.md §non-graph errors
