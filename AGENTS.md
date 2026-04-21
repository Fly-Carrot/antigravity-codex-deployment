<!-- managed-by: global-agent-fabric bootstrap_gemini_workspace.py -->
# Workspace Context Entry

This file is the project-scoped context bridge for Gemini CLI and Codex.

## Scope

- Global shared instructions continue to load from `~/.gemini/GEMINI.md`.
- This file adds only workspace-specific context.
- Shared fabric remains the canonical source for project registry, memory routing, MCP definitions, skills, and workflow registries.

## Workspace Imports

_No additional project overlay rules are registered for this workspace._

## Optional Deep Context

- `./.agents/sync/codex-context.md` remains available as deep generated session context.
- It is intentionally not auto-imported by this thin workspace bridge.
