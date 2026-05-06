# Deep Wiki Pipeline

## Goal

Turn the prompt-driven `Process Sources` and `Build All` steps into a connected pipeline that produces:

- a human-readable wiki
- a queryable wiki substrate
- a semantic graph grounded in concepts, entities, relationships, and provenance

The dashboard UI, graph, and Gemini chat should all consume the same generated knowledge layer.

## Principle

The system should be:

- prompt-driven for adaptive transformation
- contract-driven for outputs
- staging-first for safety
- provenance-preserving for trust

Raw inputs remain immutable. Generated outputs are replaceable views.

## Stage 1: Process Sources

### Inputs

- `00 Raw Sources/Agent Chats`
- `00 Raw Sources/External Imports/*`
- `00 Raw Sources/Shared Fabric Snapshots/*`
- Shared Fabric memory and sync snapshots when needed for provenance

### Execution model

- Gemini CLI runs from a prompt.
- All transformations happen in a temp workspace first.
- Only validated outputs are copied back into the vault.

### Required outputs

- `90 System/normalized-sources-manifest.json`
- `90 System/source-processing-report.md`
- `90 System/project-source-index.json`
- `90 System/global-knowledge-pool.json`
- `90 System/semantic-cache/source-keywords.json`
- `90 System/semantic-cache/source-entities.json`
- `90 System/semantic-cache/source-relationships.json`
- `90 System/semantic-cache/source-concepts.json`
- `90 System/semantic-cache/README.md`

### Semantic cache contract

Each semantic object should preserve:

- canonical label
- aliases if present
- summary
- project hints
- source references
- raw evidence snippets
- confidence or support count when available

Minimum field contract by file:

- `source-keywords.json`
  - `keyword`
  - `aliases`
  - `summary`
  - `project_hints`
  - `provenance`
  - `evidence`
  - `support_count`
- `source-entities.json`
  - `entity_id`
  - `label`
  - `type`
  - `aliases`
  - `summary`
  - `project_hints`
  - `provenance`
  - `evidence`
  - `support_count`
- `source-concepts.json`
  - `concept`
  - `aliases`
  - `description`
  - `project_hints`
  - `related_entities`
  - `related_concepts`
  - `provenance`
  - `evidence`
  - `support_count`
- `source-relationships.json`
  - `source`
  - `relation`
  - `target`
  - `summary`
  - `project_hints`
  - `provenance`
  - `evidence`
  - `support_count`

Keyword quality rules:

- reject stopwords such as `and`, `the`, `for`, `next`, `then`, `with`, `that`, `this`, `still`, and `than`
- reject path fragments, markdown separators, and UI filler
- prefer domain terms, repeated topic phrases, and source-backed entities/concepts
- derive terms from full source text, not only folder names or index titles

Project mapping rules:

- build a canonical `project-source-index.json` that maps raw sources to real projects/workspaces
- do not treat source-family buckets such as `NotebookLM: <folder>` or `Agent Chats: <folder>` as final project identities when they actually belong to an existing project
- keep unmapped sources explicit rather than inventing fake projects

Global knowledge pool rules:

- large unmapped corpora such as NotebookLM imports, agent chat history, and shared fabric snapshots should also produce a first-class `global-knowledge-pool.json`
- this file should surface cross-project or non-project-bound keywords, concepts, entities, relationships, and source clusters
- the global layer should complement project pages, not replace them
- each `source_clusters` entry should include:
  - `cluster_name`
  - `slug`
  - `source_families`
  - `themes`
  - `related_projects`
  - `representative_sources`
  - `support_count`
  - `notes`
- do not leave a very large unmapped pool as one monolithic bucket when it obviously contains multiple themes or platforms
- split large unmapped material into finer semantic clusters before `Build All`

Coverage expectations:

- for a project with meaningful evidence volume, target roughly:
  - `8-20` keywords
  - `4-12` concepts
  - `4-12` entities
  - `3-12` relationships
- if a rich corpus yields only one or two terms, treat that as under-extraction

Relationship objects should preserve:

- subject
- predicate
- object
- related projects
- source provenance

## Stage 2: Build All

### Inputs

- `90 System/normalized-sources-manifest.json`
- `90 System/source-processing-report.md`
- `90 System/project-source-index.json`
- `90 System/semantic-cache/*`
- Shared Fabric project memory
- Shared Fabric registry and receipts

### Execution model

- Gemini CLI runs from a prompt.
- Compilation happens in a temp workspace first.
- Final outputs are copied back only after validation.

### Required outputs

- `10 Wiki/Sources/Overview.md`
- source-family pages under `10 Wiki/Sources/`
- `10 Wiki/Projects/<project>/*.md`
- `10 Wiki/Concepts/<concept>.md`
- `10 Wiki/Entities/<entity>.md`
- `90 System/knowledge-base-manifest.json`
- `90 System/graph.json`
- `90 System/semantic_metadata.json`
- `90 System/wiki-query-index.json`
- `90 System/index.md`
- `90 System/log.md`
- `90 System/migration-report.md`
- `10 Wiki/Global/Overview.md`
- optional global cluster pages for large evidence pools

