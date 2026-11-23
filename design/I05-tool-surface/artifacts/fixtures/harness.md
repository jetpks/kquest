## harness

The ToolHarness dispatch contract (I04 §2.4): wraps every registered
tool with same-transaction audit, per-call deadline, result caps, budget
guards, and profile restriction. Three harness-level frozen texts:
unknown-tool (FM-12), the write-guard (FM-16), the tool deadline
(FM-04).

### canonical

```json
{"tool": "<any registered tool>", "…": "the tool's own canonical call"}
```

### refusal: unknown-tool

```
REFUSAL: no such tool: <name> — this session's legal tools: <legal-tools>; call one of those (the tool name IS the operation; there is no op key)
```

EVIDENCE: /Users/eric/architect/spaces/20261122-kquest/repos/fast-llm/gems/completions/docs/reference/tools.md §no such tool

### refusal: write-guard

```
REFUSAL: WRITE-GUARD: quest <quest-id> is held by live writer session <session-id> (driver <driver>) — pause-and-resume to take over; this session may not mutate (one active writer per quest)
```

EVIDENCE: design/I04-agent-loop/artifacts/failure-modes.tsv §FM-16

### refusal: tool-deadline

```
REFUSAL: TOOL-DEADLINE: <tool> exceeded tool_timeout_s (elapsed 120s; ran: source_grep pattern=… src=C13) — narrow the request (smaller range, narrower pattern, fewer rows) and retry; the session is alive and routes around it
```

EVIDENCE: design/I04-agent-loop/artifacts/failure-modes.tsv §FM-04
