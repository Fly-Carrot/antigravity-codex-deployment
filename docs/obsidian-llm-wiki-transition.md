# Obsidian LLM Wiki Transition Plan

## Goal

Evolve Fabric from a sync-and-observe tool into an Obsidian-oriented knowledge-base maintainer that follows the `llm-wiki.md` pattern:

- raw sources stay immutable
- the wiki becomes the maintained knowledge layer
- the schema tells the agent how to ingest, update, query, and lint

This is a better fit for long-running personal and project knowledge than treating exported chat history as the final product.

## What `llm-wiki` changes conceptually

The important shift is:

- not `query raw notes every time`
- not `archive chat transcripts and hope they stay useful`
- but `compile new knowledge into a persistent wiki that improves over time`

In that model:

- raw files are the source of truth
- markdown wiki pages are the maintained synthesis layer
- `index.md` and `log.md` make the wiki navigable without requiring full RAG
- the agent behaves like a disciplined wiki maintainer, not just a chat tool

For this project, that means the app should stop thinking of Obsidian as a passive export destination and start treating it as a first-class maintained knowledge target.

## Current state

Today the software already has useful building blocks:

- shared-fabric canonical memory lanes
- project memory and update-log compilation
- user question profile distillation
- manual export of Codex and Gemini chat transcripts into Obsidian

But the current Obsidian integration is still incomplete relative to the `llm-wiki` pattern.

### What is already good

- We can preserve readable agent conversations.
- We already compile structured project memory from canonical lanes.
- We already have a dashboard that can inspect project state, phases, sync status, and recent memory.

### What is missing

- Obsidian still behaves mostly like an export sink.
- Different top-level folders and project subtrees are not governed by one schema.
- `Agent Chat History` is useful, but it is still a raw-source archive rather than a maintained wiki.
- There is no canonical `index.md` + `log.md` layer for the vault.
- There is no ingest workflow that updates concept/entity/project pages when new material arrives.
- There is no lint workflow that checks for orphan pages, stale claims, inconsistent naming, or missing links.

## Proposed target architecture

Follow the three-layer `llm-wiki` architecture directly.

### 1. Raw Sources

This layer stays append-only or overwrite-stable, and should not be manually rewritten by the synthesis pipeline.

Recommended vault subtree:

```text
Obsidian Vault/
  00 Raw Sources/
    Agent Chats/
      <project>/
        Codex/
        Gemini CLI/
    External Imports/
      NotebookLM/
      Notion/
      Web Clipper/
    Shared Fabric Snapshots/
      Update Logs/
      Handoffs/
      Memory Receipts/
```

Rules:

- `Agent Chat History` should migrate into `00 Raw Sources/Agent Chats/`.
- Existing NotebookLM and Notion imports should become explicit raw-source providers rather than unrelated top-level islands.
- Chats remain readable, but they are inputs to synthesis, not the final wiki.

### 2. Wiki

This is the maintained layer that the agent should actively update.

Recommended vault subtree:

```text
Obsidian Vault/
  10 Wiki/
    Projects/
      <project>/
        Overview.md
        Current Status.md
        Architecture.md
        Decisions.md
        Open Questions.md
        Sources.md
    Concepts/
    Entities/
    Workflows/
    People/
```

Rules:

- Each project gets a stable wiki home.
- Pages should be interlinked with Obsidian wikilinks.
- `Overview.md` should be the entry page for each project.
- `Architecture.md` should resemble the structured style you preferred in `current_architecture_report.md`.
- `Current Status.md` should be regenerated or updated from project memory and update logs.
- `Decisions.md` and `Open Questions.md` should compile from canonical lanes rather than freehand notes.

### 3. Schema

This is the instruction layer that governs how the agent maintains the vault.

Recommended shared-fabric outputs:

```text
Obsidian Vault/
  90 System/
    AGENTS.md
    obsidian-wiki-schema.md
    index.md
    log.md
    lint-report.md
```

Rules:

- `obsidian-wiki-schema.md` should describe:
  - naming conventions
  - frontmatter conventions
  - allowed folder structure
  - ingest workflow
  - query workflow
  - lint workflow
- `index.md` is the content-oriented catalog.
- `log.md` is the append-only chronological audit of ingests, queries, wiki updates, and lint passes.
- The app should be able to regenerate these files deterministically.

## How Shared Fabric should integrate with this model

The current software already owns the right canonical state. The transformation should happen by changing what gets rendered into Obsidian.

### Keep Shared Fabric canonical

Do not move canonical truth into Obsidian.

Shared Fabric should remain canonical for:

- project registry
- decisions, handoffs, loops, learnings, receipts
- user-question profile snapshots
- dashboard snapshots and update-log compilation

Obsidian should become the maintained human-facing knowledge workspace built from those canonical inputs plus external raw sources.

### Reposition existing features

#### Agent Chat History

Keep it, but redefine it:

- old role: end-user archive
- new role: raw-source feed for wiki compilation

That means:

- preserve readable exports
- normalize folder naming
- add minimal frontmatter consistently
- do not treat transcript files as the final project memory artifact