### Build acceptance tests

- If scope is vault-wide, the rebuilt `knowledge-base-manifest.json` must include every discovered project in scope.
- If only one project appears in a vault-wide build, the run should be treated as failed or partial, not silently successful.
- If the requested scope is vault-wide, the manifest must declare `compilation_scope` as `all-vault`; it must not silently downgrade to `workspace` or `project`.
- If project labels in the manifest/graph are source-family buckets rather than canonical project identities, the run should be treated as failed or partial.
- `graph.json` must include semantic nodes and edges from concepts, entities, and relationships, not only pages and source items.
- Every concept/entity node in the graph must have at least one meaningful incident edge.
- if NotebookLM, Agent Chats, or Shared Fabric contain large unmapped evidence pools, the run must emit a meaningful global layer rather than a thin placeholder
- in `all-vault` mode, the graph should stay semantic-first: do not emit every raw source file as a graph node by default
- raw `source` nodes should be representative provenance anchors or cluster representatives, not the dominant majority of navigation nodes
- if a large unmapped corpus exists, aggregate it through global cluster/hub nodes instead of flooding the graph with file-name leaves
- `wiki-query-index.json` must include project-level, page-level, concept/entity-level, and snippet-level retrieval entries.
- Concept/entity pages must include evidence and provenance sections, not only short summaries.

Recommended `knowledge-base-manifest.json` shape:

- `generated_at`
- `version`
- `compilation_scope`
- `project_count`
- `projects`
- each project object:
  - `project_name`
  - `slug`
  - `workspace`
  - `page_count`
  - `page_paths`
  - `lifecycle_summary`
  - `last_updated`

### Deep wiki rules

Project pages should explain:

- current status
- architecture
- decisions
- open questions
- source-backed evidence

Concept and entity pages should explain:

- what the concept/entity is
- which projects it appears in
- what evidence supports it
- what related concepts/entities connect to it
- they should be synthesized from both mapped project sources and existing project wiki pages, not only filenames or shallow metadata

Global pages should explain:

- important knowledge that spans projects
- important unmapped corpora that still matter at vault level
- which source clusters contributed the evidence
- how those global concepts connect back into projects

## Stage 3: Ask Wiki

### Query flow

1. User asks a question in the dashboard chat or terminal bridge.
2. The app retrieves relevant wiki pages, system pages, and semantic pages.
3. The app injects retrieved evidence snippets into the Gemini prompt.
4. Gemini answers from retrieved wiki evidence first.
5. If evidence is insufficient, Gemini should say what is missing.

### Retrieval substrate

Near-term:

- lexical retrieval over generated markdown and system indexes
- explicit snippet extraction

Next layer:

- `wiki-query-index.json` as a structured retrieval map for projects, pages, concepts, entities, and evidence snippets

Recommended `wiki-query-index.json` shape:

- `generated_at`
- `scope`
- `projects`: `{ name, slug, workspace, pages, related_concepts, related_entities }[]`
- `pages`: `{ title, path, project, summary, concepts, entities, evidence_snippets }[]`
- `concepts`: `{ name, summary, projects, entities, related_concepts, provenance }[]`
- `entities`: `{ name, type, projects, concepts, provenance }[]`
- `snippets`: `{ id, source_path, project, page, text, concepts, entities }[]`

Optional later layer:

- embedding/vector retrieval

## Graph contract

The graph should be built primarily from:

- project nodes
- concept nodes
- entity nodes
- relationship edges
- evidence/source links

Page and file nodes should remain available as provenance and navigation anchors, but not as the dominant semantic layer.

Required `graph.json` shape:

- top-level keys:
  - `nodes`
  - `edges`
- each node object:
  - `id`
  - `label`
  - `kind`
  - `path`
  - `scope`
  - `workspace`
  - `status`
- each edge object:
  - `source`
  - `target`
  - `kind`

Dashboard compatibility rules:

- use `kind`, not `type`
- use `kind`, not `relation`
- `scope` should identify a project slug or `all-vault` shared scope
- `workspace` should be the owning workspace path when applicable
- `path` should point to the backing file when available, or be empty
- project nodes should correspond to canonical projects/workspaces
- reserve `all-vault` scope for truly shared cross-project nodes; project-specific concepts/entities should carry the owning project slug
- include high-support keyword nodes when they materially improve navigation and retrieval
- allow global clusters such as NotebookLM / Agent Chats / Shared Fabric to appear as shared hubs when they are evidence-backed

## Success criteria

The pipeline is working when:

- `Process Sources` can reorganize and semantically normalize mixed imports safely
- `Build All` can compile a concept-aware wiki from those normalized artifacts
- graph clusters reflect concepts and relationships rather than mostly filenames
- Gemini chat can answer wiki questions using retrieved wiki evidence
