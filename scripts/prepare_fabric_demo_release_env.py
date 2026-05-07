#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
from dataclasses import dataclass
from pathlib import Path
from textwrap import dedent


@dataclass(frozen=True)
class DemoProject:
    name: str
    slug: str
    runtime: str
    focus: str
    summary: str
    concepts: list[str]
    entities: list[str]
    keywords: list[str]


PROJECTS = [
    DemoProject(
        name="Signal Garden",
        slug="signal-garden",
        runtime="codex",
        focus="Turn mixed field notes into linked, queryable wiki pages.",
        summary="A release-demo project about transforming messy observations into a maintained wiki and graph.",
        concepts=["Semantic Source Normalization", "Cross-Project Retrieval"],
        entities=["Codex", "NotebookLM"],
        keywords=["normalization", "retrieval", "evidence"],
    ),
    DemoProject(
        name="Pattern Foundry",
        slug="pattern-foundry",
        runtime="gemini",
        focus="Compile repeatable automation patterns into reusable knowledge modules.",
        summary="A project focused on turning repeated workflows into stable building blocks inside the wiki layer.",
        concepts=["LLM-Wiki Maintenance", "Shared Fabric Patterns"],
        entities=["Gemini CLI", "Shared Fabric"],
        keywords=["workflow", "maintenance", "memory"],
    ),
    DemoProject(
        name="Field Atlas",
        slug="field-atlas",
        runtime="codex",
        focus="Connect raw external imports to project-specific wiki views.",
        summary="A demo project that shows how source families can be curated into concise project views.",
        concepts=["Source Family Curation", "Evidence Trails"],
        entities=["Obsidian", "NotebookLM"],
        keywords=["sources", "curation", "atlas"],
    ),
    DemoProject(
        name="Tidal Studio",
        slug="tidal-studio",
        runtime="gemini",
        focus="Use graph navigation to discover concept clusters across projects.",
        summary="A concept-heavy project used to showcase graph navigation and shared knowledge hubs.",
        concepts=["Graph Navigation", "Cross-Project Retrieval"],
        entities=["Graph View", "Gemini CLI"],
        keywords=["graph", "cluster", "navigation"],
    ),
    DemoProject(
        name="Archive Studio",
        slug="archive-studio",
        runtime="codex",
        focus="Keep raw source material immutable while building maintained synthesis pages.",
        summary="A demo project centered on preserving raw provenance while improving the human-facing knowledge layer.",
        concepts=["Immutable Raw Sources", "LLM-Wiki Maintenance"],
        entities=["Shared Fabric", "Obsidian"],
        keywords=["archive", "provenance", "wiki"],
    ),
]

CONCEPTS = {
    "LLM-Wiki Maintenance": "Maintain a growing wiki layer that improves over time instead of re-querying raw context every time.",
    "Semantic Source Normalization": "Normalize mixed source families into stable, queryable records before deeper synthesis.",
    "Cross-Project Retrieval": "Surface relevant context from multiple projects through concepts, entities, and graph neighborhoods.",
    "Graph Navigation": "Use semantic graph links as an exploration surface rather than just a folder tree.",
    "Immutable Raw Sources": "Keep raw imports append-only while promoting structured synthesis into wiki pages.",
    "Shared Fabric Patterns": "Document repeatable workflows, memory practices, and multi-agent conventions.",
    "Source Family Curation": "Organize external imports into meaningful source lanes before project assignment.",
    "Evidence Trails": "Carry provenance from raw source through synthesis, graph nodes, and query outputs.",
}

ENTITIES = {
    "Codex": "Primary coding/runtime agent used for implementation and structured maintenance tasks.",
    "Gemini CLI": "LLM runtime used for snippet-driven source processing and build-all compilation.",
    "NotebookLM": "External research source family used as raw material inside the demo vault.",
    "Shared Fabric": "Canonical cross-agent memory and sync framework that stays outside the Obsidian vault.",
    "Obsidian": "Maintained wiki surface where normalized knowledge becomes human-readable pages.",
    "Graph View": "Interactive semantic exploration layer generated from projects, concepts, entities, and keywords.",
}

