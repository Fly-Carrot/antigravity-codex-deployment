import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SYNC_DIR = Path(__file__).resolve().parents[1] / "fabric" / "scripts" / "sync"
BACKFILL_SCRIPT = SYNC_DIR / "backfill_rich_memory.py"


class MemoryExpansionBackfillTests(unittest.TestCase):
    def _write(self, path: Path, content: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def test_backfill_generates_rich_project4_memory_bundle_from_imported_workflow(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "Project4"
            workspace.mkdir()
            workflow = root / "workflows" / "imported" / "antigravity-task-123.md"
            self._write(
                workflow,
                "\n".join(
                    [
                        "---",
                        'task_id: "task-123"',
                        "---",
                        "",
                        "## Task",
                        "",
                        "# Project tracker",
                        "- [ ] polish the discussion",
                        "- [x] render main figure",
                        "",
                        "## Implementation Plan",
                        "",
                        "Plan summary with architecture rationale and cross-runtime considerations.",
                        "",
                        "## Walkthrough",
                        "",
                        "Walkthrough summary with execution detail, verification, and follow-up context.",
                        "",
                    ]
                ),
            )
            self._write(
                root / "memory" / "handoffs.ndjson",
                json.dumps(
                    {
                        "timestamp": "2026-04-10T00:00:00Z",
                        "agent": "antigravity",
                        "workspace": str(workspace),
                        "task_id": "task-123",
                        "summary": "Short old handoff",
                        "details": "Sparse details",
                        "artifacts": [str(workflow)],
                    }
                )
                + "\n",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(BACKFILL_SCRIPT),
                    "--global-root",
                    str(root),
                    "--workspace",
                    str(workspace),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            payload = json.loads(result.stdout)
            self.assertGreaterEqual(payload["generated_memory_records"], 5)

            decision_records = [
                json.loads(line)
                for line in (root / "memory" / "decision-log.ndjson").read_text(encoding="utf-8").splitlines()
            ]
            self.assertTrue(any(record.get("bundle_version") == 2 for record in decision_records))

            mem_records = [
                json.loads(line)
                for line in (root / "memory" / "mempalace-records.ndjson").read_text(encoding="utf-8").splitlines()
            ]
            self.assertTrue(mem_records)

            receipt_records = [
                json.loads(line)
                for line in (root / "sync" / "learning_receipts.ndjson").read_text(encoding="utf-8").splitlines()
            ]
            self.assertEqual(receipt_records[0]["type"], "historical_backfill_receipt")
            self.assertEqual(receipt_records[0]["writes"]["mempalace_records"], 1)
            self.assertEqual(receipt_records[0]["generated_records"][0]["lane"], "decision_log")

    def test_backfill_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "Project4"
            workspace.mkdir()
            workflow = root / "workflows" / "imported" / "antigravity-task-123.md"
            self._write(
                workflow,
                "\n".join(
                    [
                        "## Task",
                        "A task body",
                        "## Implementation Plan",
                        "A plan body",
                        "## Walkthrough",
                        "A walkthrough body",
                    ]
                ),
            )
            self._write(
                root / "memory" / "handoffs.ndjson",
                json.dumps(
                    {
                        "timestamp": "2026-04-10T00:00:00Z",
                        "agent": "antigravity",
                        "workspace": str(workspace),
                        "task_id": "task-123",
                        "summary": "Short old handoff",
                        "details": "Sparse details",
                        "artifacts": [str(workflow)],
                    }
                )
                + "\n",
            )

            for _ in range(2):
                subprocess.run(
                    [
                        sys.executable,
                        str(BACKFILL_SCRIPT),
                        "--global-root",
                        str(root),
                        "--workspace",
                        str(workspace),
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                )

            receipts = (root / "sync" / "learning_receipts.ndjson").read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(receipts), 1)


if __name__ == "__main__":
    unittest.main()
