import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from dashboard_data import build_state


class DashboardDataTests(unittest.TestCase):
    def _write(self, path: Path, content: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def _base_fixture(self, root: Path, workspace: Path) -> Path:
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
                ]
            )
            + "\n",
        )
        self._write(
            root / "memory" / "handoffs.ndjson",
            json.dumps(
                {
                    "task_id": "task-live",
                    "summary": "workspace handoff summary",
                    "timestamp": "2026-04-20T06:01:00Z",
                    "workspace": str(workspace),
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
                    "  -",
                    '    id: "qgis"',
                    "    enabled: false",
                    '    command: "/bin/false"',
                    "    args: []",
                    "    env_refs: []",
                ]
            )
            + "\n",
        )
        settings_path = root / "settings.json"
        settings_path.write_text(
            json.dumps({"mcpServers": {"context7": {}, "notebooklm": {}}}, indent=2),
            encoding="utf-8",
        )
        return settings_path

    def test_build_state_uses_exact_phase_when_available(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "MCP_Hub"
            workspace.mkdir()
            settings_path = self._base_fixture(root, workspace)
            self._write(
                root / "sync" / "task_phases.ndjson",
                json.dumps(
                    {
                        "agent": "codex",
                        "task_id": "task-live",
                        "timestamp": "2026-04-20T06:02:00Z",
                        "workspace": str(workspace),
                        "phase_key": "dispatch",
                        "phase_label": "分发",
                        "note": "dispatching UI work",
                    }
                )
                + "\n",
            )

            state = build_state(workspace=workspace, global_root=root, gemini_settings=settings_path)

            self.assertEqual(state.project_name, "MCP_Hub")
            self.assertEqual(state.runtime, "codex")
            self.assertEqual(state.lifecycle_phase, "ACTIVE")
            self.assertEqual(state.task_id, "task-live")
            self.assertEqual(state.boot_status, "OK")
            self.assertEqual(state.sync_status, "--")
            self.assertEqual(state.six_stage_current, "dispatch")
            self.assertEqual(state.six_stage_completed, ["route", "plan", "review"])
            self.assertEqual(state.phase_source, "exact")
            self.assertEqual(state.six_stage_note, "dispatching UI work")
            self.assertEqual(state.active_mcp_count, 2)
            self.assertEqual(state.enabled_registry_count, 1)
            self.assertEqual(state.disabled_registry_count, 1)
            self.assertEqual(state.last_handoff, "workspace handoff summary")

    def test_build_state_falls_back_to_heuristic_execute(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "MCP_Hub"
            workspace.mkdir()
            settings_path = self._base_fixture(root, workspace)

            state = build_state(workspace=workspace, global_root=root, gemini_settings=settings_path)

            self.assertEqual(state.six_stage_current, "execute")
            self.assertEqual(state.six_stage_completed, ["route", "plan", "review", "dispatch"])
            self.assertEqual(state.phase_source, "heuristic")
            self.assertIn("phase source = heuristic", state.alerts)

    def test_build_state_prefers_latest_task_over_stale_boot_only_task(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "MCP_Hub"
            workspace.mkdir()
            settings_path = self._base_fixture(root, workspace)
            self._write(
                root / "sync" / "receipts.ndjson",
                "\n".join(
                    [
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[BOOT_OK]",
                                "task_id": "task-stale",
                                "timestamp": "2026-04-20T05:00:00Z",
                                "workspace": str(workspace),
                            }
                        ),
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[BOOT_OK]",
                                "task_id": "task-fresh",
                                "timestamp": "2026-04-20T06:00:00Z",
                                "workspace": str(workspace),
                            }
                        ),
                        json.dumps(
                            {
                                "agent": "codex",
                                "status_marker": "[SYNC_OK]",
                                "task_id": "task-fresh",
                                "timestamp": "2026-04-20T06:10:00Z",
                                "workspace": str(workspace),
                            }
                        ),
                    ]
                )
                + "\n",
            )

            state = build_state(workspace=workspace, global_root=root, gemini_settings=settings_path)

            self.assertEqual(state.task_id, "task-fresh")
            self.assertEqual(state.sync_status, "OK")
            self.assertEqual(state.six_stage_current, "report")



if __name__ == "__main__":
    unittest.main()
