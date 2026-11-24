"""Exercise the login wrapper without touching the real desktop or user bus."""

import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest


class NiriSessionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.log = self.root / "events"
        stub = self.root / "stub"
        stub.write_text(f"#!{sys.executable}\n" + """
import json, os, signal, sys
from pathlib import Path
root = Path(os.environ['TEST_ROOT'])
with (root / 'events').open('a') as log:
    log.write(json.dumps([Path(sys.argv[0]).name, *sys.argv[1:]]) + '\\n')
if Path(sys.argv[0]).name == 'niri':
    if sys.argv[1:3] == ['msg', 'version']:
        live = os.environ.get('LIVE_NIRI_SOCKET', '')
        sys.exit(0 if live and os.environ.get('NIRI_SOCKET') == live else 1)
    (root / 'desktop.json').write_text(json.dumps({key: os.environ.get(key) for key in
        ('XDG_CURRENT_DESKTOP', 'XDG_SESSION_DESKTOP', 'XDG_SESSION_TYPE')}))
    if os.environ.get('WAIT_FOR_SIGNAL'):
        def stop(*args):
            (root / 'terminated').touch()
            sys.exit(0)
        signal.signal(signal.SIGTERM, stop)
        (root / 'ready').touch()
        signal.pause()
    sys.exit(int(os.environ.get('COMPOSITOR_EXIT', '0')))
""")
        stub.chmod(0o755)
        for name in ("niri", "systemctl"):
            (self.root / name).symlink_to(stub)
        self.runtime = self.root / "runtime"
        self.runtime.mkdir()
        self.env = {
            k: v
            for k, v in os.environ.items()
            if k not in ("NIRI_SOCKET", "LIVE_NIRI_SOCKET")
        } | {
            "TEST_ROOT": str(self.root),
            "XDG_RUNTIME_DIR": str(self.runtime),
            "NIRI_BIN": str(self.root / "niri"),
            "SYSTEMCTL_BIN": str(self.root / "systemctl"),
        }

    def launch(self, **env):
        process = subprocess.Popen(
            ["bash", str(Path(__file__).with_name("niri-session.sh"))],
            env=self.env | env,
        )
        self.addCleanup(lambda: process.poll() is None and process.kill())
        return process

    def assert_cleanup(self):
        events = [json.loads(line) for line in self.log.read_text().splitlines()]
        shutdown = ["systemctl", "--user", "start", "--job-mode=replace-irreversibly", "niri-shutdown.target"]
        self.assertEqual(events[0], shutdown, "clear the previous session before launching")
        self.assertEqual(events[1], ["niri", "--session"])
        self.assertEqual(events[2], shutdown, "logout must stop graphical services")
        self.assertEqual(events[3], [
            "systemctl", "--user", "unset-environment", "WAYLAND_DISPLAY", "DISPLAY",
            "XDG_SESSION_TYPE", "XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP", "NIRI_SOCKET", "HYPRLAND_INSTANCE_SIGNATURE",
        ])

    def test_logout_stops_services_and_clears_display(self):
        self.assertEqual(self.launch().wait(timeout=5), 0)
        self.assert_cleanup()

    def test_compositor_failure_still_cleans_up_and_preserves_status(self):
        self.assertEqual(self.launch(COMPOSITOR_EXIT="23").wait(timeout=5), 23)
        self.assert_cleanup()

    def test_niri_replaces_inherited_hyprland_identity(self):
        self.assertEqual(self.launch(
            XDG_CURRENT_DESKTOP="Hyprland", XDG_SESSION_DESKTOP="hyprland",
            XDG_SESSION_TYPE="tty",
        ).wait(timeout=5), 0)
        self.assertEqual(json.loads((self.root / "desktop.json").read_text()), {
            "XDG_CURRENT_DESKTOP": "niri", "XDG_SESSION_DESKTOP": "niri",
            "XDG_SESSION_TYPE": "wayland",
        })

    def test_termination_reaps_compositor_before_cleanup(self):
        process = self.launch(WAIT_FOR_SIGNAL="1")
        deadline = time.monotonic() + 5
        while not (self.root / "ready").exists():
            self.assertIsNone(process.poll())
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)
        process.send_signal(signal.SIGTERM)
        self.assertEqual(process.wait(timeout=5), 143)
        self.assertTrue((self.root / "terminated").exists())
        self.assert_cleanup()

    def _make_socket(self, name: str) -> Path:
        sock_path = self.runtime / name
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(str(sock_path))
        self.addCleanup(srv.close)
        return sock_path

    def test_duplicate_session_rejected_without_systemd_mutations(self):
        sock_path = self._make_socket("niri.wayland-1.1234.sock")
        proc = subprocess.run(
            ["bash", str(Path(__file__).with_name("niri-session.sh"))],
            env=self.env | {"LIVE_NIRI_SOCKET": str(sock_path)},
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("refusing to start", proc.stderr)
        events = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(events, [["niri", "msg", "version"]])

    def test_stale_niri_socket_does_not_block_login(self):
        self._make_socket("niri.wayland-1.9999.sock")
        self.assertEqual(self.launch().wait(timeout=5), 0)
        events = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(events[0], ["niri", "msg", "version"])
        shutdown = ["systemctl", "--user", "start", "--job-mode=replace-irreversibly", "niri-shutdown.target"]
        self.assertEqual(events[1], shutdown)
        self.assertEqual(events[2], ["niri", "--session"])
        self.assertEqual(events[3], shutdown)


if __name__ == "__main__":
    unittest.main()
