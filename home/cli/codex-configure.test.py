"""Check Codex activation preserves Orca/runtime additions and rejects bad TOML."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

import tomlkit


spec = importlib.util.spec_from_file_location("configure", Path(__file__).with_name("codex-configure.py"))
configure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configure)


class ConfigureTests(unittest.TestCase):
    def test_preserves_runtime_settings_and_updates_nix_owned_leaves(self):
        with tempfile.TemporaryDirectory() as directory:
            existing = Path(directory) / "config.toml"
            desired = Path(directory) / "new.toml"
            existing.write_text('''# User preference
personality = "pragmatic"
model = "old"
[projects."/work/orca-child"]
trust_level = "trusted"
[mcp_servers.user_added]
command = "user-mcp"
[mcp_servers.nix_managed]
command = "/nix/store/old/bin/mcp"
startup_timeout_sec = 45
[hooks.trust]
orca_digest = "approved"
''')
            template = '''model = "new"
[mcp_servers.nix_managed]
command = "/nix/store/new/bin/mcp"
'''
            for _ in range(2):
                desired.write_text(template)
                configure.configure(existing, desired)
                parsed = tomlkit.parse(desired.read_text())
                self.assertEqual(parsed["model"], "new")
                self.assertEqual(parsed["personality"], "pragmatic")
                self.assertEqual(parsed["projects"]["/work/orca-child"]["trust_level"], "trusted")
                self.assertEqual(parsed["hooks"]["trust"]["orca_digest"], "approved")
                self.assertEqual(parsed["mcp_servers"]["user_added"]["command"], "user-mcp")
                self.assertEqual(parsed["mcp_servers"]["nix_managed"], {
                    "command": "/nix/store/new/bin/mcp", "startup_timeout_sec": 45,
                })
                self.assertIn("# User preference", desired.read_text())
                existing.write_text(desired.read_text())

    def test_invalid_existing_file_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            existing = Path(directory) / "config.toml"
            desired = Path(directory) / "new.toml"
            existing.write_text("invalid = [")
            desired.write_text('model = "new"\n')
            with self.assertRaises(tomlkit.exceptions.ParseError):
                configure.configure(existing, desired)
            self.assertEqual(existing.read_text(), "invalid = [")
            self.assertEqual(desired.read_text(), 'model = "new"\n')

    def test_first_activation_creates_config_from_template(self):
        with tempfile.TemporaryDirectory() as directory:
            desired = Path(directory) / "new.toml"
            desired.write_text('model = "new"\n')
            configure.configure(Path(directory) / "missing.toml", desired)
            self.assertEqual(tomlkit.parse(desired.read_text())["model"], "new")


if __name__ == "__main__":
    unittest.main()
