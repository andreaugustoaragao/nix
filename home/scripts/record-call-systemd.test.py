"""Explicit synthetic systemd integration test; no capture devices or live pactl.

Run separately from sandboxed Nix checks. The only units started/stopped by this
fixture run generated PCM and fixture module operations. It retains READY intake
artifacts under a private evidence directory for the Fulcrum consumer test.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("recorder_tests", Path(__file__).with_name("record-call-session.test.py"))
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
recorder = fixtures.recorder


class SystemdTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cache = Path.home() / ".cache"
        cls.evidence = Path(tempfile.mkdtemp(prefix="record-call-synthetic-", dir=cache))
        cls.evidence.chmod(0o700)

    def setUp(self):
        self.fixture = fixtures.RecorderTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        template = self.fixture.session()
        self.fixture.synthetic_capture(template)
        self.config = {**template.config, "systemdRun": shutil.which("systemd-run"),
                       "systemctl": shutil.which("systemctl"), "defaultWhisperServerUrl": "http://synthetic.invalid"}
        # Keep recorder state/legacy checks isolated while connecting these
        # two fixture commands to the real user manager's private socket.
        for name in ("systemdRun", "systemctl"):
            executable = self.config[name]
            bridge = self.fixture.root / ("fixture-" + name)
            bridge.write_text(f"#!{sys.executable}\nimport os, sys\nos.execve({executable!r}, "
                              f"[{executable!r}, *sys.argv[1:]], {{**os.environ, "
                              f"'XDG_RUNTIME_DIR': {os.environ['XDG_RUNTIME_DIR']!r}}})\n")
            bridge.chmod(0o700)
            self.config[name] = str(bridge)
        config = self.fixture.root / "config with % and $quote.json"
        config.write_text(json.dumps(self.config))
        self.config_path = config
        self.environment = {**os.environ, "XDG_STATE_HOME": str(self.fixture.root / "state"),
                            "XDG_RUNTIME_DIR": str(self.fixture.root / "runtime"), "TZ": "UTC",
                            "RECORD_CALL_FRAGMENT_SEC": "1", "RECORD_CALL_ADVANCE_SEC": "30",
                            "RECORD_CALL_WINDOW_SEC": "45", "WHISPER_SERVER_URL": "http://synthetic.invalid"}
        self.directories = []
        self.addCleanup(self.stop_test_units)
        self.start_public(self.fixture.root / "public capture % $quote")

    def stop_test_units(self):
        for directory in self.directories:
            state = recorder.read_json(directory / ".record-call/state.json")
            subprocess.run([self.config["systemctl"], "--user", "stop", state["unit"]],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)

    def command(self, *arguments, expected=0):
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("record-call-session.py")),
                                 "--config", str(self.config_path), *map(str, arguments)],
                                env=self.environment, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def start_public(self, directory):
        self.command("start", directory)
        self.directories.append(directory)
        self.session = recorder.Session(directory, self.config)
        self.await_status({"recording"})
        self.session = recorder.Session(directory, self.config)
        status = json.loads(self.command("status", "--json").stdout)
        self.assertEqual(status["status"], "recording")
        self.assertEqual(status["recordingId"], self.session.manifest["recordingId"])

    def stop_public(self):
        state = recorder.read_json(self.session.private / "state.json")
        self.command("stop")
        request = recorder.read_json(self.session.private / "stop.json")
        self.assertEqual(request, {"invocationId": state["invocationId"]})
        return state

    def await_status(self, expected):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            manifest = recorder.read_json(self.session.directory / "recording.json")
            if manifest["status"] in expected:
                return manifest
            time.sleep(0.1)
        self.fail(f"Expected {expected}; observed {manifest['status']}, {manifest.get('failure')}")

    def await_stopped(self):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            properties = recorder.owner_properties(self.session.state, self.session.config)
            if properties.get("ActiveState") not in ("active", "activating", "deactivating"):
                return
            time.sleep(0.1)
        self.fail("Synthetic unit did not exit")

    def assert_unrelated_modules(self):
        modules = json.loads((self.fixture.root / "modules.json").read_text())
        self.assertEqual([item["index"] for item in modules], [11, 12])

    def test_ready_contract_and_argument_quoting(self):
        blocked_directory = self.fixture.root / "must not start concurrently"
        result = self.command("start", blocked_directory, expected=1)
        self.assertEqual(json.loads(result.stderr)["failure"]["code"], "recording_already_active")
        self.assertFalse(blocked_directory.exists())
        result = self.command("retry", self.session.directory, expected=1)
        self.assertEqual(json.loads(result.stderr)["failure"]["code"], "recording_busy")
        result = self.command("retry-diarization", self.session.directory, expected=1)
        self.assertEqual(json.loads(result.stderr)["failure"]["code"], "recording_busy")
        with recorder.locked(self.fixture.root / "state/record-call/command.lock"):
            for arguments in (
                    ("start", blocked_directory), ("stop",), ("retry", self.session.directory),
                    ("retry-diarization", self.session.directory)):
                result = self.command(*arguments, expected=1)
                self.assertEqual(json.loads(result.stderr)["failure"]["code"], "recording_busy")
        self.assertFalse((self.session.private / "stop.json").exists())
        time.sleep(0.8)
        state = self.stop_public()
        manifest = self.await_status({"ready", "incomplete"})
        self.assertEqual(manifest["status"], "ready", manifest.get("failure"))
        self.await_stopped()
        self.assert_unrelated_modules()
        cleaned = recorder.read_json(self.session.private / "state.json")
        self.assertEqual(cleaned["cleanupCompletedInvocationId"], state["invocationId"])
        journal = subprocess.run([shutil.which("journalctl"), "--user", "--unit=" + state["unit"],
                                  "--output=cat", "--no-pager"], capture_output=True, text=True, check=True)
        events = [json.loads(line) for line in journal.stdout.splitlines() if line.startswith('{"event":')]
        self.assertEqual([(event["provider"], event["side"], event["code"]) for event in events], [
            ("remote", "call", "ok"), ("remote", "mic", "ok")])
        self.assertTrue(all(event["durationMs"] >= 0 for event in events))
        self.assertNotIn(str(self.fixture.root), json.dumps(events))
        status = json.loads(self.command("status", "--json").stdout)
        self.assertEqual(status["status"], "ready")
        transcript = (self.session.directory / "transcript.raw.txt").read_text()
        self.assertEqual(transcript.count("call window 000000"), 1)
        self.assertEqual(transcript.count("mic window 000000"), 1)
        self.assertEqual(len(list((self.session.private / "windows").glob("*/done.json"))), 1)
        before = self.snapshot(self.session.directory)
        self.command("retry", self.session.directory)
        self.command("stop", expected=1)
        self.assertEqual(self.snapshot(self.session.directory), before)
        target = self.evidence / "ready" / manifest["recordingId"]
        target.mkdir(parents=True)
        for name in ("recording.json", "transcript.turns.txt", "transcript.raw.txt"):
            shutil.copy2(self.session.directory / name, target / name)
        self.assertEqual(recorder.file_hash(target / "transcript.turns.txt"), manifest["source"]["transcript"]["sha256"])
        print(json.dumps({"result": "PASS", "readyDirectory": str(target),
                          "durationMs": manifest["coverage"]["durationMs"], "unit": state["unit"]}))

    def test_owner_crash_cleans_owned_group_and_modules(self):
        unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        try:
            time.sleep(0.3)
            subprocess.run([self.session.config["systemctl"], "--user", "kill", "--kill-whom=main",
                            "--signal=SIGKILL", self.session.state["unit"]], check=True)
            self.await_stopped()
            manifest = self.await_status({"incomplete"})
            self.assertEqual(manifest["failure"]["code"], "recording_owner_lost")
            self.assertIsNone(manifest["endedAt"])
            self.assertIsNone(unrelated.poll())
            self.assert_unrelated_modules()
            recorder.atomic_json(self.evidence / "owner-crash.json", manifest)
        finally:
            unrelated.terminate()
            unrelated.wait()

    def test_retry_unit_waits_for_launcher_handoff_and_reuses_successful_asr(self):
        (self.fixture.root / "control.json").write_text('{"fail_mic":100}')
        time.sleep(0.4)
        self.stop_public()
        self.await_status({"incomplete"})
        self.await_stopped()
        success = self.session.private / "windows/000000/call.ok.json"
        receipt = success.read_bytes()
        (self.fixture.root / "control.json").write_text('{}')
        launch = recorder.launch_unit

        def delayed_handoff(session, config, retry):
            launch(session, config, retry)
            time.sleep(0.25)
            properties = recorder.owner_properties(session.state, session.config)
            self.assertIn(properties.get("ActiveState"), ("active", "activating"))

        with patch.object(recorder, "state_root", return_value=self.fixture.root / "controller"), \
             patch.object(recorder, "current_directory", return_value=self.session.directory), \
             patch.object(recorder, "launch_unit", side_effect=delayed_handoff):
            recorder.retry(self.session.directory, self.session.config, self.config_path)
        self.session = recorder.Session(self.session.directory, self.session.config)
        manifest = self.await_status({"ready", "incomplete"})
        self.assertEqual(manifest["status"], "ready", manifest.get("failure"))
        self.await_stopped()
        self.assertEqual(success.read_bytes(), receipt)
        self.assertEqual((self.fixture.root / "call-attempts").read_text(), "1")
        self.assertEqual((self.fixture.root / "mic-attempts").read_text(), "2")
        self.assertEqual(len(list((self.session.private / "windows").glob("*/done.json"))), 1)
        self.assert_unrelated_modules()

    def test_diarization_retry_uses_owned_unit_without_replaying_asr(self):
        time.sleep(0.5)
        self.stop_public()
        manifest = self.await_status({"ready", "incomplete"})
        self.assertEqual(manifest["status"], "ready", manifest.get("failure"))
        self.await_stopped()
        state = recorder.read_json(self.session.private / "state.json")
        self.assertEqual(state["diarization"]["status"], "failed")
        asr_attempts = {
            side: (self.fixture.root / (side + "-attempts")).read_text()
            for side in recorder.SIDES
        }
        windows_before = {
            str(path.relative_to(self.session.private)): path.read_bytes()
            for path in (self.session.private / "windows").rglob("*")
            if path.is_file()
        }
        base_transcript = (self.session.directory / "transcript.turns.txt").read_bytes()

        (self.fixture.root / "control.json").write_text('{"diarization_success":true}')
        self.command("retry-diarization", self.session.directory)
        self.session = recorder.Session(self.session.directory, self.config)
        observed = json.loads(self.command("status", "--json").stdout)
        self.assertIn(observed["status"], ("diarizing", "ready"))
        self.await_stopped()

        manifest = recorder.read_json(self.session.directory / "recording.json")
        state = recorder.read_json(self.session.private / "state.json")
        self.assertEqual(manifest["status"], "ready")
        self.assertEqual(manifest["source"]["transcript"]["path"], "transcript.diarized.turns.txt")
        self.assertEqual(state["diarization"]["status"], "ready")
        self.assertEqual(state["diarization"]["attempts"], 2)
        self.assertEqual(
            {
                str(path.relative_to(self.session.private)): path.read_bytes()
                for path in (self.session.private / "windows").rglob("*")
                if path.is_file()
            },
            windows_before,
        )
        self.assertEqual(
            (self.session.directory / "transcript.turns.txt").read_bytes(),
            base_transcript,
        )
        self.assertEqual(
            {
                side: (self.fixture.root / (side + "-attempts")).read_text()
                for side in recorder.SIDES
            },
            asr_attempts,
        )

    @staticmethod
    def snapshot(directory):
        return {str(path.relative_to(directory)): path.read_bytes()
                for path in directory.rglob("*") if path.is_file()}

    def widget_action(self, right_click=False):
        widget = Path(__file__).parent.parent / "desktop/dms-plugins/record-call/RecordCallWidget.qml"
        script = r'''
            const fs = require('fs');
            const text = fs.readFileSync(process.argv[1], 'utf8');
            const state = JSON.parse(fs.readFileSync(0, 'utf8'));
            const toggleProc = {running:false};
            const root = {_pollOut:JSON.stringify(state)};
            const status = new Function('root', 'exitCode', 'exitStatus', text.match(/onExited: \(exitCode, exitStatus\) => \{([\s\S]*?)\n        \}\n    \}/)[1]);
            status(root, 0, 0);
            root.recording = root.phase === 'recording';
            root.finalizing = ['starting','finalizing','diarizing'].includes(root.phase);
            for (const name of ['toggle','startNew']) {
                const body = text.match(new RegExp('function ' + name + '\\(\\) \\{([\\s\\S]*?)\\n    \\}'))[1];
                root[name] = () => new Function('root','toggleProc',body)(root,toggleProc);
            }
            const binding = process.argv[2] === 'right' ? 'pillRightClickAction' : 'pillClickAction';
            new Function('root', 'return ' + text.match(new RegExp(binding + ': (.*)'))[1])(root)();
            process.stdout.write(JSON.stringify(toggleProc.command));
        '''
        status = self.command("status", "--json").stdout
        result = subprocess.run(["node", "-e", script, str(widget), "right" if right_click else "left"],
                                input=status, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_widget_can_start_next_meeting_after_repeated_asr_failure_without_losing_retry(self):
        (self.fixture.root / "control.json").write_text('{"fail_mic":100}')
        time.sleep(0.5)
        self.stop_public()
        self.await_status({"incomplete"})
        self.await_stopped()
        old_directory = self.session.directory
        original_id = self.session.manifest["recordingId"]
        receipt = (self.session.private / "windows/000000/call.ok.json").read_bytes()
        for _ in range(2):
            action = self.widget_action()
            self.assertEqual(action, ["record-call", "retry", str(old_directory)])
            self.command(*action[1:])
            self.session = recorder.Session(old_directory, self.config)
            self.await_status({"incomplete"})
            self.await_stopped()
            self.assertEqual((self.session.private / "windows/000000/call.ok.json").read_bytes(), receipt)
        self.assertEqual((self.fixture.root / "call-attempts").read_text(), "1")
        self.assertEqual((self.fixture.root / "mic-attempts").read_text(), "3")
        before = self.snapshot(old_directory)
        action = self.widget_action(right_click=True)
        self.assertEqual(action, ["record-call", "start"])
        # Supply a test-only destination to the public start command so the
        # actual widget action cannot write to the user's recording directory.
        new_directory = self.fixture.root / "next meeting"
        (self.fixture.root / "control.json").write_text('{}')
        self.command(*action[1:], new_directory)
        self.directories.append(new_directory)
        self.session = recorder.Session(new_directory, self.config)
        self.await_status({"recording"})
        time.sleep(0.5)
        self.stop_public()
        self.assertEqual(self.await_status({"ready", "incomplete"})["status"], "ready")
        self.await_stopped()
        self.assertNotEqual(self.session.manifest["recordingId"], original_id)
        self.assertEqual(self.snapshot(old_directory), before)
        self.assert_unrelated_modules()


if __name__ == "__main__":
    unittest.main()
