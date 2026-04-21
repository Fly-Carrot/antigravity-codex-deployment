# Memory Architecture

## Goal

Global Agent Fabric uses a dual-track memory model so that Antigravity and Codex share the right level of knowledge without mixing stable norms with noisy session details.

## Track A: Stable Technical-Route Memory

Mechanism:
- `cc-skill-continuous-learning`

Purpose:
- Capture durable technical routes, proven workflows, architecture norms, stable environment recipes, and reusable implementation instincts.

Characteristics:
- High-signal
- Distilled
- Reusable across sessions and often across projects
- Should not include raw debugging chatter or transient failed branches unless they produce a stable lesson

Bridge into Global Agent Fabric:
- `memory/ki-registry.yaml`
- `memory/decision-log.ndjson` when the insight affects cross-project execution policy

## Track B: Episodic / Detailed Memory

Mechanism:
- `mempalace` MCP server

Purpose:
- Preserve process details, reasoning chains, tried-and-failed parameters, detailed debugging traces, and retrieval-rich context that would be too noisy for stable KI.

Characteristics:
- Time-aware
- Detail-heavy
- Retrieval-oriented
- Useful for reconstruction, forensic debugging, and context continuation

Bridge into Global Agent Fabric:
- `memory/mempalace-taxonomy.yaml`
- `memory/handoffs.ndjson` and `memory/open-loops.ndjson` should reference relevant drawers/tags/queries when needed

## Shared Logs

The following files are the shared cross-runtime ledger:
- `memory/decision-log.ndjson`
- `memory/open-loops.ndjson`
- `memory/handoffs.ndjson`

These logs are not replacements for Continuous Learning or MemPalace. They are the shared coordination layer between them.

## Routing Rule

1. If the knowledge is a stable pattern, route first to `cc-skill-continuous-learning`.
2. If the knowledge is a detailed process trace or rich context, route first to `mempalace`.
3. If the knowledge must be visible to both Antigravity and Codex immediately, also write a structured summary to the shared ndjson logs.
