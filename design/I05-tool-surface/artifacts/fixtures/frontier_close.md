## frontier_close

Close an OPEN frontier entry; closed entries stay history forever
(never deleted); refuses closes that would leave the claim satisfying
nothing.

### canonical

```json
{"claim": "K1"}
```

### refusal: no-open-entry

```
REFUSAL: NO-OPEN-ENTRY: K1 has no open frontier entry (state=closed) — frontier_close closes an OPEN entry; closed entries are history and never deleted; a later round re-poses via frontier_add; check the queue with list/mass
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/repos/hermit-kb/quest/skills/quest/SKILL-claim-graph.md §frontier

### refusal: closure-violation

```
REFUSAL: CLOSURE-VIOLATION: closing K7 would leave it satisfying nothing (no terminal, no derives_from, no other open entry) — give it a terminal (node_set terminal:{…}), wire a derivation (edge_add derives_from), or leave it open; every claim satisfies at least one arm at the gate
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/notes/arc-run-20261121T-quest2-failure-taxonomy.md §1 class i
