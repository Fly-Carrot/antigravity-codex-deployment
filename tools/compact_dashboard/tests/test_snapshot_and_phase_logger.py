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

    def test_export_snapshot_prints_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "MCP_Hub"
            workspace.mkdir()
            self._write(
                root / "sync" / "receipts.ndjson",
                json.dumps(
                    {
                        "agent": "codex",
                        "status_marker": "[BOOT_OK]",
                        "task_id": "task-live",
                        "timestamp": "2026-04-20T06:00:00Z",
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
            self.assertEqual(payload["six_stage_current"], "execute")
            self.assertEqual(payload["phase_source"], "heuristic")


if __name__ == "__main__":
    unittest.main()
