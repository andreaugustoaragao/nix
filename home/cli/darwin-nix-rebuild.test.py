"""Exercise Git detection, build/GUI-auth boundaries, and singleton locking; never activate."""

from datetime import datetime
import fcntl
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("darwin_nix_rebuild", ROOT / "darwin-nix-rebuild.py")
backend = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backend)

SYSTEM = "/nix/store/" + "0" * 32 + "-darwin-system-darwin-25.11"


class DarwinRebuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="darwin-nix-rebuild-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / "repo"
        self.repo.mkdir()
        self.config = {
            "repository": str(self.repo),
            "hostname": "mac-work",
            "git": "git",
            "nix": "nix",
            "activator": "/nix/store/" + "a" * 32 + "-darwin-nix-rebuild-activate/bin/darwin-nix-rebuild-activate",
            "osascript": "osascript",
            "launchctl": "launchctl",
        }
        self.runner = backend.DarwinRebuilder(
            self.config, self.base / "config.json", self.base / "state"
        )
        self.runner.current_system = self.base / "current-system"
        self.runner.current_system.symlink_to("/nix/store/previous-system")
        self.switches_system = True
        self.calls = []
        self.git_dirty = True
        self.aqua = True
        self.build_code = 0
        self.auth_code = 0
        self.auth_stderr = ""
        self.build_json = json.dumps([{"outputs": {"out": SYSTEM}}])

    def fake(self, name, *args, **kwargs):
        self.calls.append((name, args, kwargs))
        stdout, stderr, code = "", "", 0
        if name == "git":
            stdout = b" M tracked\0" if self.git_dirty else b""
        elif name == "launchctl":
            stdout = "Aqua\n" if self.aqua else "Background\n"
        elif name == "nix":
            stdout, code = self.build_json, self.build_code
        elif name == "osascript":
            # Distinguish admin elevation from desktop notifications.
            if any("administrator privileges" in str(a) for a in args):
                code, stderr = self.auth_code, self.auth_stderr
                if code == 0 and self.switches_system:
                    self.runner.current_system.unlink()
                    self.runner.current_system.symlink_to(SYSTEM)
        return subprocess.CompletedProcess([name, *args], code, stdout, stderr)

    def invoke(self):
        with patch.object(self.runner, "command", side_effect=self.fake):
            return self.runner.run()

    def test_real_git_staged_unstaged_untracked_and_ignored(self):
        def git(*args):
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(self.repo),
                    "-c",
                    "core.hooksPath=/dev/null",
                    "-c",
                    "commit.gpgsign=false",
                    *args,
                ],
                check=True,
                capture_output=True,
            )

        git("init", "-q")
        tracked = self.repo / "tracked"
        tracked.write_text("baseline")
        git("add", "tracked")
        self.assertTrue(self.runner.dirty())
        git(
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.invalid",
            "commit",
            "-qm",
            "baseline",
        )
        self.assertFalse(self.runner.dirty())
        tracked.write_text("changed")
        self.assertTrue(self.runner.dirty())
        git("checkout", "--", "tracked")
        (self.repo / "untracked").write_text("new")
        self.assertTrue(self.runner.dirty())
        self.assertEqual(
            subprocess.check_output(["git", "-C", str(self.repo), "diff", "--cached"]), b""
        )
        (self.repo / "untracked").unlink()
        (self.repo / ".git/info/exclude").write_text("ignored\n")
        (self.repo / "ignored").write_text("scratch")
        self.assertFalse(self.runner.dirty())

    def test_success_builds_before_gui_auth_and_applies_only_built_path(self):
        self.assertEqual(self.invoke(), 0)
        nix_idx = next(i for i, (n, _, _) in enumerate(self.calls) if n == "nix")
        elev_idx = next(
            i
            for i, (n, args, _) in enumerate(self.calls)
            if n == "osascript" and any("administrator privileges" in str(a) for a in args)
        )
        self.assertLess(nix_idx, elev_idx)
        nix_args = self.calls[nix_idx][1]
        self.assertIn("--no-write-lock-file", nix_args)
        self.assertEqual(nix_args[-1], f"{self.repo}#darwinConfigurations.mac-work.system")
        elev_args = self.calls[elev_idx][1]
        shell_cmd = elev_args[-2]
        self.assertIn(self.config["activator"], shell_cmd)
        self.assertIn(SYSTEM, shell_cmd)
        self.assertNotIn("--flake", shell_cmd)
        self.assertEqual(self.runner.read_state()["phase"], "done")
        self.assertEqual(self.runner.read_state()["system"], SYSTEM)

    def test_build_failure_or_invalid_output_never_authenticates(self):
        for code, output in (
            (1, self.build_json),
            (0, "malformed"),
            (0, "[]"),
            (0, json.dumps([{"outputs": {"out": "/tmp/unsafe"}}])),
            (0, json.dumps([{"outputs": {"out": "/nix/store/" + "0" * 32 + "-nixos-system-x"}}])),
        ):
            with self.subTest(code=code, output=output):
                self.calls = []
                self.build_code, self.build_json = code, output
                self.assertEqual(self.invoke(), 1)
                self.assertFalse(
                    any(
                        n == "osascript" and any("administrator privileges" in str(a) for a in args)
                        for n, args, _ in self.calls
                    )
                )
                self.assertEqual(self.runner.read_state()["phase"], "failed")

    def test_missing_aqua_session_never_authenticates(self):
        self.aqua = False
        self.assertEqual(self.invoke(), 1)
        self.assertFalse(
            any(
                n == "osascript" and any("administrator privileges" in str(a) for a in args)
                for n, args, _ in self.calls
            )
        )
        self.assertEqual(self.runner.read_state()["phase"], "failed")
        self.assertIn("Aqua", self.runner.read_state()["message"])

    def test_user_cancel_records_cancelled_and_returns_zero(self):
        self.auth_code = 1
        self.auth_stderr = "35:105: execution error: User canceled. (-128)\n"
        self.assertEqual(self.invoke(), 0)
        state = self.runner.read_state()
        self.assertEqual(state["phase"], "cancelled")
        self.assertEqual(state["system"], SYSTEM)

    def test_activation_failure_records_failed(self):
        self.auth_code = 1
        self.auth_stderr = "activation failed: boom\n"
        self.assertEqual(self.invoke(), 1)
        self.assertEqual(self.runner.read_state()["phase"], "failed")

    def test_zero_exit_without_selecting_built_system_is_partial_failure(self):
        self.switches_system = False
        self.assertEqual(self.invoke(), 1)
        state = self.runner.read_state()
        self.assertEqual(state["phase"], "failed")
        self.assertIn("partial", state["message"])

    def test_status_detects_interrupted_and_active_lock(self):
        self.runner.save("building", "Building...")
        with patch.object(self.runner, "dirty", return_value=True):
            status = self.runner.status()
            self.assertFalse(status["busy"])
            self.assertEqual(status["phase"], "interrupted")

            with self.runner.run_lock_file.open("a") as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                try:
                    busy_status = self.runner.status()
                    self.assertTrue(busy_status["busy"])
                    self.assertEqual(busy_status["phase"], "building")
                    start_res = self.runner.start()
                    self.assertEqual(start_res, {"started": False, "busy": True})
                finally:
                    fcntl.flock(held, fcntl.LOCK_UN)

    def test_start_refuses_clean_checkout(self):
        with patch.object(self.runner, "dirty", return_value=False):
            res = self.runner.start()
            self.assertEqual(res["started"], False)
            self.assertEqual(res["busy"], False)

    def test_timestamp_log_and_logged_run_preserve_json_stdout(self):
        buf = io.StringIO()
        fixed = datetime(2026, 11, 25, 11, 0, 0).astimezone()
        log = backend.TimestampLog(buf, now=lambda: fixed)
        result = backend.logged_run(
            [
                "python3",
                "-c",
                "import sys; sys.stdout.write('[{\"ok\":true}]'); sys.stderr.write('step 1\\nstep 2\\n')",
            ],
            log,
            capture_stdout=True,
            capture_stderr=True,
        )
        self.assertEqual(result.stdout, '[{"ok":true}]')
        self.assertEqual(result.stderr, "step 1\nstep 2\n")
        logged = buf.getvalue()
        self.assertIn("] step 1\n", logged)
        self.assertIn("] step 2\n", logged)
        self.assertNotIn('{"ok":true}', logged)


if __name__ == "__main__":
    unittest.main()
