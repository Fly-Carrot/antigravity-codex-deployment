# Fabric Architecture

Fabric is an LLM-native local knowledge workstation that sits on top of an agent governance layer.

The app is important, but it is not the whole system. The larger idea is that agents should not rely on scattered prompts, private chat histories, or accidental local state. They should share one explicit operating fabric, then use Obsidian as a maintained human-readable wiki.

The boundary is:

- **Agent Shared Fabric** is the governance and memory layer.
- **Fabric App** is the knowledge workbench that consumes receipts, wiki pages, graph data, and source-processing artifacts.
- **Fabric App is not the source of truth for governance.**

## 1. Governance Brain

`global-agent-fabric` is the canonical control plane from Agent Shared Fabric.

It owns:

- global rules and runtime discipline
- project registry and workspace overlays
- MCP registry
- skill source registry
- workflow source registry
- memory routing and sync receipts
- boot, phase-log, import, export, and postflight scripts

The governance brain should stay light. It should describe what exists, where it lives, and how agents should use it. It should not become a dumping ground for heavy skill repos, generated media, or raw data.

## 2. Implementation Body

Heavy implementations live outside the brain.

This includes:

- curated skills
- local academic skills such as `nature-*`
- awesome-skills references
- custom MCP implementations
- future dedicated subagents
- workflow implementation packs

In a local install, the body root is usually a sibling of the governance root:

```text
/path/to/antigravity-implementation
```

The brain points to this body through YAML registries. That is the important boundary: the brain routes; the body executes.

## 3. Runtime Mirrors

Different runtimes read different files, so Fabric generates mirrors instead of making each runtime a new source of truth.

Examples:

- Antigravity and Gemini read `~/.gemini/GEMINI.md`.
- Antigravity global workflows are mirrored into `~/.gemini/antigravity/global_workflows/`.
- Antigravity MCP config is mirrored into `~/.gemini/antigravity/mcp_config.json`.
- Codex reads `AGENTS.md`, `.agents/sync/*`, and its local runtime configuration.

The rule is simple:

- edit the canonical fabric files
- export generated mirrors
- do not manually maintain mirrors as independent systems

## 4. Obsidian Knowledge Base

Obsidian is the human-readable wiki layer.

Fabric treats the vault as a structured knowledge base:

- `00 Raw Sources`: immutable external inputs
- `10 Wiki`: maintained pages for projects, concepts, entities, and global hubs
- `90 System`: manifests, semantic metadata, graph data, query indexes, logs, and reports

This follows an llm-wiki-inspired pattern:

- raw material is preserved
- normalized sources provide provenance
- wiki pages become the durable synthesis layer
- graph data becomes the navigation layer
- terminal agents become the query and maintenance layer

## 5. Workflow Discipline

Complex work follows the six-stage discipline:

```text
route -> plan -> review -> dispatch -> execute -> report
```

This is inspired by staged governance patterns such as 三省六部-style separation of review, dispatch, and execution. The practical goal is not ceremony. The goal is to stop agents from silently skipping planning, inventing context, or losing sync.

## 6. MCP, Skills, and Maestro

MCP servers are registered centrally in:

```text
/path/to/global-agent-fabric/mcp/servers.yaml
```

Skills are registered centrally in:

```text
/path/to/global-agent-fabric/skills/sources.yaml
```

Maestro is wired as the orchestration layer for complex subagent work:

- Antigravity uses the local Maestro Gemini MCP entrypoint.
- Codex uses the local Maestro Codex MCP entrypoint.
- Execution remains gated by `MAESTRO_EXECUTION_MODE=ask`.
- Maestro should be used for complex or medium orchestration, not for every tiny task.

The current design keeps native Codex/Antigravity delegation mechanisms intact. Maestro is an orchestration bridge, not a replacement for every runtime-specific capability.

## 7. Where Fabric.app Fits

`Fabric.app` is the desktop workstation for this architecture.

It provides:

- shared fabric setup
- runtime monitoring
- Obsidian wiki foundation tools
- source normalization and deep extraction prompts
- semantic graph exploration
- embedded terminal workflows

So the app is the visible control room for knowledge maintenance. The governance underneath remains Agent Shared Fabric.
