"""Exercise Git detection, process boundaries and the real widget; never activate."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("nix_rebuild", ROOT / "noctalia-nix-rebuild.py")
backend = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backend)
LUAU = "luau"
SYSTEM = "/nix/store/" + "0" * 32 + "-nixos-system-test-host-26.05"


class RebuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="noctalia-nix-rebuild-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / "repo"
        self.repo.mkdir()
        self.config = {
            "repository": str(self.repo), "hostname": "test-host",
            **{name: name for name in (
                "git", "systemctl", "systemd_run", "nix", "pkexec", "rebuild", "notify", "zenity",
            )},
        }
        self.runner = backend.Rebuilder(self.config, self.base / "config.json", self.base / "state")
        self.calls = []
        self.active = False
        self.git_dirty = True
        self.build_code = 0
        self.auth_code = 0
        self.build_json = json.dumps([{"outputs": {"out": SYSTEM}}])

    def fake(self, name, *args, **kwargs):
        self.calls.append((name, args, kwargs))
        stdout, code = "", 0
        if name == "git":
            stdout = b" M tracked\0" if self.git_dirty else b""
        elif name == "systemctl":
            stdout = "active\n" if self.active else "inactive\n"
        elif name == "nix":
            stdout, code = self.build_json, self.build_code
        elif name == "pkexec":
            code = self.auth_code
        return subprocess.CompletedProcess([name, *args], code, stdout, "")

    def invoke(self):
        with patch.object(self.runner, "command", side_effect=self.fake):
            return self.runner.run()

    def test_real_git_staged_unstaged_untracked_and_ignored(self):
        def git(*args):
            subprocess.run(
                ["git", "-C", str(self.repo), "-c", "core.hooksPath=/dev/null",
                 "-c", "commit.gpgsign=false", *args],
                check=True, capture_output=True,
            )
        git("init", "-q")
        tracked = self.repo / "tracked"
        tracked.write_text("baseline")
        git("add", "tracked")
        self.assertTrue(self.runner.dirty(), "staged additions count")
        git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "baseline")
        self.assertFalse(self.runner.dirty())
        tracked.write_text("changed")
        self.assertTrue(self.runner.dirty(), "unstaged changes count")
        git("checkout", "--", "tracked")
        (self.repo / "untracked").write_text("new")
        self.assertTrue(self.runner.dirty(), "untracked files count without staging them")
        self.assertEqual(subprocess.check_output(["git", "-C", str(self.repo), "diff", "--cached"]), b"")
        (self.repo / "untracked").unlink()
        (self.repo / ".git/info/exclude").write_text("ignored\n")
        (self.repo / "ignored").write_text("scratch")
        self.assertFalse(self.runner.dirty(), "ignored files do not count")
        self.repo.rename(self.base / "moved")
        with self.assertRaises(ValueError):
            self.runner.dirty()

    def test_success_builds_before_gui_auth_and_applies_only_built_path(self):
        self.assertEqual(self.invoke(), 0)
        names = [name for name, _, _ in self.calls]
        self.assertLess(names.index("nix"), names.index("pkexec"))
        nix_args = next(args for name, args, _ in self.calls if name == "nix")
        self.assertIn("--no-write-lock-file", nix_args)
        self.assertEqual(nix_args[-1], str(self.repo) + "#nixosConfigurations.test-host.config.system.build.toplevel")
        auth_args = next(args for name, args, _ in self.calls if name == "pkexec")
        self.assertEqual(auth_args, (
            "--disable-internal-agent", "rebuild", "switch", "--store-path", SYSTEM, "--no-reexec",
        ))
        self.assertNotIn("--flake", auth_args, "root must not evaluate a changed checkout")
        self.assertEqual(self.runner.read_state()["phase"], "done")
        self.assertTrue(self.repo.exists(), "never commit, reset or remove the checkout")

    def test_build_failure_or_invalid_output_never_authenticates(self):
        for code, output in ((1, self.build_json), (0, "malformed"), (0, "[]"),
                             (0, json.dumps([{"outputs": {"out": "/tmp/unsafe"}}]))):
            with self.subTest(code=code, output=output):
                self.calls = []
                self.build_code, self.build_json = code, output
                self.assertEqual(self.invoke(), 1)
                self.assertNotIn("pkexec", [name for name, _, _ in self.calls])
                self.assertEqual(self.runner.read_state()["phase"], "failed")

    def test_store_path_validation(self):
        self.assertEqual(backend.Rebuilder.built_system(self.build_json, "test-host"), SYSTEM)
        for value in (None, "--option", SYSTEM + "/bin", SYSTEM.replace("test-host", "other-host")):
            with self.subTest(value=value), self.assertRaises(ValueError):
                backend.Rebuilder.built_system(json.dumps([{"outputs": {"out": value}}]), "test-host")
        with self.assertRaises(ValueError):
            backend.Rebuilder.built_system(json.dumps([{}, {}]), "test-host")

    def test_authentication_cancellation_failure_and_partial_activation(self):
        for code, expected, result in ((126, "cancelled", 0), (127, "failed", 1), (1, "failed", 1)):
            with self.subTest(code=code):
                self.auth_code = code
                self.assertEqual(self.invoke(), result)
                self.assertEqual(self.runner.read_state()["phase"], expected)
                if code == 1:
                    self.assertIn("partial", self.runner.read_state()["message"])

    def test_root_and_clean_checkout_do_not_build(self):
        with patch.object(backend.os, "geteuid", return_value=0), self.assertRaises(ValueError):
            self.invoke()
        self.assertEqual(self.calls, [])
        self.git_dirty = False
        self.assertEqual(self.invoke(), 0)
        self.assertNotIn("nix", [name for name, _, _ in self.calls])
        self.assertEqual(self.runner.read_state()["phase"], "idle")

    def test_start_uses_transient_singleton_without_authenticating(self):
        with patch.object(self.runner, "command", side_effect=self.fake):
            self.assertEqual(self.runner.start(), {"started": True, "busy": True})
        args = next(args for name, args, _ in self.calls if name == "systemd_run")
        self.assertIn("--unit=" + backend.UNIT, args)
        self.assertIn("--collect", args)
        self.assertEqual(args[-1], "run")
        self.assertNotIn("pkexec", [name for name, _, _ in self.calls])
        self.active = True
        self.calls = []
        with patch.object(self.runner, "command", side_effect=self.fake):
            self.assertEqual(self.runner.start(), {"started": False, "busy": True})
        self.assertEqual([name for name, _, _ in self.calls], ["systemctl"])
        self.active, self.git_dirty = False, False
        with patch.object(self.runner, "command", side_effect=self.fake):
            self.assertFalse(self.runner.start()["started"])

    def test_concurrent_launch_lock(self):
        with (self.runner.state_dir / "launch.lock").open("a") as lock:
            backend.fcntl.flock(lock, backend.fcntl.LOCK_EX | backend.fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                self.runner.start()

    def test_status_reconciles_stale_job_and_unknown_systemd(self):
        self.runner.save("building", "old job")
        with patch.object(self.runner, "command", side_effect=self.fake):
            state = self.runner.status()
        self.assertEqual(state["phase"], "interrupted")
        self.assertTrue(state["dirty"])
        self.assertFalse(state["busy"])
        self.active = True
        with patch.object(self.runner, "command", side_effect=self.fake):
            self.assertTrue(self.runner.status()["busy"])
        with patch.object(self.runner, "unit_active", side_effect=ValueError("user systemd unavailable")), \
             patch.object(self.runner, "dirty", return_value=True):
            state = self.runner.status()
        self.assertTrue(state["busy"])
        self.assertIn("unavailable", state["error"])
        with patch.object(self.runner, "unit_active", return_value=False), \
             patch.object(self.runner, "dirty", side_effect=ValueError("Git unavailable")):
            self.assertFalse(self.runner.status()["dirty"])

    def test_log_uses_gui_viewer(self):
        self.runner.log_file.write_text("test log")
        with patch.object(self.runner, "command", side_effect=self.fake):
            self.assertEqual(self.runner.show_log(), 0)
        self.assertEqual(self.calls[0][0], "zenity")
        self.assertIn("--filename=" + str(self.runner.log_file), self.calls[0][1])

    def test_widget_visibility_and_duplicate_clicks(self):
        host = r'''
local visible, text, color, tooltip
local data = {dirty = false, busy = false}
local failPoll, rejectLaunch = false, false
local starts, logs, errors = 0, 0, 0
local startCallback
barWidget = {
    setVisible = function(value) visible = value end,
    setGlyph = function(value) assert(value == "snowflake") end,
    setText = function(value) text = value end,
    setColor = function(value) color = value end,
    setGlyphColor = function(_) end,
    setTooltip = function(value) tooltip = value end,
}
noctalia = {
    setUpdateInterval = function(ms) assert(ms == 5000) end,
    json = { decode = function(_) if failPoll then error("malformed") end; return data end },
    notifyError = function(_, _) errors = errors + 1 end,
    runAsync = function(argv, callback)
        assert(argv[1] == "noctalia-nix-rebuild" and #argv == 2)
        if argv[2] == "status" then
            callback({exitCode = 0, stdout = "fixture"})
        elseif argv[2] == "start" then
            starts = starts + 1
            if rejectLaunch then return false end
            startCallback = callback
        elseif argv[2] == "log" then
            assert(callback == nil, "log viewer must outlive the widget")
            logs = logs + 1
        else error("unexpected command") end
        return true
    end,
}
'''
        assertions = r'''
assert(not visible, "clean checkout hides the entire capsule")
onClick(); assert(starts == 0)
data = {dirty = true, busy = false}; update()
assert(visible and text == "Rebuild")
assert(string.find(tooltip, "does not stage or commit", 1, true))
onClick(); onClick(); assert(starts == 1, "rapid clicks must not duplicate the job")
data = {dirty = true, busy = true, phase = "building"}; startCallback({exitCode = 0})
assert(visible and text == "Building")
onClick(); assert(starts == 1, "a running job cannot be started again")
data.phase = "applying"; update(); assert(text == "Applying")
data = {dirty = true, busy = false, phase = "done"}; update()
assert(visible, "successful rebuild does not clean Git")
onRightClick(); assert(logs == 1)
data = {dirty = false, busy = true}; update()
assert(not visible, "visibility follows Git even if a job is running")
failPoll = true; update(); assert(not visible)
failPoll = false; data = {dirty = true, busy = true, error = "unavailable"}; update()
onClick(); assert(starts == 1)
data = {dirty = true, busy = false}; update(); rejectLaunch = true
onClick(); assert(starts == 2 and errors == 1 and color == "error")
print("Rebuild widget passed: dirty visibility, lifecycle, errors, logs and duplicate clicks.")
'''
        script = self.base / "widget.test.luau"
        plugin = ROOT / "noctalia-plugins/nix-rebuild/rebuild.luau"
        script.write_text(host + plugin.read_text() + assertions)
        subprocess.run([LUAU, str(script)], check=True)


if __name__ == "__main__":
    if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
        LUAU = sys.argv.pop(1)
    unittest.main()
