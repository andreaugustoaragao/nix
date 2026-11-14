"""Exercise registration preservation, retries, and the pinned session hooks."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest

spec = importlib.util.spec_from_file_location("configure", Path(__file__).with_name("herdr-configure.py"))
configure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configure)


class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="herdr-check-")
        self.addCleanup(self.directory.cleanup)
        self.home = Path(self.directory.name)
        self.config = self.home / ".config"
        self.state = self.home / ".local/state"

    def reconcile(self):
        configure.configure(self.home, self.config, self.state)

    def test_preserves_other_handlers_and_removes_legacy_herdr_hooks(self):
        path = self.home / ".codex/hooks.json"
        script = self.home / ".codex/herdr-agent-state.sh"
        other = {"type": "command", "command": "pi-rs hook claude"}
        configure.write(path, {"description": "keep", "hooks": {
            "PreToolUse": [{"matcher": "Bash", "hooks": [
                other, {"type": "command", "command": f"bash '{script}' working"},
            ]}],
        }})
        self.reconcile()
        result = configure.load(path)
        self.assertEqual(result["description"], "keep")
        self.assertEqual(result["hooks"]["PreToolUse"], [{"matcher": "Bash", "hooks": [other]}])
        self.assertEqual(len(result["hooks"]["SessionStart"]), 1)

    def test_repeated_activation_keeps_files_and_preferences(self):
        cli = self.config / "opencode/cli.json"
        configure.write(cli, {"theme": "catppuccin", "plugins": ["another-plugin"]})
        tui = self.config / "opencode/tui.jsonc"
        tui.write_text('// Preserve preferences, accepting JSONC.\n{"keybinds": {"leader": "ctrl+a"},}\n')
        self.reconcile()
        paths = [self.home / ".codex/hooks.json", cli, tui]
        before = [(path.read_bytes(), path.stat().st_mtime_ns) for path in paths]
        self.reconcile()
        self.assertEqual(before, [(path.read_bytes(), path.stat().st_mtime_ns) for path in paths])
        self.assertEqual(configure.load(cli)["plugins"], ["another-plugin", "./herdr-opencode"])
        self.assertEqual(configure.load(cli)["theme"], "catppuccin")
        self.assertEqual(configure.load(tui)["keybinds"], {"leader": "ctrl+a"})

    def test_existing_plugin_options_are_preserved(self):
        config = {"plugins": [["./herdr-opencode", {"custom": True}]]}
        self.assertEqual(configure.plugin_config(config, "plugins", "./herdr-opencode"), config)

    def test_retirement_preserves_desktop_and_agent_hub_integrations(self):
        codex = self.home / ".codex/hooks.json"
        script = self.home / ".codex/herdr-agent-state.sh"
        desktop = {"type": "command", "command": "hc report"}
        hub = {"type": "command", "command": "agent-hub observe"}
        configure.write(codex, {"hooks": {"SessionStart": [{"matcher": "keep", "hooks": [
            desktop, hub,
            {"command": f"bash {script} session"},
            {"command": ": orca-agent-hook-form=1; exit 0"},
        ]}]}})
        cli = self.config / "opencode/cli.json"
        desktop_plugin = "/home/test/.config/herdr-app/integrations/opencode"
        configure.write(cli, {"theme": "keep", "plugins": [
            "./herdr-opencode", ["./herdr-tui-session.js", {}], desktop_plugin,
        ]})
        extension = self.home / ".pi/agent/extensions/orca-prefill.ts"
        extension.parent.mkdir(parents=True)
        extension.write_text("legacy extension")
        configure.retire(self.home, self.config, self.state)
        self.assertEqual(configure.load(codex)["hooks"]["SessionStart"], [
            {"matcher": "keep", "hooks": [desktop, hub]},
        ])
        self.assertEqual(configure.load(cli), {"theme": "keep", "plugins": [desktop_plugin]})
        self.assertFalse(extension.exists())
        backups = list((self.state / "retired-ai-tools/pi-extensions").iterdir())
        self.assertEqual([p.read_text() for p in backups], ["legacy extension"])
        before = [p.read_bytes() for p in (codex, cli)]
        configure.retire(self.home, self.config, self.state)
        self.assertEqual(before, [p.read_bytes() for p in (codex, cli)])

    def test_retirement_does_not_create_missing_agent_configs(self):
        configure.retire(self.home, self.config, self.state)
        self.assertEqual(list(self.home.iterdir()), [])

    def test_migration_is_deferred_then_converges(self):
        legacy = self.config / "opencode/tui.json"
        configure.write(legacy, {"theme": "personal"})
        self.reconcile()
        cli = self.config / "opencode/cli.json"
        self.assertFalse(cli.exists())
        # Simulate the agent completing its native V1 preference migration.
        configure.write(cli, {"theme": "personal"})
        self.reconcile()
        self.assertEqual(configure.load(cli), {"theme": "personal", "plugins": ["./herdr-opencode"]})

    def test_invalid_config_is_not_overwritten(self):
        path = self.home / ".codex/hooks.json"
        path.parent.mkdir()
        path.write_text('{"hooks": ["invalid"]}')
        with self.assertRaisesRegex(ValueError, "must be an object"):
            self.reconcile()
        self.assertEqual(path.read_text(), '{"hooks": ["invalid"]}')

    def test_opencode_tui_loads_through_home_manager_symlinks(self):
        assets = ASSETS / "opencode"
        entrypoint, = assets.rglob("tui.js")
        plugin = self.config / "opencode/herdr-opencode/tui.js"
        plugin.parent.mkdir(parents=True)
        plugin.symlink_to(entrypoint)
        helper = plugin.parent.parent / "herdr-tui-session.js"
        helper.symlink_to(assets / "herdr-tui-session.js")
        subprocess.run([
            "node", "--input-type=module", "-e",
            'import assert from "node:assert/strict";'
            f'const {{ default: plugin }} = await import({json.dumps(plugin.as_uri())});'
            'assert.equal(plugin.id, "herdr.opencode.session-selection");'
            'assert.equal(typeof plugin.setup, "function");',
        ], check=True, timeout=5)

    def test_session_hooks_report_to_the_pane_socket(self):
        for agent in ("claude", "codex", "cursor", "grok"):
            with self.subTest(agent=agent), socket.socket(socket.AF_UNIX) as server:
                address = self.home / f"{agent}.sock"
                server.bind(str(address))
                server.listen(1)
                server.settimeout(3)
                received = []

                def receive():
                    client, _ = server.accept()
                    with client, client.makefile("rb") as stream:
                        received.append(json.loads(stream.readline()))
                        client.sendall(b'{"ok":true}\n')

                thread = threading.Thread(target=receive)
                thread.start()
                payload = {"hook_event_name": "SessionStart", "session_id": "synthetic-session",
                           "transcript_path": str(self.home / "transcript.jsonl"),
                           "source": "startup"}
                if agent == "cursor":
                    payload["hook_event_name"] = "sessionStart"
                    payload["conversation_id"] = payload["session_id"]
                if agent == "grok":
                    payload["source"] = "new"
                environment = {**os.environ, "HERDR_ENV": "1", "HERDR_SOCKET_PATH": str(address),
                               "HERDR_PANE_ID": "w1:p1"}
                # A parent's Codex thread identity is not part of this fixture.
                environment.pop("CODEX_THREAD_ID", None)
                environment.pop("GROK_SESSION_ID", None)
                subprocess.run(["bash", str(ASSETS / agent / "herdr-agent-state.sh"), "session"],
                               input=json.dumps(payload), text=True, env=environment,
                               check=True, timeout=5)
                thread.join(timeout=4)
                self.assertFalse(thread.is_alive())
                self.assertEqual(len(received), 1)
                report = received[0]
                self.assertEqual(report["method"], "pane.report_agent_session")
                self.assertEqual(report["params"]["pane_id"], "w1:p1")
                self.assertEqual(report["params"]["agent"], agent)
                self.assertEqual(report["params"]["agent_session_id"], "synthetic-session")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--assets", type=Path, required=True)
    arguments, remaining = parser.parse_known_args()
    ASSETS = arguments.assets
    unittest.main(argv=[__file__, *remaining])
