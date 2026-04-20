# Gemini CLI Shared Knowledge Base Transition v1

## Goal

Use Gemini CLI as the primary interactive runtime alongside Codex, while keeping a single shared knowledge base for:

- project management and workspace routing
- durable memories and decisions
- reusable skills
- MCP server definitions
- workflow snapshots and handoff state

The long-term direction is:

- Codex <-> Shared Fabric <-> Gemini CLI
- Antigravity -> optional legacy adapter only

This design does **not** treat Gemini CLI's local runtime state as the canonical knowledge base. Gemini should consume and contribute to the shared fabric, not replace it.

## What the official Gemini CLI architecture means for us

Based on the official Gemini CLI repository and documentation:

1. Gemini CLI is split into `packages/cli` and `packages/core`, with tools executed through the core package. This means Gemini already has a clean separation between UI and execution backend, so it is a good fit as a runtime sitting on top of a separate shared fabric.
2. Configuration is layered: defaults -> system defaults -> user settings -> project settings -> system override settings -> environment variables -> command-line arguments. This is ideal for our model because we can keep global defaults in the shared fabric and render Gemini-facing settings at user or project scope.
3. Gemini CLI uses a hierarchical context model. It always loads `~/.gemini/GEMINI.md`, then workspace/ancestor context files, then just-in-time local context files. This means we should stop treating `~/.gemini/GEMINI.md` as a giant handwritten monolith and instead turn it into a thin import-based entrypoint into shared context.
4. Gemini supports `context.fileName`, including names like `AGENTS.md`. That gives us a direct compatibility bridge with Codex-style project instructions.
5. MCP servers are defined in `settings.json` under `mcpServers`, while global allow/deny rules live under `mcp`. This means the shared fabric can stay canonical and render Gemini-compatible MCP config from one source.
6. Skills are first-class and are discovered from `.gemini/skills/`, `.agents/skills/`, `~/.gemini/skills/`, `~/.agents/skills/`, and extensions. The `.agents/skills/` alias is explicitly supported and has higher precedence than `.gemini/skills/` within the same scope. This is the cleanest cross-tool skill sharing path.
7. Gemini `save_memory` writes facts into the global `~/.gemini/GEMINI.md` file. Auto Memory mines local session transcripts and drafts `SKILL.md` files into a project-local inbox. So Gemini has two native memory channels:
   - fact memory -> global context file
   - procedural memory -> generated skills
8. Gemini checkpointing stores reversible file snapshots and conversation state locally in `~/.gemini/history/<project_hash>` and `~/.gemini/tmp/<project_hash>/checkpoints`. This is useful for local safety, but it should not be treated as the cross-tool shared memory source of truth.

## Current state audit

### Already good

- `global-agent-fabric` already centralizes project registry, sync scripts, shared memory routing, MCP registry, skills sources, and workflow sources.
- The deployment project already templates `runtime-map.yaml`, `hook-policy.yaml`, and `projects/registry.yaml`.
- The deployment project already understands Gemini-specific paths such as `AGF_GEMINI_ROOT` and `AGF_GEMINI_RULE`.
- Your `Project4` workspace already has agent-specific local overlay material in `.agents/`.

### Current bottlenecks

1. Gemini is only partially represented in the current model. The deployment layer knows about Gemini files, but the runtime model still treats `antigravity` as the active peer runtime.
2. The current shared MCP registry still points back to `~/.gemini/antigravity/mcp_config.json` as the effective source, which keeps Antigravity in the center of the graph.
3. `~/.gemini/settings.json` is almost empty right now and does not yet express project context compatibility, MCP rendering, skill conventions, or shared policy paths.
4. `Project4` does not yet expose a Gemini-native context entrypoint such as `AGENTS.md` or `GEMINI.md` at the project root.
5. Shared memories are still optimized around Codex + Antigravity sync receipts and imported workflows, not around Gemini's native `save_memory` / Auto Memory behavior.

## Canonical-source rule

To make knowledge truly shared, we need a hard rule:

### Shared fabric remains the canonical source of truth for:

- project registry and workspace routing
- durable shared memory files
- cross-tool MCP server definitions
- cross-tool skill directories and skill indexes
- workflow snapshots, handoffs, and sync receipts

### Gemini local state is only authoritative for:

- Gemini UI/session preferences
- Gemini authentication and trusted-folders state
- Gemini local checkpoint/history safety features
- Gemini-only temporary session artifacts