GLOBAL_CLUSTERS = [
    {
        "name": "NotebookLM Research Pool",
        "slug": "notebooklm-research-pool",
        "themes": ["research synthesis", "topic extraction"],
        "related_projects": ["signal-garden", "field-atlas", "tidal-studio"],
    },
    {
        "name": "Agent Workflow Notes",
        "slug": "agent-workflow-notes",
        "themes": ["multi-agent coordination", "operational handoffs"],
        "related_projects": ["pattern-foundry", "archive-studio"],
    },
    {
        "name": "Shared Fabric Patterns",
        "slug": "shared-fabric-patterns",
        "themes": ["memory routing", "phase logging"],
        "related_projects": [project.slug for project in PROJECTS],
    },
]

SOURCE_FAMILIES = [
    ("NotebookLM", 48, "Research corpora and notebook summaries staged outside Fabric and normalized into the wiki pipeline."),
    ("Agent Chats", 36, "Runtime conversations prepared by external tooling and then compiled into project- and concept-aware summaries."),
    ("Shared Fabric Snapshots", 18, "System receipts, handoffs, learnings, and sync metadata compiled into project update logs."),
]


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content.rstrip() + "\n", encoding="utf-8")


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def write_ndjson(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows), encoding="utf-8")


def markdown_page(title: str, body: str) -> str:
    return dedent(
        f"""
        # {title}

        {body.strip()}
        """
    ).strip() + "\n"


