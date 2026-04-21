import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace

from install.bootstrap_shared_fabric import (
    build_install_command,
    derive_values,
    ensure_layout,
    render_env_file,
)


class BootstrapSharedFabricTests(unittest.TestCase):
    def test_derive_values_defaults_projects_under_desktop(self) -> None:
        with TemporaryDirectory() as tmpdir:
            home = Path(tmpdir) / "home"
            desktop = home / "Desktop"
            args = SimpleNamespace(
                non_interactive=True,
                user_home=home,
                desktop_root=desktop,
                framework_source_root=Path(__file__).resolve().parents[1] / "fabric",
                global_root=home / "Antigravity_Skills" / "global-agent-fabric",
                awesome_skills_root=None,
                gemini_root=None,
                gemini_settings=None,
                gemini_rule=None,
                antigravity_mcp_config=None,
                antigravity_brain_root=None,
                antigravity_history_root=None,
                codex_root=None,
            )

            values = derive_values(args)

            self.assertEqual(Path(values["AGF_PROJECT_MCP_HUB"]), (desktop / "MCP_Hub").resolve())
            self.assertEqual(Path(values["AGF_PROJECT_4"]), (desktop / "Project4").resolve())
            self.assertTrue(values["AGF_GEMINI_RULE"].endswith("/.gemini/GEMINI.md"))

    def test_ensure_layout_creates_skeleton_and_placeholders(self) -> None:
        with TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            values = {
                "AGF_FRAMEWORK_SOURCE_ROOT": str(Path(__file__).resolve().parents[1] / "fabric"),
                "AGF_GLOBAL_ROOT": str(root / "global-agent-fabric"),
                "AGF_AWESOME_SKILLS_ROOT": str(root / "awesome-skills"),
                "AGF_GEMINI_ROOT": str(root / ".gemini"),
                "AGF_GEMINI_SETTINGS": str(root / ".gemini" / "settings.json"),
                "AGF_GEMINI_RULE": str(root / ".gemini" / "GEMINI.md"),
                "AGF_ANTIGRAVITY_MCP_CONFIG": str(root / ".gemini" / "antigravity" / "mcp_config.json"),
                "AGF_ANTIGRAVITY_BRAIN_ROOT": str(root / ".gemini" / "antigravity" / "brain"),
                "AGF_ANTIGRAVITY_HISTORY_ROOT": str(root / "Library" / "Application Support" / "Antigravity" / "User" / "History"),
                "AGF_CODEX_ROOT": str(root / ".codex"),
                "AGF_PROJECT_MCP_HUB": str(root / "Desktop" / "MCP_Hub"),
                "AGF_PROJECT_3_5": str(root / "Desktop" / "Project3.5"),
                "AGF_PROJECT_4": str(root / "Desktop" / "Project4"),
                "AGF_PROJECT_5": str(root / "Desktop" / "Project5"),
                "AGF_PROJECT_5_5": str(root / "Desktop" / "Project 5.5"),
                "AGF_PROJECT_DESIGN": str(root / "Desktop" / "Project Design"),
            }

            created = ensure_layout(values)

            self.assertTrue((root / ".gemini" / "GEMINI.md").exists())
            self.assertTrue((root / ".gemini" / "settings.json").exists())
            self.assertTrue((root / ".gemini" / "antigravity" / "mcp_config.json").exists())
            self.assertTrue((root / "Desktop" / "Project4" / ".agents").exists())
            self.assertIn(str((root / "global-agent-fabric").resolve()), created)

    def test_render_env_file_and_command(self) -> None:
        values = {
            "AGF_USER_HOME": "/tmp/home",
            "AGF_DESKTOP_ROOT": "/tmp/home/Desktop",
            "AGF_FRAMEWORK_SOURCE_ROOT": "/tmp/repo/fabric",
            "AGF_GLOBAL_ROOT": "/tmp/home/Antigravity_Skills/global-agent-fabric",
            "AGF_AWESOME_SKILLS_ROOT": "/tmp/home/Antigravity_Skills/awesome-skills",
            "AGF_GEMINI_ROOT": "/tmp/home/.gemini",
            "AGF_GEMINI_SETTINGS": "/tmp/home/.gemini/settings.json",
            "AGF_GEMINI_RULE": "/tmp/home/.gemini/GEMINI.md",
            "AGF_ANTIGRAVITY_MCP_CONFIG": "/tmp/home/.gemini/antigravity/mcp_config.json",
            "AGF_ANTIGRAVITY_BRAIN_ROOT": "/tmp/home/.gemini/antigravity/brain",
            "AGF_ANTIGRAVITY_HISTORY_ROOT": "/tmp/home/Library/Application Support/Antigravity/User/History",
            "AGF_CODEX_ROOT": "/tmp/home/.codex",
            "AGF_PROJECT_MCP_HUB": "/tmp/home/Desktop/MCP_Hub",
            "AGF_PROJECT_3_5": "/tmp/home/Desktop/Project3.5",
            "AGF_PROJECT_4": "/tmp/home/Desktop/Project4",
            "AGF_PROJECT_5": "/tmp/home/Desktop/Project5",
            "AGF_PROJECT_5_5": "/tmp/home/Desktop/Project 5.5",
            "AGF_PROJECT_DESIGN": "/tmp/home/Desktop/Project Design",
        }

        rendered = render_env_file(values)
        command = build_install_command(Path("/tmp/.env.local"), Path("/tmp/paths.yaml"), Path("/tmp/state.tgz"))

        self.assertIn('AGF_GLOBAL_ROOT="/tmp/home/Antigravity_Skills/global-agent-fabric"', rendered)
        self.assertEqual(command[-1], "/tmp/state.tgz")


if __name__ == "__main__":
    unittest.main()
