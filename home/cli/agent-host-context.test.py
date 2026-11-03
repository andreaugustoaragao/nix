"""Check fresh terminal evidence, including nested hosts and missing commands."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("agent-host-context.py")


class ContextTests(unittest.TestCase):
    def run_context(self, environment):
        result = subprocess.run(
            [sys.executable, str(SCRIPT)],
            env={"PATH": "", **environment},
            check=True, capture_output=True, text=True, timeout=5,
        )
        return json.loads(result.stdout)

    def test_environment_is_fresh_and_preserves_partial_and_overlapping_hosts(self):
        tui = {"HERDR_ENV": "1", "HERDR_PANE_ID": "w1:p1",
               "HERDR_SOCKET_PATH": "/missing/tui.sock"}
        core = {"HC_TERMINAL_ID": "t8", "HC_TERMINAL_SOCKET": "/missing/core.sock"}
        orca = {"ORCA_PANE_KEY": "pane-1", "ORCA_TAB_ID": "tab-1",
                "ORCA_CLI_COMMAND": "/opt/Orca/bin/orca"}
        structured = {"ORCA_STRUCTURED_SESSION": "1", "ORCA_AGENT_SESSION_ID": "agent-1"}
        for environment in ({}, tui, core, orca, structured, {"HC_TERMINAL_ID": "t9"},
                            {"HERDR_ENV": "0"}, {"HC_TERMINAL_ID": ""},
                            {**tui, **core, **orca}):
            with self.subTest(environment=environment):
                result = self.run_context({**environment, "API_KEY": "do-not-report",
                                           "TERM_PROGRAM": "ghostty",
                                           "ORCA_AGENT_HOOK_TOKEN": "do-not-report",
                                           "ORCA_ENVIRONMENT": "remote-target"})
                self.assertEqual(result["environment"], environment)
                self.assertTrue(all(path is None for path in result["commands"].values()))

    def test_command_presence_does_not_claim_a_host_or_execute_the_command(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "hc"
            executable.write_text("#!/bin/sh\nexit 99\n")
            executable.chmod(0o755)
            result = self.run_context({"PATH": directory})
            self.assertEqual(result["environment"], {})
            self.assertEqual(result["commands"]["hc"], str(executable))
            self.assertIsNone(result["commands"]["herdr"])

    def test_current_shell_markers_are_preserved(self):
        result = self.run_context(os.environ)
        for key in ("HC_TERMINAL_ID", "HC_TERMINAL_SOCKET", "HERDR_PANE_ID"):
            if key in os.environ:
                self.assertEqual(result["environment"][key], os.environ[key])


if __name__ == "__main__":
    unittest.main()