#### Project Memory

This becomes the primary synthesis input for project wiki pages.

Suggested mapping:

- `Decision` -> `10 Wiki/Projects/<project>/Decisions.md`
- `Handoff` -> `10 Wiki/Projects/<project>/Current Status.md`
- `Open Loop` -> `10 Wiki/Projects/<project>/Open Questions.md`
- `Mem` -> `10 Wiki/Projects/<project>/Architecture.md` or `Workflows/`
- `Learn` -> `10 Wiki/Concepts/` or `Workflows/`
- `Receipt` -> `90 System/log.md` and audit records

#### Update Log

This should become the basis for:

- project `Current Status.md`
- project `Architecture.md`
- vault-level `log.md`

The current structured report format is already close to what we want. The next step is to render it into stable wiki pages rather than only showing it inside the dashboard.

#### User Question Profile

This should not become a visible “wiki page for everything,” but it can drive:

- preferred output language
- emphasis style
- how much ambiguity to resolve up front
- what kinds of sections the generated wiki pages prioritize

## Recommended vault normalization

Right now the vault has mixed top-level folders such as:

- `Agent Chat History`
- `NotebookLM`
- `Notion`

That makes sense historically, but not as a durable wiki contract.

Recommended normalized top level:

```text
Obsidian Vault/
  00 Raw Sources/
  10 Wiki/
  20 Queries and Reports/
  90 System/
```

Suggested migration mapping:

- `Agent Chat History` -> `00 Raw Sources/Agent Chats`
- `NotebookLM` -> `00 Raw Sources/External Imports/NotebookLM`
- `Notion` -> `00 Raw Sources/External Imports/Notion`

This gives the vault one architectural language instead of multiple unrelated naming schemes.

## What the app should do next

### Stage 1: Vault normalization

Add a new Obsidian mode in the app:

- `Archive Mode` for raw chat export
- `Wiki Mode` for maintained knowledge-base output

In `Wiki Mode`, the app should:

- validate the target vault structure
- offer a one-click “Normalize Vault Layout”
- generate `90 System/obsidian-wiki-schema.md`
- generate `90 System/index.md`
- generate `90 System/log.md`
- create missing project wiki folders

This is the minimum foundation.

### Stage 2: Wiki rendering

Add a compiler that renders canonical shared-fabric memory into wiki pages.

Minimum project outputs:

- `Overview.md`
- `Current Status.md`
- `Architecture.md`
- `Decisions.md`
- `Open Questions.md`
- `Sources.md`

Important rule:

- overwrite or patch stable pages deterministically
- do not create endless duplicate notes

This mirrors the same “new chat overwrites old same session” idea, but for wiki pages.

### Stage 3: Incremental ingest

When a new source appears in raw sources, the app should:

1. register it in `90 System/log.md`
2. add or update source metadata in `Sources.md`
3. update relevant project or concept pages
4. refresh `index.md`

This is the moment where the software truly starts behaving like the `llm-wiki` pattern.

### Stage 4: Lint and maintenance

Add a wiki health pass that checks:

- orphan pages
- missing backlinks
- stale pages not updated after important new evidence
- inconsistent project naming
- missing source references
- duplicated concepts split across multiple pages

The output should land in:

- `90 System/lint-report.md`

And also surface in the dashboard as a new `Wiki Health` card later.

## Why this is better than direct RAG

This project should not begin by building an embedding-heavy retrieval layer.

The better path is:

1. maintain a structured wiki
2. rely on `index.md`, `log.md`, wikilinks, and stable page layout
3. only add local search tools later if scale demands it

This aligns with `llm-wiki.md`:

- knowledge is compiled once and maintained
- contradictions and cross-links are surfaced ahead of query time
- questions can produce new durable wiki pages instead of disappearing into chat

If search is needed later, a local markdown search tool can be added on top. It should enhance the wiki, not replace it.

## Recommended first implementation slice

The safest first slice is:

1. keep current chat export
2. normalize the Obsidian vault layout
3. add generated `index.md` and `log.md`
4. render one project wiki subtree from existing Project Memory
5. make `Update Log` export into `10 Wiki/Projects/<project>/Current Status.md`

This is enough to prove the transition without overbuilding.

## Concrete product reframing

Old framing:

- dashboard for shared sync, memory browsing, and chat export

New framing:

- a personal AI memory console that maintains a living Obsidian wiki from Codex, Gemini, and shared-fabric memory

That framing is much closer to what users will actually value:

- durable understanding
- navigable knowledge
- less repeated rediscovery
- a cleaner bridge between agent work and human reading

## Next action items

1. Add an Obsidian wiki schema generator to the app and scripts.
2. Normalize vault folder naming around `00 Raw Sources / 10 Wiki / 90 System`.
3. Export `Update Log` as stable project wiki pages.
4. Add `index.md` and `log.md` generation.
5. Add a future `Wiki Health` dashboard card.

That is the path that best matches the Karpathy-style `llm-wiki` strategy while staying compatible with the current shared-fabric architecture.
