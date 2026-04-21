import unittest

from install.render_framework_config import render_memory_routes, render_runtime_map


class RenderRuntimeMapTests(unittest.TestCase):
    def test_render_runtime_map_includes_first_class_gemini_and_bridge_launchers(self) -> None:
        values = {
            "AGF_GLOBAL_ROOT": "/tmp/global-agent-fabric",
            "AGF_AWESOME_SKILLS_ROOT": "/tmp/awesome-skills",
            "AGF_GEMINI_RULE": "/tmp/.gemini/GEMINI.md",
            "AGF_GEMINI_SETTINGS": "/tmp/.gemini/settings.json",
            "AGF_ANTIGRAVITY_MCP_CONFIG": "/tmp/.gemini/antigravity/mcp_config.json",
            "AGF_CODEX_CLI": "codex",
            "AGF_GEMINI_CLI": "gemini",
        }

        rendered = render_runtime_map(values)

        self.assertIn("  gemini:", rendered)
        self.assertIn('    bridge_context_entrypoint: "AGENTS.md"', rendered)
        self.assertNotIn("bridge_launcher_command", rendered)
        self.assertNotIn('    bridge_mode: "handoff"', rendered)

    def test_render_memory_routes_uses_machine_specific_paths(self) -> None:
        values = {
            "AGF_GLOBAL_ROOT": "/tmp/global-agent-fabric",
            "AGF_AWESOME_SKILLS_ROOT": "/tmp/awesome-skills",
        }

        rendered = render_memory_routes(values)

        self.assertIn('/tmp/awesome-skills/skills/cc-skill-continuous-learning', rendered)
        self.assertIn('/tmp/global-agent-fabric/mcp/servers.yaml#mempalace', rendered)


if __name__ == "__main__":
    unittest.main()
