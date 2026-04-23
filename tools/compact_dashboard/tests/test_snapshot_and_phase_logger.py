import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

DASHBOARD_DIR = Path(__file__).resolve().parents[1]
EXPORT_SNAPSHOT = DASHBOARD_DIR / "export_snapshot.py"
PHASE_LOGGER = Path(__file__).resolve().parents[3] / "fabric" / "scripts" / "sync" / "log_task_phase.py"


class SnapshotAndPhaseLoggerTests(unittest.TestCase):
    def _write(self, path: Path, content: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def test_phase_logger_writes_valid_record(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "MCP_Hub"
            workspace.mkdir()

            result = subprocess.run(
                [
                    sys.executable,
                    str(PHASE_LOGGER),
                    "--global-root",
                    str(root),
                    "--workspace",
                    str(workspace),
                    "--agent",
                    "codex",
                    "--task-id",
                    "phase-test",
                    "--phase",
                    "plan",
                    "--note",
                    "planning dashboard",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            payload = json.loads(result.stdout)
            self.assertEqual(payload["phase_key"], "plan")

            records = (root / "sync" / "task_phases.ndjson").read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(records), 1)
            record = json.loads(records[0])
            self.assertEqual(record["phase_key"], "plan")
            self.assertEqual(record["phase_label"], "规划")
            self.assertEqual(record["note"], "planning dashboard")

    def test_phase_logger_rejects_invalid_phase_without_writing(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "MCP_Hub"
            workspace.mkdir()

            result = subprocess.run(
                [
                    sys.executable,
                    str(PHASE_LOGGER),
                    "--global-root",
                    str(root),
                    "--workspace",
                    str(workspace),
                    "--agent",
                    "codex",
                    "--task-id",
                    "phase-test",
                    "--phase",
                    "bad-phase",
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / "sync" / "task_phases.ndjson").exists())

    def test_export_snapshot_prints_json_with_sync_delta(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "MCP_Hub"
            workspace.mkdir()
            self._write(
                root / "sync" / "receipts.ndjson",
                "\n".join(
                    [
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[BOOT_OK]",
                                "task_id": "task-live",
                                "timestamp": "2026-04-20T06:00:00Z",
                                "workspace": str(workspace),
                            }
                        ),
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[SYNC_OK]",
                                "task_id": "task-live",
                                "timestamp": "2026-04-20T06:01:00Z",
                                "summary": "snapshot sync",
                                "workspace": str(workspace),
                            }
                        ),
                    ]
                )
                + "\n",
            )
            self._write(
                root / "sync" / "learning_receipts.ndjson",
                json.dumps(
                    {
                        "agent": "codex",
                        "task_id": "task-live",
                        "timestamp": "2026-04-20T06:01:00Z",
                        "workspace": str(workspace),
                        "writes": {"receipts": 1, "handoffs": 1, "promoted_learnings": 1},
                        "learned_items": ["Snapshot carries sync delta"],
                        "skipped_items": [],
                        "source_summary": "snapshot sync",
                    }
                )
                + "\n",
            )
            self._write(
                root / "memory" / "user-question-profiles.ndjson",
                json.dumps(
                    {
                        "agent": "codex",
                        "task_id": "task-live",
                        "timestamp": "2026-04-20T06:01:00Z",
                        "workspace": str(workspace),
                    }
                )
                + "\n",
            )
            self._write(
                root / "memory" / "user-question-profile.md",
                "\n".join(
                    [
                        "# Global User Question Profile",
                        "",
                        "Compiled from `1` distilled user-question snapshots across `1` workspace(s).",
                        "Last updated: `2026-04-20T06:01:00Z`",
                    ]
                )
                + "\n",
            )
            self._write(
                workspace / ".agents" / "sync" / "user-question-profile.md",
                "\n".join(
                    [
                        "# Workspace User Question Profile",
                        "",
                        "Compiled from `1` distilled user-question snapshots across `1` workspace(s).",
                        "Last updated: `2026-04-20T06:01:00Z`",
                    ]
                )
                + "\n",
            )
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

            result = subprocess.run(
                [
                    sys.executable,
                    str(EXPORT_SNAPSHOT),
                    "--workspace",
                    str(workspace),
                    "--global-root",
                    str(root),
                    "--gemini-settings",
                    str(settings_path),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            payload = json.loads(result.stdout)
            self.assertEqual(payload["project_name"], "MCP_Hub")
            self.assertEqual(payload["workspace_mode"], "pinned")
            self.assertEqual(payload["six_stage_current"], "")
            self.assertEqual(payload["phase_source"], "heuristic")
            self.assertFalse(payload["is_bridged"])
            self.assertEqual(payload["sync_audit_source"], "exact")
            self.assertEqual(payload["last_sync_delta"]["learned_items"], ["Snapshot carries sync delta"])
            self.assertEqual(payload["last_sync_delta"]["records"][0]["title"], "Learning Receipt")
            self.assertEqual(payload["user_question_profile"]["snapshot_count"], 1)
            self.assertEqual(payload["user_question_profile"]["workspace_snapshot_count"], 1)
            self.assertEqual(
                payload["user_question_profile"]["global_profile"]["summary"],
                "Compiled from `1` distilled user-question snapshots across `1` workspace(s).",
            )
            self.assertIn("project_memory_counts", payload)
            self.assertIn("project_memory_records", payload)
            self.assertEqual(payload["attention_state"], "healthy")

    def test_export_snapshot_auto_follows_latest_workspace(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace_a = root / "MCP_Hub"
            workspace_b = root / "Project4"
            workspace_a.mkdir()
            workspace_b.mkdir()
            self._write(
                root / "sync" / "receipts.ndjson",
                "\n".join(
                    [
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[BOOT_OK]",
                                "task_id": "task-a",
                                "timestamp": "2026-04-20T06:00:00Z",
                                "workspace": str(workspace_a),
                            }
                        ),
                        json.dumps(
                            {
                                "agent": "gemini",
                                "status_marker": "[SYNC_OK]",
                                "task_id": "task-b",
                                "timestamp": "2026-04-20T06:02:00Z",
                                "summary": "project4 sync",
                                "workspace": str(workspace_b),
                            }
                        ),
                    ]
                )
                + "\n",
            )
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

            result = subprocess.run(
                [
                    sys.executable,
                    str(EXPORT_SNAPSHOT),
                    "--global-root",
                    str(root),
                    "--gemini-settings",
                    str(settings_path),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            payload = json.loads(result.stdout)
            self.assertEqual(Path(payload["workspace"]), workspace_b.resolve())
            self.assertEqual(payload["workspace_mode"], "auto")
            self.assertEqual(payload["project_name"], "Project4")
            self.assertEqual(payload["runtime"], "gemini")

    def test_export_snapshot_includes_available_workspaces(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "MCP_Hub"
            registered = root / "Project5"
            workspace.mkdir()
            registered.mkdir()
            self._write(
                root / "sync" / "receipts.ndjson",
                json.dumps(
                    {
                        "agent": "codex",
                        "status_marker": "[SYNC_OK]",
                        "task_id": "task-live",
                        "timestamp": "2026-04-20T06:01:00Z",
                        "summary": "snapshot sync",
                        "workspace": str(workspace),
                    }
                )
                + "\n",
            )
            self._write(
                root / "projects" / "registry.yaml",
                "\n".join(
                    [
                        "version: 1",
                        "projects:",
                        "  -",
                        '    id: "mcp-hub"',
                        '    name: "MCP_Hub"',
                        f'    path: "{workspace}"',
                        "    overlay_rules: []",
                        f'    overlay_root: "{workspace}/.agents"',
                        "  -",
                        '    id: "project5"',
                        '    name: "Project5"',
                        f'    path: "{registered}"',
                        "    overlay_rules: []",
                        f'    overlay_root: "{registered}/.agents"',
                    ]
                )
                + "\n",
            )
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

            result = subprocess.run(
                [
                    sys.executable,
                    str(EXPORT_SNAPSHOT),
                    "--workspace",
                    str(workspace),
                    "--global-root",
                    str(root),
                    "--gemini-settings",
                    str(settings_path),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            payload = json.loads(result.stdout)
            self.assertEqual([item["label"] for item in payload["available_workspaces"]], ["MCP_Hub", "Project5"])
            self.assertEqual([item["source"] for item in payload["available_workspaces"]], ["active", "registered"])

    def test_export_snapshot_filters_missing_workspace_candidates(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "MCP_Hub"
            missing = root / "Shixi"
            workspace.mkdir()
            self._write(
                root / "sync" / "receipts.ndjson",
                "\n".join(
                    [
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[SYNC_OK]",
                                "task_id": "task-live",
                                "timestamp": "2026-04-20T06:01:00Z",
                                "summary": "snapshot sync",
                                "workspace": str(workspace),
                            }
                        ),
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[SYNC_OK]",
                                "task_id": "task-missing",
                                "timestamp": "2026-04-20T06:05:00Z",
                                "summary": "missing sync",
                                "workspace": str(missing),
                            }
                        ),
                    ]
                )
                + "\n",
            )
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

            result = subprocess.run(
                [
                    sys.executable,
                    str(EXPORT_SNAPSHOT),
                    "--global-root",
                    str(root),
                    "--gemini-settings",
                    str(settings_path),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            payload = json.loads(result.stdout)
            self.assertEqual(Path(payload["workspace"]), workspace.resolve())
            self.assertEqual([item["label"] for item in payload["available_workspaces"]], ["MCP_Hub"])

    def test_export_snapshot_includes_bridge_fields(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "MCP_Hub"
            workspace.mkdir()
            self._write(
                root / "sync" / "receipts.ndjson",
                "\n".join(
                    [
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[BOOT_OK]",
                                "task_id": "task-bridge",
                                "timestamp": "2026-04-20T06:00:00Z",
                                "workspace": str(workspace),
                            }
                        ),
                        json.dumps(
                            {
                                "agent": "codex",
                                "task_id": "task-bridge",
                                "timestamp": "2026-04-20T06:01:00Z",
                                "workspace": str(workspace),
                                "hook": "multicli_bridge",
                                "bridge_session_id": "bridge-codex-to-gemini-demo",
                                "bridge_mode": "handoff",
                                "origin_runtime": "codex",
                                "target_runtime": "gemini",
                                "context_entrypoint": "AGENTS.md",
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
                        "task_id": "task-bridge",
                        "summary": "Codex handed work to Gemini",
                        "timestamp": "2026-04-20T06:02:00Z",
                        "workspace": str(workspace),
                        "bridge_session_id": "bridge-codex-to-gemini-demo",
                        "bridge_mode": "handoff",
                        "origin_runtime": "codex",
                        "target_runtime": "gemini",
                    }
                )
                + "\n",
            )
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

            result = subprocess.run(
                [
                    sys.executable,
                    str(EXPORT_SNAPSHOT),
                    "--workspace",
                    str(workspace),
                    "--global-root",
                    str(root),
                    "--gemini-settings",
                    str(settings_path),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            payload = json.loads(result.stdout)
            self.assertTrue(payload["is_bridged"])
            self.assertEqual(payload["bridge_session_id"], "bridge-codex-to-gemini-demo")
            self.assertEqual(payload["bridge_mode"], "handoff")
            self.assertEqual(payload["origin_runtime"], "codex")
            self.assertEqual(payload["target_runtime"], "gemini")
            bridge_handoff = next(item for item in payload["project_memory_records"] if item["task_id"] == "task-bridge")
            self.assertTrue(bridge_handoff["is_bridged"])
            self.assertEqual(bridge_handoff["bridge_session_id"], "bridge-codex-to-gemini-demo")
            self.assertEqual(bridge_handoff["origin_runtime"], "codex")
            self.assertEqual(bridge_handoff["target_runtime"], "gemini")


if __name__ == "__main__":
    unittest.main()
