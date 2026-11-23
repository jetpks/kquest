## subagent_status

Poll a child run by id against the run registry; a missing tool result
NEVER implies a dead child (wedge #3 law, I04 FM-20).

### canonical

```json
{"run": "run/7c1d"}
```

```text
subagent_status: run/7c1d profile=survey state=running elapsed=212s (poll again; digest lands on completion)
```

### refusal: unknown-run

```
REFUSAL: UNKNOWN-RUN: no run run/9zzz in the registry — spawns return immediately and a missing tool result NEVER implies a dead child; verify by the run id from the spawn answer, and poll again
```

EVIDENCE: design/I04-agent-loop/artifacts/failure-modes.tsv §FM-20
