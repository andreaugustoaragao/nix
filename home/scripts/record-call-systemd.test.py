"""Explicit synthetic systemd integration test; no capture devices or live pactl.

Run separately from sandboxed Nix checks. The only units started/stopped by this
fixture run generated PCM and fixture module operations. It retains READY intake
artifacts under a private evidence directory for the Fulcrum consumer test.
"""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

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
        self.session = self.fixture.session()
        self.fixture.synthetic_capture(self.session)
        self.session.manifest["recordingId"] = str(uuid.uuid4())
        self.session.state.update({"recordingId": self.session.manifest["recordingId"],
                                   "bootId": recorder.boot_id(), "invocationId": None, "unit": ""})
        self.session.config.update({"systemdRun": shutil.which("systemd-run"), "systemctl": shutil.which("systemctl")})
        self.session.persist()
        config = self.fixture.root / "config with % and $quote.json"
        config.write_text(json.dumps(self.session.config))
        self.config_path = config
        with patch.object(recorder, "state_root", return_value=self.fixture.root / "controller"):
            recorder.launch_unit(self.session, config, False)
        self.await_status({"recording"})

    def tearDown(self):
        subprocess.run([self.session.config["systemctl"], "--user", "stop", self.session.state["unit"]],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        self.fixture.tearDown()

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
        time.sleep(0.8)
        state = recorder.read_json(self.session.private / "state.json")
        recorder.atomic_json(self.session.private / "stop.json", {"invocationId": state["invocationId"]})
        manifest = self.await_status({"ready", "incomplete"})
        self.assertEqual(manifest["status"], "ready", manifest.get("failure"))
        self.await_stopped()
        self.assert_unrelated_modules()
        cleaned = recorder.read_json(self.session.private / "state.json")
        self.assertEqual(cleaned["cleanupCompletedInvocationId"], state["invocationId"])
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
        state = recorder.read_json(self.session.private / "state.json")
        recorder.atomic_json(self.session.private / "stop.json", {"invocationId": state["invocationId"]})
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


if __name__ == "__main__":
    unittest.main()
