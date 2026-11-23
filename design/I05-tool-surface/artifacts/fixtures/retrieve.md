## retrieve

Hybrid retrieval over chunks/claims/frontier needs: dense + PG FTS legs,
RRF fusion (K=60), per-user scoped, quest-scopable; NO model parameter
EVER — the embedding registry is the only model path and kquest resolves
it (I03 G-REG, R-054).

### canonical

```json
{"query": "evidence on asset allocation impact vs stock selection", "kinds": ["chunk", "claim", "frontier_need"], "limit": 10}
```

### refusal: model-name-refused

```
REFUSAL: MODEL-NAME-REFUSED: retrieval takes no model — the embedding registry is the only model path and kquest resolves it; resubmit without the model field; queries name WHAT to find, never HOW it is embedded
```

EVIDENCE: design/I03-retrieval/DECISIONS.md §DR-01
