## search

Substring match over node text (claims then evidence), capped at 20 rows
with 120-char snippets (principled order, capped — L15); empty text lists
instead (use list); id-probes are refused with the resolution recipe.

### canonical

```json
{"text": "asset allocation", "label": "claim"}
```

### refusal: id-probe

```
REFUSAL: ID-PROBE: search matches node TEXT, it does not resolve ids — a bare K/E/urn probe never hits; resolve the node with node_get, or search words from the claim text
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/notes/arc-run-20261122T-llm-trading-midarc.md §4 finding 1 (~20 dead search "K50" calls)
