## web_search

Query the web for candidate sources; every result carries the frozen
budget echo (advisory lines teach); when the web-call budget line is
HARD and exhausted, the call is refused before the wire.

### canonical

```json
{"query": "Brinson Hood Beebower 1986 Determinants of Portfolio Performance Financial Analysts Journal", "max_results": 5}
```

```text
web_search: [1] https://jstor.org/… "Determinants of Portfolio Performance II…" — the study's own data …
web_calls=42/1400
```

### refusal: budget-exceeded

```
REFUSAL: BUDGET-EXCEEDED: the web-call budget line for this quest is exhausted (web_calls=1400/1400, mode=hard) — work the saved corpus instead: source_list, source_grep, source_read, retrieve; a budget stop routes to synthesis (the never-reportless finisher), never a silent stop
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/notes/arc-run-20261122T-quest2-arc-summary.md §Organic exits were all reportless