This prevents us from moving from one unstable center (Antigravity) to another unstable center (raw Gemini local state).

## Target architecture

### 1. Global instruction layer

Make `~/.gemini/GEMINI.md` a thin, modular entrypoint instead of a handwritten monolith.

Recommended structure:

- keep a short user persona section at the top
- import shared global rules from `global-agent-fabric`
- reserve the `## Gemini Added Memories` section for native Gemini `save_memory`
- optionally import generated shared memory summaries from the fabric

Example direction:

```md
# David Global Gemini Context

@/Users/david_chen/Antigravity_Skills/global-agent-fabric/rules/global/gemini-global.md
@/Users/david_chen/Antigravity_Skills/global-agent-fabric/memory/shared-global-context.md

## Gemini Added Memories
```

Why this matters:

- Gemini keeps working natively with `/memory add` and `save_memory`
- Codex and Gemini can still converge on the same shared rule layer
- global instructions stop being trapped inside one runtime's private file

### 2. Workspace context bridge

Gemini CLI can load `AGENTS.md` if we configure `context.fileName`. We should use that.

Recommended user-level Gemini settings direction:

```json
{
  "context": {
    "fileName": ["AGENTS.md", "GEMINI.md"]
  }
}
```

Then, for each shared workspace:

- add a project-root `AGENTS.md` or `GEMINI.md`
- use imports to pull in `.agents/` rules and shared fabric overlays
- keep `.agents/` as the implementation detail and `AGENTS.md` as the Gemini/Codex bridge file

For `Project4`, the first good target is:

- `/Users/david_chen/Desktop/Project4/AGENTS.md`
  - imports `.agents/rules/ecology.md`
  - imports `.agents/sync/codex-context.md` only after that file is simplified into a Gemini-safe, non-duplicative project summary

This gives Gemini and Codex one visible project context entrypoint.

### 3. Shared skills layer

Gemini officially supports `.agents/skills/` and `~/.agents/skills/`. We should standardize on that alias for cross-tool sharing.

Recommended convention:

- workspace shared skills: `PROJECT/.agents/skills/`
- user shared skills: `~/.agents/skills/`
- Gemini-specific or experimental generated drafts: `.gemini/skills-inbox/` or Gemini Auto Memory inbox until promoted

Rules:

- promoted durable skills move into `.agents/skills/` or `~/.agents/skills/`
- shared fabric indexes those directories in `skills/sources.yaml`
- Codex and Gemini both consume the same promoted skill set
- Antigravity, if retained, reads from the same shared skill source via adapter

This is the cleanest way to make procedural knowledge portable.

### 4. Shared MCP layer

The MCP registry must become fabric-first.

Recommended rule:

- canonical definition lives in `global-agent-fabric/mcp/servers.yaml`
- renderer produces Gemini-compatible `mcpServers` JSON into `~/.gemini/settings.json` or a generated fragment merged into it
- optional legacy export still writes Antigravity's `mcp_config.json` while it remains in use

Do **not** keep `~/.gemini/antigravity/mcp_config.json` as the source of truth.

Instead:

- shared fabric owns server id, command, args, env refs, scope, and enablement
- Gemini renderer maps that to `settings.json -> mcpServers`
- Gemini `mcp.allowed` / `mcp.excluded` can be generated from shared policy

This flips the dependency direction the right way.

### 5. Shared memory layer

We need to separate native Gemini memory from shared memory.

#### Durable factual knowledge

Source channels:

- Gemini `save_memory` -> appends to `~/.gemini/GEMINI.md`
- Codex/shared sync -> writes to `global-agent-fabric/memory/*`

Design rule:

- `~/.gemini/GEMINI.md` remains a valid native memory sink
- a sync adapter should periodically extract the `## Gemini Added Memories` section and mirror approved facts into shared fabric memory
- shared fabric may also generate a summarized `shared-global-context.md` that is imported back into `~/.gemini/GEMINI.md`

That creates a two-way bridge without forcing Gemini to abandon its native memory tool.

#### Procedural knowledge

Source channels:

- Gemini Auto Memory drafts skills from transcripts
- accepted skills are promoted into `.agents/skills/` or `~/.agents/skills/`

Design rule:

- do not treat Auto Memory inbox as the shared library
- only promoted skills become shared knowledge