def prepare_demo_root(root: Path) -> dict[str, str]:
    if root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True)

    global_root = root / "global-root"
    vault_root = root / "vault"
    workspaces_root = root / "workspaces"
    settings_path = root / "gemini-settings.json"

    workspace_paths = {project.slug: workspaces_root / project.slug for project in PROJECTS}
    for path in workspace_paths.values():
        path.mkdir(parents=True, exist_ok=True)
        write_text(path / "README.md", f"# {path.name}\n\nSanitized demo workspace for the Fabric 4.0.0 release media.\n")

    write_json(
        settings_path,
        {
            "mcpServers": {}
        },
    )

    registry_yaml = ["version: 1", "projects:"]
    for project in PROJECTS:
        registry_yaml.extend(
            [
                "  -",
                f'    name: "{project.name}"',
                f'    path: "{workspace_paths[project.slug]}"',
            ]
        )
    write_text(global_root / "projects" / "registry.yaml", "\n".join(registry_yaml))

    write_text(
        global_root / "mcp" / "servers.yaml",
        dedent(
            """
            version: 1
            servers: []
            """
        ),
    )

    receipts = []
    handoffs = []
    learning_receipts = []
    decisions = []
    open_loops = []
    learnings = []
    mem_records = []
    question_profiles = []

    for index, project in enumerate(PROJECTS, start=1):
        workspace = str(workspace_paths[project.slug])
        task_id = f"task-{project.slug}"
        base_hour = 8 + index
        receipts.extend(
            [
                {
                    "agent": project.runtime,
                    "status_marker": "[BOOT_OK]",
                    "task_id": task_id,
                    "timestamp": f"2026-05-03T{base_hour:02d}:00:00Z",
                    "workspace": workspace,
                },
                {
                    "agent": project.runtime,
                    "status_marker": "[SYNC_OK]",
                    "task_id": task_id,
                    "timestamp": f"2026-05-03T{base_hour:02d}:04:00Z",
                    "summary": f"{project.name} wiki refresh completed",
                    "workspace": workspace,
                },
            ]
        )
        handoffs.append(
            {
                "agent": project.runtime,
                "task_id": task_id,
                "timestamp": f"2026-05-03T{base_hour:02d}:05:00Z",
                "workspace": workspace,
                "summary": project.focus,
            }
        )
        learning_receipts.append(
            {
                "agent": project.runtime,
                "task_id": task_id,
                "timestamp": f"2026-05-03T{base_hour:02d}:06:00Z",
                "workspace": workspace,
                "writes": {"receipts": 1, "handoffs": 1, "promoted_learnings": 1},
                "learned_items": [project.concepts[0], project.summary],
                "skipped_items": [],
                "source_summary": f"{project.name} wiki refresh completed",
            }
        )
        question_profiles.append(
            {
                "agent": project.runtime,
                "task_id": task_id,
                "timestamp": f"2026-05-03T{base_hour:02d}:06:00Z",
                "workspace": workspace,
            }
        )
        decisions.append(
            {
                "task_id": task_id,
                "timestamp": f"2026-05-03T{base_hour:02d}:03:00Z",
                "workspace": workspace,
                "summary": f"Adopt {project.concepts[0]} as a maintained wiki pattern.",
            }
        )
        open_loops.append(
            {
                "task_id": task_id,
                "timestamp": f"2026-05-03T{base_hour:02d}:02:00Z",
                "workspace": workspace,
                "summary": f"Expand {project.name} source coverage with higher-support evidence clusters.",
            }
        )
        learnings.append(
            {
                "task_id": task_id,
                "timestamp": f"2026-05-03T{base_hour:02d}:06:00Z",
                "workspace": workspace,
                "summary": f"{project.concepts[0]} improves retrieval and graph navigation.",
            }
        )
        mem_records.append(
            {
                "task_id": task_id,
                "timestamp": f"2026-05-03T{base_hour:02d}:01:00Z",
                "workspace": workspace,
                "summary": f"Preserve raw sources while building human-readable wiki pages for {project.name}.",
            }
        )

        workspace_profile = markdown_page(
            f"{project.name} Workspace Profile",
            f"""
            Compiled from `1` distilled question-profile snapshot for **{project.name}**.

            - Preferred style: direct, structured, implementation-aware
            - Common focus: wiki integrity, graph quality, multi-agent operational clarity
            - Current emphasis: {project.focus}
            """,
        )
        write_text(workspace_paths[project.slug] / ".agents" / "sync" / "user-question-profile.md", workspace_profile)

    write_ndjson(global_root / "sync" / "receipts.ndjson", receipts)
    write_ndjson(global_root / "sync" / "learning_receipts.ndjson", learning_receipts)
    write_ndjson(global_root / "memory" / "handoffs.ndjson", handoffs)
    write_ndjson(global_root / "memory" / "decision-log.ndjson", decisions)
    write_ndjson(global_root / "memory" / "open-loops.ndjson", open_loops)
    write_ndjson(global_root / "memory" / "promoted-learnings.ndjson", learnings)
    write_ndjson(global_root / "memory" / "mempalace-records.ndjson", mem_records)
    write_ndjson(global_root / "memory" / "user-question-profiles.ndjson", question_profiles)
    write_text(
        global_root / "memory" / "user-question-profile.md",
        markdown_page(
            "Global User Question Profile",
            """
            Compiled from `5` distilled user-question snapshots across `5` workspace(s).

            - Preferred style: concise, exact, implementation-ready
            - Recurring themes: shared memory discipline, wiki maintenance, semantic graph quality
            - Product framing: Fabric as a maintained LLM-native knowledge base
            """,
        ),
    )

    source_cards = []
    for family, item_count, summary in SOURCE_FAMILIES:
        source_cards.append(f"- **{family}**: {item_count} items - {summary}")
        write_text(
            vault_root / "10 Wiki" / "Sources" / f"{family}.md",
            markdown_page(
                family,
                f"""
                This source family is treated as an **external input** to Fabric.

                - Item count: {item_count}
                - Role: {summary}
                - Pipeline position: raw source -> normalization -> semantic extraction -> wiki compilation
                """,
            ),
        )

    write_text(
        vault_root / "10 Wiki" / "Sources" / "Overview.md",
        markdown_page(
            "Sources Overview",
            """
            Fabric treats imports as raw source families that stay outside the maintained wiki logic until they are normalized and compiled.

            """ + "\n".join(source_cards),
        ),
    )

    write_text(
        vault_root / "10 Wiki" / "Global" / "Overview.md",
        markdown_page(
            "Global Knowledge Overview",
            """
            This vault-level layer captures shared knowledge that matters across projects.

            - NotebookLM Research Pool
            - Agent Workflow Notes
            - Shared Fabric Patterns
            - Cross-project concept and entity hubs
            """,
        ),
    )
    for cluster in GLOBAL_CLUSTERS:
        write_text(
            vault_root / "10 Wiki" / "Global" / f"{cluster['name']}.md",
            markdown_page(
                cluster["name"],
                f"""
                This global cluster groups shared knowledge that does not belong cleanly to one project.

                - Themes: {', '.join(cluster['themes'])}
                - Related projects: {', '.join(cluster['related_projects'])}
                - Role in Fabric: shared cross-project knowledge hub
                """,
            ),
        )

    page_titles = ["Overview", "Current Status", "Architecture", "Decisions", "Open Questions", "Sources"]
    manifest_projects = []
    wiki_pages = []
    snippets = []
    graph_nodes = []
    graph_edges = []

    hub_id = "hub:global-knowledge"
    graph_nodes.append(
        {
            "id": hub_id,
            "label": "Global Knowledge",
            "kind": "hub",
            "path": str(vault_root / "10 Wiki" / "Global" / "Overview.md"),
            "scope": "all-vault",
            "workspace": "",
            "status": "active",
        }
    )

    for cluster in GLOBAL_CLUSTERS:
        cluster_id = f"cluster:{cluster['slug']}"
        graph_nodes.append(
            {
                "id": cluster_id,
                "label": cluster["name"],
                "kind": "cluster",
                "path": str(vault_root / "10 Wiki" / "Global" / f"{cluster['name']}.md"),
                "scope": "all-vault",
                "workspace": "",
                "status": "active",
            }
        )
        graph_edges.append({"source": hub_id, "target": cluster_id, "kind": "contains"})

    for concept, description in CONCEPTS.items():
        slug = concept.lower().replace(" ", "-")
        path = vault_root / "10 Wiki" / "Concepts" / f"{concept}.md"
        write_text(
            path,
            markdown_page(
                concept,
                f"""
                {description}

                ## Why it matters in Fabric
                Fabric uses this concept to connect raw source normalization, maintained wiki pages, graph structure, and query-time retrieval.
                """,
            ),
        )
        graph_nodes.append(
            {
                "id": f"concept:{slug}",
                "label": concept,
                "kind": "concept",
                "path": str(path),
                "scope": "all-vault",
                "workspace": "",
                "status": "active",
            }
        )
        graph_edges.append({"source": hub_id, "target": f"concept:{slug}", "kind": "contains"})

    for entity, description in ENTITIES.items():
        slug = entity.lower().replace(" ", "-")
        path = vault_root / "10 Wiki" / "Entities" / f"{entity}.md"
        write_text(
            path,
            markdown_page(
                entity,
                f"""
                {description}

                ## Relevance
                This entity appears in the demo graph to show how Fabric binds tools, systems, and source families into a maintained knowledge network.
                """,
            ),
        )
        graph_nodes.append(
            {
                "id": f"entity:{slug}",
                "label": entity,
                "kind": "entity",
                "path": str(path),
                "scope": "all-vault",
                "workspace": "",
                "status": "active",
            }
        )

    all_keywords = sorted({keyword for project in PROJECTS for keyword in project.keywords} | {"llm-wiki", "knowledge graph", "terminal"})
    for keyword in all_keywords:
        slug = keyword.lower().replace(" ", "-")
        graph_nodes.append(
            {
                "id": f"keyword:{slug}",
                "label": keyword,
                "kind": "keyword",
                "path": "",
                "scope": "all-vault",
                "workspace": "",
                "status": "active",
            }
        )

    for project in PROJECTS:
        workspace_path = workspace_paths[project.slug]
        project_wiki_root = vault_root / "10 Wiki" / "Projects" / project.slug
        page_paths = []
        for title in page_titles:
            path = project_wiki_root / f"{title}.md"
            page_paths.append(str(path))
            wiki_pages.append({
                "title": f"{project.name} · {title}",
                "path": str(path),
                "project": project.name,
            })
        write_text(
            project_wiki_root / "Overview.md",
            markdown_page(
                f"{project.name} Overview",
                f"""
                {project.summary}

                ## Core Focus
                {project.focus}

                ## Linked Concepts
                {' | '.join(f'[[{concept}]]' for concept in project.concepts)}

                ## Linked Entities
                {' | '.join(f'[[{entity}]]' for entity in project.entities)}
                """,
            ),
        )
        write_text(
            project_wiki_root / "Current Status.md",
            markdown_page(
                f"{project.name} Current Status",
                f"""
                - Lifecycle: SYNCED
                - Runtime: {project.runtime.upper()}
                - Current focus: {project.focus}
                - Knowledge posture: wiki-first, graph-assisted, provenance-aware
                """,
            ),
        )
        write_text(
            project_wiki_root / "Architecture.md",
            markdown_page(
                f"{project.name} Architecture",
                f"""
                Fabric keeps raw source material stable while compiling normalized sources into maintained wiki pages.

                - Raw sources remain append-only
                - Concepts and entities become reusable semantic hubs
                - Project pages stay concise and human-readable
                - Graph nodes make cross-project exploration possible
                """,
            ),
        )
        write_text(
            project_wiki_root / "Decisions.md",
            markdown_page(
                f"{project.name} Decisions",
                f"""
                - Chose **{project.concepts[0]}** as a guiding project pattern.
                - Prefer external ingestion + Fabric compilation over in-app raw acquisition.
                - Keep graph, wiki, and terminal aligned around the same canonical knowledge base.
                """,
            ),
        )
        write_text(
            project_wiki_root / "Open Questions.md",
            markdown_page(
                f"{project.name} Open Questions",
                f"""
                - Which additional raw sources should be promoted into this project's semantic layer?
                - Where should shared knowledge remain vault-level instead of project-specific?
                - Which graph links deserve stronger evidence coverage?
                """,
            ),
        )
        write_text(
            project_wiki_root / "Sources.md",
            markdown_page(
                f"{project.name} Sources",
                f"""
                Fabric compiles this project from normalized external inputs and shared-fabric memory.

                - External imports: NotebookLM and agent workflow notes
                - Shared memory lanes: decisions, handoffs, learnings, open loops
                - Global layer reuse: notebook clusters, workflow patterns, and cross-project concepts
                """,
            ),
        )

        manifest_projects.append(
            {
                "project_name": project.name,
                "name": project.name,
                "slug": project.slug,
                "workspace": str(workspace_path),
                "source": "active",
                "lifecycle_phase": "SYNCED",
                "runtime": project.runtime,
                "last_updated": "2026-05-03 16:40",
                "focus": project.focus,
                "page_count": len(page_titles),
                "page_paths": page_paths,
                "has_wiki": True,
                "wiki_root": str(project_wiki_root),
            }
        )

        project_node_id = f"project:{project.slug}"
        graph_nodes.append(
            {
                "id": project_node_id,
                "label": project.name,
                "kind": "project",
                "path": str(project_wiki_root / "Overview.md"),
                "scope": project.slug,
                "workspace": str(workspace_path),
                "status": "active",
            }
        )
        for concept in project.concepts:
            graph_edges.append({
                "source": project_node_id,
                "target": f"concept:{concept.lower().replace(' ', '-')}",
                "kind": "references",
            })
        for entity in project.entities:
            graph_edges.append({
                "source": project_node_id,
                "target": f"entity:{entity.lower().replace(' ', '-')}",
                "kind": "references",
            })
        for keyword in project.keywords:
            graph_edges.append({
                "source": project_node_id,
                "target": f"keyword:{keyword.lower().replace(' ', '-')}",
                "kind": "references",
            })

        snippets.append(
            {
                "project": project.name,
                "source": "NotebookLM Research Pool",
                "content": f"{project.name} uses {project.concepts[0]} to turn raw source material into a maintained wiki and graph surface.",
                "kind": "semantic-summary",
            }
        )

    graph_payload = {
        "node_count": len(graph_nodes),
        "edge_count": len(graph_edges),
        "nodes": graph_nodes,
        "edges": graph_edges,
    }
    write_json(vault_root / "90 System" / "graph.json", graph_payload)

    manifest_payload = {
        "generated_at": "2026-05-04T10:00:00Z",
        "version": "4.0.0",
        "compilation_scope": "all-vault",
        "summary": {
            "wiki_page_count": len(manifest_projects) * len(page_titles),
            "graph_node_count": len(graph_nodes),
            "graph_edge_count": len(graph_edges),
        },
        "projects": manifest_projects,
        "legacy_sources": [
            {
                "name": family,
                "path": str(vault_root / "00 Raw Sources" / family),
                "classification": "external-input",
                "status": "normalized",
            }
            for family, _, _ in SOURCE_FAMILIES
        ],
    }
    write_json(vault_root / "90 System" / "knowledge-base-manifest.json", manifest_payload)

    write_json(
        vault_root / "90 System" / "wiki-query-index.json",
        {
            "scope": "all-vault",
            "generated_at": "2026-05-04T10:00:00Z",
            "projects": [
                {
                    "name": project.name,
                    "slug": project.slug,
                    "related_concepts": project.concepts,
                    "related_entities": project.entities,
                }
                for project in PROJECTS
            ],
            "pages": wiki_pages,
            "concepts": [{"name": key} for key in CONCEPTS],
            "entities": [{"name": key} for key in ENTITIES],
            "snippets": snippets,
        },
    )

    write_json(
        vault_root / "90 System" / "global-knowledge-pool.json",
        {
            "generated_at": "2026-05-04T10:00:00Z",
            "global_keywords": all_keywords,
            "global_concepts": list(CONCEPTS.keys()),
            "global_entities": list(ENTITIES.keys()),
            "global_relationships": [
                {"source": "NotebookLM", "target": "Semantic Source Normalization", "kind": "supports"},
                {"source": "Shared Fabric", "target": "LLM-Wiki Maintenance", "kind": "governs"},
                {"source": "Graph View", "target": "Cross-Project Retrieval", "kind": "enables"},
            ],
            "source_clusters": [
                {
                    "cluster_name": cluster["name"],
                    "slug": cluster["slug"],
                    "source_families": ["NotebookLM", "Agent Chats", "Shared Fabric Snapshots"],
                    "themes": cluster["themes"],
                    "related_projects": cluster["related_projects"],
                    "representative_sources": [cluster["name"] + " summary"],
                    "support_count": 12,
                    "notes": "Sanitized demo cluster for release screenshots.",
                }
                for cluster in GLOBAL_CLUSTERS
            ],
            "unmapped_summary": "Large external corpora are grouped into meaningful global clusters instead of one monolithic unmapped bucket.",
        },
    )

    write_json(
        vault_root / "90 System" / "project-source-index.json",
        {
            "generated_at": "2026-05-04T10:00:00Z",
            "projects": [
                {
                    "project_name": project.name,
                    "slug": project.slug,
                    "workspace": str(workspace_paths[project.slug]),
                    "source_families": ["NotebookLM", "Agent Chats", "Shared Fabric Snapshots"],
                    "evidence_count": 18,
                }
                for project in PROJECTS
            ]
            + [
                {
                    "project_name": "Unmapped Sources",
                    "slug": "unmapped-sources",
                    "workspace": "",
                    "source_families": ["NotebookLM", "Agent Chats", "Shared Fabric Snapshots"],
                    "evidence_count": 42,
                }
            ],
        },
    )

    write_json(
        vault_root / "90 System" / "normalized-sources-manifest.json",
        {
            "generated_at": "2026-05-04T10:00:00Z",
            "total_sources": sum(item_count for _, item_count, _ in SOURCE_FAMILIES),
            "families": [
                {"name": family, "item_count": item_count, "status": "normalized"}
                for family, item_count, _ in SOURCE_FAMILIES
            ],
        },
    )

    write_text(
        vault_root / "90 System" / "source-processing-report.md",
        markdown_page(
            "Source Processing Report",
            """
            Fabric normalized the demo vault into clear source families before any wiki compilation happened.

            ## Highlights
            - All raw materials remained immutable.
            - External imports were summarized as families, not treated as final wiki pages.
            - Shared global clusters were generated for cross-project knowledge.
            """,
        ),
    )
    write_json(
        vault_root / "90 System" / "semantic_metadata.json",
        {
            "generated_at": "2026-05-04T10:00:00Z",
            "concept_count": len(CONCEPTS),
            "entity_count": len(ENTITIES),
            "keyword_count": len(all_keywords),
            "cluster_count": len(GLOBAL_CLUSTERS),
        },
    )
    write_text(
        vault_root / "90 System" / "index.md",
        markdown_page(
            "Vault Index",
            """
            Fabric keeps this vault readable by maintaining a stable index across projects, concepts, entities, sources, and global knowledge hubs.
            """,
        ),
    )
    write_text(
        vault_root / "90 System" / "log.md",
        markdown_page(
            "Build Log",
            """
            - 2026-05-04: Demo vault normalized.
            - 2026-05-04: Sources processed into semantic families.
            - 2026-05-04: Projects, concepts, entities, and graph artifacts compiled.
            """,
        ),
    )
    write_text(
        vault_root / "90 System" / "migration-report.md",
        markdown_page(
            "Migration Report",
            """
            This sanitized release demo illustrates Fabric's intended steady-state knowledge-base workflow rather than a raw historical migration.
            """,
        ),
    )

    for family, _, _ in SOURCE_FAMILIES:
        (vault_root / "00 Raw Sources" / family).mkdir(parents=True, exist_ok=True)

    summary = {
        "demo_root": str(root),
        "global_root": str(global_root),
        "vault_root": str(vault_root),
        "settings_path": str(settings_path),
        "default_workspace": str(workspace_paths[PROJECTS[0].slug]),
    }
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description="Prepare a sanitized Fabric release demo environment.")
    parser.add_argument("--output-root", type=Path, default=Path("/tmp/fabric-release-demo"))
    args = parser.parse_args()

    summary = prepare_demo_root(args.output_root.expanduser().resolve())
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
