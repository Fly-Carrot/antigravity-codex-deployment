import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools" / "compact_dashboard"))

from export_obsidian_wiki import export_obsidian_wiki


class ExportObsidianWikiTests(unittest.TestCase):
    def _write(self, path: Path, content: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def _write_registry(self, root: Path, projects: list[tuple[str, str]]) -> None:
        lines = ["version: 1", "projects:"]
        for name, path in projects:
            lines.extend(
                [
                    "  -",
                    f'    id: "{name.lower().replace(" ", "-")}"',
                    f'    name: "{name}"',
                    f'    path: "{path}"',
                    "    overlay_rules: []",
                    f'    overlay_root: "{path}/.agents"',
                ]
            )
        self._write(root / "projects" / "registry.yaml", "\n".join(lines) + "\n")

    def _base_fixture(self, root: Path, workspace: Path) -> Path:
        self._write(
            root / "mcp" / "servers.yaml",
            "\n".join(
                [
                    "version: 1",
                    "servers:",
                    "  -",
                    '    id: "context7"',
                    "    enabled: true",
                    '    command: "/bin/true"',
                    "    args: []",
                    "    env_refs: []",
                ]
            )
            + "\n",
        )
        settings_path = root / "settings.json"
        settings_path.write_text(json.dumps({"mcpServers": {"context7": {}}}), encoding="utf-8")
        self._write_registry(root, [(workspace.name, str(workspace))])
        return settings_path

    def test_export_obsidian_wiki_builds_system_and_project_pages(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "fabric"
            workspace = Path(tmpdir) / "workspace"
            vault = Path(tmpdir) / "vault"
            workspace.mkdir()
            vault.mkdir()
            settings_path = self._base_fixture(root, workspace)
            self._write(
                root / "sync" / "receipts.ndjson",
                "\n".join(
                    [
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[BOOT_OK]",
                                "task_id": "task-wiki",
                                "timestamp": "2026-04-28T03:00:00Z",
                                "workspace": str(workspace),
                            }
                        ),
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[SYNC_OK]",
                                "task_id": "task-wiki",
                                "timestamp": "2026-04-28T03:10:00Z",
                                "summary": "wiki build ready",
                                "workspace": str(workspace),
                            }
                        ),
                    ]
                )
                + "\n",
            )
            self._write(
                root / "memory" / "handoffs.ndjson",
                json.dumps(
                    {
                        "task_id": "task-wiki",
                        "summary": "当前重点是把项目记忆编译成可维护的 Obsidian wiki 页面。",
                        "details": "Need current status and architecture pages.",
                        "timestamp": "2026-04-28T03:10:00Z",
                        "workspace": str(workspace),
                    }
                )
                + "\n",
            )
            self._write(
                root / "memory" / "decision-log.ndjson",
                json.dumps(
                    {
                        "task_id": "task-wiki",
                        "summary": "Use raw-sources/wiki/schema as the Obsidian model.",
                        "details": "Chat export should become raw sources, not the final memory artifact.",
                        "timestamp": "2026-04-28T03:10:00Z",
                        "workspace": str(workspace),
                        "artifacts": [str(workspace / "docs" / "plan.md")],
                    }
                )
                + "\n",
            )
            self._write(
                root / "memory" / "open-loops.ndjson",
                json.dumps(
                    {
                        "task_id": "task-wiki",
                        "summary": "Implement Normalize Vault Layout and Build Current Project Wiki actions.",
                        "details": "",
                        "timestamp": "2026-04-28T03:10:00Z",
                        "workspace": str(workspace),
                    }
                )
                + "\n",
            )
            self._write(
                root / "memory" / "mempalace-records.ndjson",
                json.dumps(
                    {
                        "task_id": "task-wiki",
                        "summary": "Compared current archive-centric design with llm-wiki maintenance model.",
                        "details": "The maintained wiki layer should sit between raw chats and future retrieval.",
                        "timestamp": "2026-04-28T03:10:00Z",
                        "workspace": str(workspace),
                    }
                )
                + "\n",
            )
            self._write(
                root / "memory" / "promoted-learnings.ndjson",
                json.dumps(
                    {
                        "task_id": "task-wiki",
                        "summary": "Structured project memory can render stable wiki pages.",
                        "details": "Current Status and Architecture are strong first generated pages.",
                        "timestamp": "2026-04-28T03:10:00Z",
                        "workspace": str(workspace),
                    }
                )
                + "\n",
            )
            self._write(
                root / "sync" / "learning_receipts.ndjson",
                json.dumps(
                    {
                        "agent": "codex",
                        "task_id": "task-wiki",
                        "timestamp": "2026-04-28T03:10:00Z",
                        "workspace": str(workspace),
                        "writes": {
                            "receipts": 1,
                            "handoffs": 1,
                            "decision_log": 1,
                            "open_loops": 1,
                            "mempalace_records": 1,
                            "promoted_learnings": 1,
                        },
                        "source_summary": "wiki build ready",
                    }
                )
                + "\n",
            )
            self._write(
                root / "sync" / "task_phases.ndjson",
                json.dumps(
                    {
                        "agent": "codex",
                        "task_id": "task-wiki",
                        "timestamp": "2026-04-28T03:09:00Z",
                        "workspace": str(workspace),
                        "phase_key": "report",
                        "phase_label": "回奏",
                        "note": "reporting wiki build work",
                    }
                )
                + "\n",
            )
            self._write(root / "memory" / "user-question-profile.md", "# Global profile\n\n偏好中文输出。\n")
            self._write(workspace / ".agents" / "sync" / "user-question-profile.md", "# Workspace profile\n\n喜欢结构化架构报告。\n")
            self._write(
                root / "memory" / "user-question-profiles.ndjson",
                json.dumps(
                    {
                        "workspace": str(workspace),
                        "task_id": "task-wiki",
                        "timestamp": "2026-04-28T03:10:00Z",
                        "summary": "偏好中文和结构化报告",
                    }
                )
                + "\n",
            )

            result = export_obsidian_wiki(
                workspace=workspace,
                global_root=root,
                vault_root=vault,
                gemini_settings=settings_path,
                raw_chat_dir="00 Raw Sources/Agent Chats",
                mode="both",
            )

            self.assertEqual(result["project_name"], "workspace")
            self.assertTrue((vault / "90 System" / "obsidian-wiki-schema.md").exists())
            self.assertTrue((vault / "90 System" / "index.md").exists())
            self.assertTrue((vault / "90 System" / "log.md").exists())
            self.assertTrue((vault / "10 Wiki" / "Projects" / "workspace" / "Overview.md").exists())
            self.assertTrue((vault / "10 Wiki" / "Projects" / "workspace" / "Current Status.md").exists())
            self.assertTrue((vault / "10 Wiki" / "Projects" / "workspace" / "Architecture.md").exists())
            self.assertTrue((vault / "10 Wiki" / "Projects" / "workspace" / "Decisions.md").exists())
            self.assertTrue((vault / "10 Wiki" / "Projects" / "workspace" / "Open Questions.md").exists())
            self.assertTrue((vault / "10 Wiki" / "Projects" / "workspace" / "Sources.md").exists())

            schema_text = (vault / "90 System" / "obsidian-wiki-schema.md").read_text(encoding="utf-8")
            self.assertIn("00 Raw Sources/Agent Chats/", schema_text)
            self.assertIn("10 Wiki/Projects/<project>/", schema_text)

            status_text = (vault / "10 Wiki" / "Projects" / "workspace" / "Current Status.md").read_text(encoding="utf-8")
            self.assertIn("项目更新日志", status_text)
            self.assertIn("近期轮次变更", status_text)

            architecture_text = (vault / "10 Wiki" / "Projects" / "workspace" / "Architecture.md").read_text(encoding="utf-8")
            self.assertIn("架构与运行脉络", architecture_text)
            self.assertIn("过程记忆与实现脉络", architecture_text)

            sources_text = (vault / "10 Wiki" / "Projects" / "workspace" / "Sources.md").read_text(encoding="utf-8")
            self.assertIn("plan.md", sources_text)

            index_text = (vault / "90 System" / "index.md").read_text(encoding="utf-8")
            self.assertIn("workspace Overview", index_text)

    def test_export_obsidian_wiki_normalize_only_skips_project_pages(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "fabric"
            workspace = Path(tmpdir) / "workspace"
            vault = Path(tmpdir) / "vault"
            workspace.mkdir()
            vault.mkdir()
            settings_path = self._base_fixture(root, workspace)
            self._write(
                root / "sync" / "receipts.ndjson",
                json.dumps(
                    {
                        "agent": "codex",
                        "status_marker": "[BOOT_OK]",
                        "task_id": "task-normalize",
                        "timestamp": "2026-04-28T04:00:00Z",
                        "workspace": str(workspace),
                    }
                )
                + "\n",
            )
            self._write(root / "memory" / "handoffs.ndjson", "")
            self._write(root / "memory" / "decision-log.ndjson", "")
            self._write(root / "memory" / "open-loops.ndjson", "")
            self._write(root / "memory" / "mempalace-records.ndjson", "")
            self._write(root / "memory" / "promoted-learnings.ndjson", "")
            self._write(root / "sync" / "learning_receipts.ndjson", "")
            self._write(root / "sync" / "task_phases.ndjson", "")
            self._write(root / "memory" / "user-question-profile.md", "")
            self._write(workspace / ".agents" / "sync" / "user-question-profile.md", "")
            self._write(root / "memory" / "user-question-profiles.ndjson", "")

            result = export_obsidian_wiki(
                workspace=workspace,
                global_root=root,
                vault_root=vault,
                gemini_settings=settings_path,
                raw_chat_dir="00 Raw Sources/Agent Chats",
                mode="normalize",
            )

            self.assertEqual(result["mode"], "normalize")
            self.assertTrue((vault / "00 Raw Sources" / "Agent Chats" / "README.md").exists())
            self.assertTrue((vault / "90 System" / "index.md").exists())
            self.assertFalse((vault / "10 Wiki" / "Projects" / "workspace" / "Overview.md").exists())

    def test_export_obsidian_wiki_build_all_generates_manifest_graph_and_migration_report(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "fabric"
            workspace_a = Path(tmpdir) / "Project Alpha"
            workspace_b = Path(tmpdir) / "Project Beta"
            vault = Path(tmpdir) / "vault"
            workspace_a.mkdir()
            workspace_b.mkdir()
            vault.mkdir()
            settings_path = self._base_fixture(root, workspace_a)
            self._write_registry(root, [("Project Alpha", str(workspace_a)), ("Project Beta", str(workspace_b))])
            self._write(vault / "Agent Chat History" / "README.md", "# legacy\n")

            self._write(
                root / "sync" / "receipts.ndjson",
                "\n".join(
                    [
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[BOOT_OK]",
                                "task_id": "task-alpha",
                                "timestamp": "2026-04-28T05:00:00Z",
                                "workspace": str(workspace_a),
                            }
                        ),
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[SYNC_OK]",
                                "task_id": "task-alpha",
                                "timestamp": "2026-04-28T05:05:00Z",
                                "summary": "alpha ready",
                                "workspace": str(workspace_a),
                            }
                        ),
                        json.dumps(
                            {
                                "agent": "gemini",
                                "status_marker": "[SYNC_OK]",
                                "task_id": "task-beta",
                                "timestamp": "2026-04-28T05:07:00Z",
                                "summary": "beta ready",
                                "workspace": str(workspace_b),
                            }
                        ),
                    ]
                )
                + "\n",
            )
            self._write(
                root / "memory" / "handoffs.ndjson",
                "\n".join(
                    [
                        json.dumps(
                            {
                                "task_id": "task-alpha",
                                "summary": "Alpha focus",
                                "timestamp": "2026-04-28T05:05:00Z",
                                "workspace": str(workspace_a),
                            }
                        ),
                        json.dumps(
                            {
                                "task_id": "task-beta",
                                "summary": "Beta focus",
                                "timestamp": "2026-04-28T05:07:00Z",
                                "workspace": str(workspace_b),
                            }
                        ),
                    ]
                )
                + "\n",
            )
            self._write(
                root / "memory" / "decision-log.ndjson",
                "\n".join(
                    [
                        json.dumps(
                            {
                                "task_id": "task-alpha",
                                "summary": "Alpha decision",
                                "details": "Alpha detail",
                                "timestamp": "2026-04-28T05:05:00Z",
                                "workspace": str(workspace_a),
                            }
                        ),
                        json.dumps(
                            {
                                "task_id": "task-beta",
                                "summary": "Beta decision",
                                "details": "Beta detail",
                                "timestamp": "2026-04-28T05:07:00Z",
                                "workspace": str(workspace_b),
                            }
                        ),
                    ]
                )
                + "\n",
            )
            self._write(root / "memory" / "open-loops.ndjson", "")
            self._write(root / "memory" / "mempalace-records.ndjson", "")
            self._write(root / "memory" / "promoted-learnings.ndjson", "")
            self._write(root / "sync" / "learning_receipts.ndjson", "\n")
            self._write(root / "sync" / "task_phases.ndjson", "\n")
            self._write(root / "memory" / "user-question-profile.md", "# Global\n")
            self._write(workspace_a / ".agents" / "sync" / "user-question-profile.md", "# A\n")
            self._write(workspace_b / ".agents" / "sync" / "user-question-profile.md", "# B\n")
            self._write(root / "memory" / "user-question-profiles.ndjson", "")

            result = export_obsidian_wiki(
                workspace=workspace_a,
                global_root=root,
                vault_root=vault,
                gemini_settings=settings_path,
                raw_chat_dir="00 Raw Sources/Agent Chats",
                mode="build-all",
            )

            self.assertEqual(result["projects_built"], 2)
            self.assertTrue((vault / "90 System" / "knowledge-base-manifest.json").exists())
            self.assertTrue((vault / "90 System" / "graph.json").exists())
            self.assertTrue((vault / "90 System" / "migration-report.md").exists())
            self.assertTrue((vault / "10 Wiki" / "Projects" / "project-alpha" / "Overview.md").exists())
            self.assertTrue((vault / "10 Wiki" / "Projects" / "project-beta" / "Overview.md").exists())

            manifest = json.loads((vault / "90 System" / "knowledge-base-manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["summary"]["project_count"], 2)
            self.assertEqual(manifest["summary"]["legacy_source_count"], 1)
            self.assertEqual(len(manifest["projects"]), 2)

            graph = json.loads((vault / "90 System" / "graph.json").read_text(encoding="utf-8"))
            self.assertGreater(graph["node_count"], 2)
            self.assertGreater(graph["edge_count"], 2)

            migration = (vault / "90 System" / "migration-report.md").read_text(encoding="utf-8")
            self.assertIn("Agent Chat History", migration)
            self.assertIn("conservative", migration.lower())


if __name__ == "__main__":
    unittest.main()
