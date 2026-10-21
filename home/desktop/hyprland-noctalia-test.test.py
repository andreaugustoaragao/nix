import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SOURCE = Path(__file__).with_name("hyprland-noctalia-test.sh")
MOCK = r'''
import json
import os
from pathlib import Path
import sys

command = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["TEST_LOG"], "a") as log:
    log.write(json.dumps([command, *args]) + "\n")
if command == "tty":
    print(os.environ.get("TEST_TTY", "/dev/tty3"))
elif command == "systemctl" and args == ["is-active", "--quiet", "greetd.service"]:
    sys.exit(int(os.environ.get("TEST_GREETD_INACTIVE", "0")))
elif command == "sudo" and args == ["-v"]:
    sys.exit(int(os.environ.get("TEST_SUDO_STATUS", "0")))
elif command == "uwsm":
    assert not any(name in os.environ for name in (
        "WAYLAND_DISPLAY", "DISPLAY", "NIRI_SOCKET", "HYPRLAND_INSTANCE_SIGNATURE"
    ))
    sys.exit(int(os.environ.get("TEST_SESSION_STATUS", "0")))
'''


class SessionLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.log = self.root / "commands.jsonl"
        for name in ("tty", "systemctl", "sudo", "uwsm"):
            executable = self.root / name
            executable.write_text(f"#!{sys.executable}\n{MOCK}")
            executable.chmod(0o755)
        self.env = os.environ.copy()
        for name in ("DISPLAY", "WAYLAND_DISPLAY"):
            self.env.pop(name, None)
        self.env.update(
            PATH=f"{self.root}:{os.environ['PATH']}",
            TEST_LOG=str(self.log),
            NIRI_SOCKET="stale-niri-socket",
            HYPRLAND_INSTANCE_SIGNATURE="stale-hyprland-signature",
        )

    def run_session(self, *args, **env):
        result = subprocess.run(
            [
                shutil.which("bash"), "-euo", "pipefail", "-c",
                'hyprland_noctalia_config=/test/config; '
                'hyprland_noctalia_compositor=/test/start-hyprland; '
                'source_file=$1; shift; source "$source_file"',
                "test-session", str(SOURCE), *args,
            ],
            env=self.env | env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        commands = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, commands

    def test_help_does_not_touch_the_session(self):
        result, commands = self.run_session("--help", WAYLAND_DISPLAY="wayland-1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("stops the current graphical session", result.stdout)
        self.assertEqual(commands, [])

    def test_refuses_to_run_inside_a_desktop(self):
        result, commands = self.run_session(WAYLAND_DISPLAY="wayland-1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("text console", result.stderr)
        self.assertEqual(commands, [])

    def test_refuses_a_terminal_or_ssh(self):
        result, commands = self.run_session(TEST_TTY="/dev/pts/2")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(commands, [["tty"]])

    def test_unknown_arguments_do_not_touch_the_session(self):
        result, commands = self.run_session("--unknown")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(commands, [])

    def test_runs_the_test_then_restores_the_default(self):
        result, commands = self.run_session()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(commands, [
            ["tty"],
            ["systemctl", "is-active", "--quiet", "greetd.service"],
            ["sudo", "-v"],
            ["sudo", "systemctl", "stop", "greetd.service"],
            ["systemctl", "--user", "stop", "graphical-session.target"],
            ["systemctl", "--user", "unset-environment", "WAYLAND_DISPLAY", "DISPLAY",
             "NIRI_SOCKET", "HYPRLAND_INSTANCE_SIGNATURE"],
            ["uwsm", "start", "-e", "-D", "Hyprland:NoctaliaTest", "/test/start-hyprland",
             "--", "--config", "/test/config"],
            ["systemctl", "--user", "stop", "graphical-session.target"],
            ["sudo", "systemctl", "start", "greetd.service"],
        ])

    def test_failed_session_still_restores_the_default(self):
        result, commands = self.run_session(TEST_SESSION_STATUS="42")
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(commands[-1], ["sudo", "systemctl", "start", "greetd.service"])

    def test_does_not_start_an_initially_inactive_login_service(self):
        result, commands = self.run_session(TEST_GREETD_INACTIVE="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(command[0] == "sudo" for command in commands))
        self.assertTrue(any(command[0] == "uwsm" for command in commands))

    def test_failed_sudo_authentication_leaves_the_desktop_running(self):
        result, commands = self.run_session(TEST_SUDO_STATUS="1")
        self.assertEqual(result.returncode, 1)
        self.assertFalse(any("stop" in command for command in commands))
        self.assertFalse(any(command[0] == "uwsm" for command in commands))


if __name__ == "__main__":
    unittest.main()
