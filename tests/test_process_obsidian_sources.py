import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools" / "compact_dashboard"))

from process_obsidian_sources import process_sources


class ProcessObsidianSourcesTests(unittest.TestCase):
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

    def test_process_sources_normalizes_multiple_source_families_and_updates_wiki_outputs(self) -> None:
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
                                "task_id": "task-process",
                                "timestamp": "2026-04-30T02:00:00Z",
                                "workspace": str(workspace),
                            }
                        ),
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[SYNC_OK]",
                                "task_id": "task-process",
                                "timestamp": "2026-04-30T02:10:00Z",
                                "summary": "process sources ready",
                                "workspace": str(workspace),
                            }
                        ),
                    ]
                )
                + "\n",
            )
            self._write(
                root / "memory" / "decision-log.ndjson",
                json.dumps(
                    {
                        "task_id": "task-process",
                        "summary": "Normalize imports into immutable raw-source lanes.",
                        "details": "The wiki should be compiled from extracted source elements.",
                        "timestamp": "2026-04-30T02:10:00Z",
                        "workspace": str(workspace),
                    }
                )
                + "\n",
            )
            self._write(
                root / "memory" / "handoffs.ndjson",
                json.dumps(
                    {
                        "task_id": "task-process",
                        "summary": "Maintain one shared import pipeline across all source families.",
                        "details": "NotebookLM, Notion, ChatGPT and shared fabric should feed one normalized shape.",
                        "timestamp": "2026-04-30T02:10:00Z",
                        "workspace": str(workspace),
                    }
                )
                + "\n",
            )
            self._write(
                root / "memory" / "open-loops.ndjson",
                json.dumps(
                    {
                        "task_id": "task-process",
                        "summary": "Add source processing workflow button.",
                        "details": "",
                        "timestamp": "2026-04-30T02:10:00Z",
                        "workspace": str(workspace),
                    }
                )
                + "\n",
            )
            self._write(root / "memory" / "user-question-profile.md", "# Global profile\n\nPrefer structured summaries.\n")
            self._write(root / "sync" / "learning_receipts.ndjson", json.dumps({"task_id": "task-process", "workspace": str(workspace), "timestamp": "2026-04-30T02:10:00Z"}) + "\n")
            self._write(root / "sync" / "task_phases.ndjson", json.dumps({"task_id": "task-process", "workspace": str(workspace), "timestamp": "2026-04-30T02:09:00Z", "phase_key": "report"}) + "\n")

            self._write(vault / "Agent Chat History" / "workspace" / "Codex" / "chat.md", "# Codex Chat\n\nDiscussed MCP_Hub and source normalization.\n")
            self._write(vault / "NotebookLM" / "research.md", "# NotebookLM\n\nMCP_Hub architecture note.\n")
            self._write(vault / "Notion" / "brief.md", "# Notion brief\n\nLink Project4 with MCP_Hub.\n")
            self._write(vault / "ChatGPT" / "session.md", "# ChatGPT\n\nContradiction about repository and wiki responsibilities.\n")
            self._write(vault / "Gemini CLI" / "session.md", "# Gemini CLI\n\nWorkspace MCP_Hub follow-up.\n")
            self._write(root / "workflows" / "imported" / "mcp_hub.md", "# Imported workflow\n\nMCP_Hub cross-project synthesis.\n")

            result = process_sources(
                workspace=workspace,
                global_root=root,
                vault_root=vault,
                raw_chat_dir="Agent Chat History",
                gemini_settings=settings_path,
            )

            self.assertEqual(result["families_processed"], 6)
            self.assertTrue((vault / "90 System" / "normalized-sources-manifest.json").exists())
            self.assertTrue((vault / "90 System" / "source-processing-report.md").exists())
            self.assertTrue((vault / "00 Raw Sources" / "Agent Chats" / "workspace" / "Codex" / "chat.md").exists())
            self.assertTrue((vault / "00 Raw Sources" / "External Imports" / "NotebookLM" / "research.md").exists())
            self.assertTrue((vault / "00 Raw Sources" / "External Imports" / "Notion" / "brief.md").exists())
            self.assertTrue((vault / "00 Raw Sources" / "External Imports" / "ChatGPT" / "session.md").exists())
            self.assertTrue((vault / "00 Raw Sources" / "External Imports" / "Gemini" / "session.md").exists())
            self.assertTrue((vault / "00 Raw Sources" / "Shared Fabric Snapshots" / "workflows-imported" / "mcp_hub.md").exists())

            manifest = json.loads((vault / "90 System" / "normalized-sources-manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["summary"]["family_count"], 6)
            self.assertGreaterEqual(manifest["summary"]["item_count"], 6)
            self.assertEqual(
                result["next_step"],
                "Run export_obsidian_wiki.py --mode build-all to compile source manifests into wiki/system outputs.",
            )
            self.assertFalse((vault / "10 Wiki" / "Sources" / "Overview.md").exists())
            self.assertFalse((vault / "90 System" / "knowledge-base-manifest.json").exists())
            self.assertFalse((vault / "90 System" / "graph.json").exists())


if __name__ == "__main__":
    unittest.main()