#### Episodic / session detail

Keep using shared fabric routes for:

- receipts
- handoffs
- decision logs
- open loops
- workflow snapshots

Gemini's local history and checkpoint files remain local convenience features, not the canonical cross-tool memory store.

### 6. Project management layer

Project management should not live inside Gemini local `projects.json` alone.

Canonical rule:

- `global-agent-fabric/projects/registry.yaml` is the master project registry
- Gemini adapters may render or reconcile project metadata into Gemini-local project files if needed
- workspace-level `AGENTS.md` / `GEMINI.md` files become the runtime-facing project brief

That way:

- project identity is shared
- project instructions are shared
- local Gemini project metadata can be regenerated if needed

## Migration plan

### Phase 0 - coexistence

Keep Codex + Antigravity + Gemini all working, but treat Gemini as read-mostly while we add explicit adapters.

### Phase 1 - Gemini runtime formalization

1. Add a real `gemini` runtime block beside `codex` in the shared runtime model.
2. Rename current Antigravity-specific path variables into two groups:
   - `AGF_GEMINI_*`
   - `AGF_ANTIGRAVITY_LEGACY_*`
3. Stop describing Gemini through the Antigravity runtime slot.

### Phase 2 - context bridge

1. Add `context.fileName = ["AGENTS.md", "GEMINI.md"]` to Gemini user settings.
2. Create project-root `AGENTS.md` files for active workspaces.
3. Convert those root files into import-based bridges into `.agents/` and shared fabric docs.

### Phase 3 - skill convergence

1. Standardize on `.agents/skills/` and `~/.agents/skills/`.
2. Promote any accepted Gemini Auto Memory outputs into those directories.
3. Update shared fabric `skills/sources.yaml` to treat these as primary shared skill sources.

### Phase 4 - MCP convergence

1. Render Gemini `mcpServers` from `global-agent-fabric/mcp/servers.yaml`.
2. Keep Antigravity MCP export as optional compatibility only.
3. Document a single enable/disable policy path in the shared fabric.

### Phase 5 - memory convergence

1. Add a Gemini-memory importer that reads `## Gemini Added Memories` and mirrors approved facts into shared fabric memory.
2. Add a shared summary exporter that can be imported back into `~/.gemini/GEMINI.md`.
3. Keep Gemini checkpoint/history local and out of the shared knowledge base.

### Phase 6 - Antigravity deprecation

Once Gemini covers project context, MCP, skills, and memory bridging reliably:

- stop using Antigravity as the primary sync peer
- retain only a legacy export adapter if some historical workflows still depend on it

## Immediate implementation priorities

These are the next three practical tasks I recommend implementing first.

### Priority A - Gemini context compatibility

- update `~/.gemini/settings.json` to recognize `AGENTS.md`
- create root `AGENTS.md` for active projects
- keep imports small and explicit

### Priority B - Gemini MCP renderer

- generate Gemini `mcpServers` from shared `mcp/servers.yaml`
- do not edit MCP server definitions by hand in `~/.gemini/antigravity/mcp_config.json`

### Priority C - shared-memory bridge

- preserve Gemini native `/memory` behavior
- add importer/exporter scripts so Codex and Gemini can see the same durable facts and accepted procedures

## Practical definition of "shared knowledge base"

For this migration, "shared knowledge base" should mean exactly this:

1. Shared instructions
   - global rules
   - workspace rules
   - project briefs

2. Shared durable facts
   - preferences
   - decisions
   - environment truths
   - architecture facts

3. Shared procedural knowledge
   - reusable skills
   - promoted workflow patterns

4. Shared execution capability definitions
   - MCP servers
   - skill sources
   - workflow sources

5. Shared project state summaries
   - open loops
   - handoffs
   - decision logs
   - imported workflow snapshots

It should **not** mean blindly syncing every local runtime artifact.

## Decision

The correct transition is not "move everything into Gemini".

The correct transition is:

- keep `global-agent-fabric` as the canonical shared knowledge base
- make Gemini CLI a first-class consumer and contributor
- use `AGENTS.md` + `GEMINI.md` imports for context compatibility
- use `.agents/skills/` as the cross-tool procedural knowledge layer
- render Gemini MCP settings from the shared fabric
- demote Antigravity to a temporary legacy adapter

That gives you what you actually want: different tools sharing one knowledge system, instead of each tool building its own silo.
