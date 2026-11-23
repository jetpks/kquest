## web_fetch

Fetch + save: snapshot blob, `sources` row (content-addressed URN), and
`quest_sources` membership in ONE transaction — the source is
anchorable in the SAME session (auto-indexing; the agent never writes
corpus state). Never re-fetch a saved URL.

### canonical

```json
{"url": "https://www.jstor.org/stable/4479068", "save": true}
```

```text
web_fetch: saved C14 [kb:src:2Rf8Yk1mNc] "Determinants of Portfolio Performance" 41830 chars — anchorable now (node_add label=evidence src:"C14")
web_calls=43/1400
```

### refusal: budget-exceeded

```
REFUSAL: BUDGET-EXCEEDED: the web-call budget line for this quest is exhausted (web_calls=1400/1400, mode=hard) — work the saved corpus instead: source_list, source_grep, source_read, retrieve; a budget stop routes to synthesis (the never-reportless finisher), never a silent stop
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/notes/arc-run-20261122T-quest2-arc-summary.md §Organic exits were all reportless

### refusal: duplicate-fetch

```
REFUSAL: DUPLICATE-FETCH: this URL is already saved as C14 ("Determinants of Portfolio Performance") — never re-fetch a saved URL (same snapshot = same urn everywhere); read the saved snapshot: {"tool":"source_read","src":"C14","offset":1,"limit":60}
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/repos/hermit-kb/quest/skills/quest/SKILL-claim-graph.md §the corpus
