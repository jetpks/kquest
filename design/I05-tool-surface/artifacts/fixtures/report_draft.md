## report_draft

Structured sectioned authoring on the session's draft version: a section
key plus a body with inline citation ordinals `[^n]` only (the model
never transcribes hashes); few long sections beat many small — but each
section under the write cap.

### canonical

```json
{"version": "draft", "section": "findings/brinson-attribution", "body": "Brinson, Hood and Beebower attribute the overwhelming share of plan return variance to investment policy.[^13] The study decomposes …"}
```

### refusal: section-too-large

```
REFUSAL: SECTION-TOO-LARGE: section bodies are capped at 20000 chars — write in SECTIONS: one heading per derivation thread, few long sections beat many small; split this one at its next thread boundary and continue
```

EVIDENCE: /Users/eric/architect/spaces/20261110-knowledge-builder/repos/hermit-kb/quest/skills/quest/SKILL-claim-graph.md §synthesis

### refusal: version-frozen

```
REFUSAL: VERSION-FROZEN: version 2 is bound (citations resolved, standing) — bound versions never change; a rework is a NEW synthesis round on a new draft version (report_draft version:"draft"); the chain is the history
```

EVIDENCE: design/I02-cross-quest/DESIGN.md §7

### refusal: phase-not-synthesis

```
REFUSAL: PHASE-NOT-SYNTHESIS: report versions mint from a synthesis phase — this session binds decompose(1/1), whose kind is not synthesis (fk_report_versions_phase pins the version's synthesis_phase_id to a kind-synthesis phases row); report writes need a synthesis-phase binding — re-open synthesis (the console's re-synthesis door) and draft from that session; a rework is a NEW draft version
```

EVIDENCE: schema-law (fk_report_versions_phase + ck_report_versions_phase_kind)
