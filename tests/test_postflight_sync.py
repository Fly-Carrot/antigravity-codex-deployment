import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "fabric" / "scripts" / "sync" / "postflight_sync.py"


class PostflightSyncTests(unittest.TestCase):
    def test_postflight_writes_learning_receipt_and_routes(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "workspace"
            workspace.mkdir()

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--global-root",
                    str(root),
                    "--workspace",
                    str(workspace),
                    "--agent",
                    "codex",
                    "--task-id",
                    "sync-test",
                    "--summary",
                    "dashboard 2.1 sync complete",
                    "--decision",
                    "Use learning receipts for audit visibility",
                    "--open-loop",
                    "Refine the workspace bootstrap flow next",
                    "--learned-item",
                    "Learning receipts show exactly what changed",
                    "--skipped-item",
                    "No extra open loops to record",
                    "--mempalace-record",
                    "Tracked the design tradeoff discussion",
                    "--promoted-learning",
                    "SwiftUI cards improve glanceability",
                    "--bridge-session-id",
                    "bridge-codex-to-gemini-test",
                    "--bridge-mode",
                    "handoff",
                    "--origin-runtime",
                    "codex",
                    "--target-runtime",
                    "gemini",
                    "--context-entrypoint",
                    "AGENTS.md",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            payload = json.loads(result.stdout)
            self.assertEqual(payload["status_marker"], "[SYNC_OK]")
            self.assertEqual(payload["writes"]["receipts"], 1)
            self.assertEqual(payload["writes"]["handoffs"], 1)
            self.assertEqual(payload["writes"]["decision_log"], 1)
            self.assertEqual(payload["writes"]["open_loops"], 1)
            self.assertEqual(payload["writes"]["mempalace_records"], 1)
            self.assertEqual(payload["writes"]["promoted_learnings"], 1)
            self.assertEqual(payload["learned_items"][0], "Learning receipts show exactly what changed")

            learning_records = (root / "sync" / "learning_receipts.ndjson").read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(learning_records), 1)
            learning = json.loads(learning_records[0])
            self.assertEqual(learning["source_summary"], "dashboard 2.1 sync complete")
            self.assertEqual(learning["writes"]["promoted_learnings"], 1)
            self.assertEqual(learning["bridge_session_id"], "bridge-codex-to-gemini-test")
            self.assertEqual(learning["origin_runtime"], "codex")
            self.assertEqual(learning["target_runtime"], "gemini")
            self.assertEqual(len(learning["generated_records"]), 5)

            decision = json.loads((root / "memory" / "decision-log.ndjson").read_text(encoding="utf-8").splitlines()[0])
            self.assertEqual(decision["lane"], "decision_log")
            self.assertEqual(decision["bundle_version"], 2)
            promoted = json.loads((root / "memory" / "promoted-learnings.ndjson").read_text(encoding="utf-8").splitlines()[0])
            self.assertEqual(promoted["mechanism"], "cc-skill-continuous-learning")
            self.assertEqual(promoted["bridge_mode"], "handoff")
            mempalace = json.loads((root / "memory" / "mempalace-records.ndjson").read_text(encoding="utf-8").splitlines()[0])
            self.assertEqual(mempalace["mechanism"], "mempalace")

    def test_postflight_dry_run_surfaces_learning_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            workspace = root / "workspace"
            workspace.mkdir()

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--global-root",
                    str(root),
                    "--workspace",
                    str(workspace),
                    "--agent",
                    "codex",
                    "--task-id",
                    "sync-test",
                    "--summary",
                    "dry run sync",
                    "--dry-run",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            payload = json.loads(result.stdout)
            self.assertEqual(payload["status_marker"], "[SYNC_DRY_RUN]")
            self.assertIn("learning_receipt", payload)
            self.assertFalse((root / "sync" / "learning_receipts.ndjson").exists())


if __name__ == "__main__":
    unittest.main()
