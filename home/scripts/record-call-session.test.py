"""Recorder regressions: synthetic files/processes only, never system audio."""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import textwrap
import unittest
import wave
from unittest.mock import patch
from contextlib import redirect_stdout

SPEC = importlib.util.spec_from_file_location(
    "record_call_session", Path(__file__).with_name("record-call-session.py")
)
recorder = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = recorder
SPEC.loader.exec_module(recorder)


def wav(path, milliseconds=1000):
    with wave.open(str(path), "wb") as output:
        output.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        output.writeframes(b"\x01\x00" * (milliseconds * 16))


class RecorderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="recorder-test '")
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def asr(self, value):
        path = self.root / "result.json"
        path.write_text(json.dumps(value))
        return path

    def test_both_valid_asr_formats_and_silence(self):
        self.assertEqual(recorder.validate_asr(self.asr({"segments": []})), 0)
        self.assertEqual(recorder.validate_asr(self.asr({"transcription": []})), 0)
        self.assertEqual(recorder.validate_asr(self.asr({"segments": [
            {"start": 0, "end": 1, "text": "Hello"}]})), 1)
        self.assertEqual(recorder.validate_asr(self.asr({"transcription": [
            {"offsets": {"from": 0, "to": 1000}, "text": "Hello"}]})), 1)

    def test_asr_missing_malformed_and_error_responses_fail(self):
        for value in ({}, {"error": "failed"}, {"segments": None},
                      {"segments": [{"text": "missing time"}]},
                      {"segments": [{"start": 2, "end": 1, "text": "bad"}]},
                      {"segments": [{"start": float("nan"), "end": 1, "text": "bad"}]}):
            with self.subTest(value=value), self.assertRaises(recorder.Failure):
                recorder.validate_asr(self.asr(value))
        for content in ("", "{"):
            path = self.root / "broken.json"
            path.write_text(content)
            with self.assertRaises(recorder.Failure):
                recorder.validate_asr(path)
        with self.assertRaises(recorder.Failure):
            recorder.validate_asr(self.root / "absent.json")

    def test_asr_accepts_bounded_padding_timestamps_in_both_formats(self):
        # Actual remote Whisper output for a 45-second recording window put
        # its final ellipsis at 45.02–45.12. Padding is outside the emitted
        # audio range, but must not reject all the valid speech in the window.
        for key, segment in (
            ("segments", {"start": 45.02, "end": 45.12, "text": "..."}),
            ("transcription", {"offsets": {"from": 45020, "to": 45120}, "text": "..."}),
        ):
            with self.subTest(format=key):
                self.assertEqual(recorder.validate_asr(self.asr({key: [segment]}), 45000), 1)

    def test_asr_padding_tolerance_does_not_accept_invalid_timestamps(self):
        for start, end in ((46.001, 46.1), (45.02, 46.001), (45.12, 45.02),
                           (-0.01, 0), (float("nan"), 1), (0, float("inf"))):
            for key, segment in (
                ("segments", {"start": start, "end": end, "text": "invalid"}),
                ("transcription", {"offsets": {"from": start * 1000, "to": end * 1000}, "text": "invalid"}),
            ):
                with self.subTest(format=key, start=start, end=end), self.assertRaises(recorder.Failure):
                    recorder.validate_asr(self.asr({key: [segment]}), 45000)

    def test_atomic_commit_and_coverage_do_not_hide_dead_microphone(self):
        manifest = recorder.new_manifest("abc", "2026-10-06T15:00:00.000Z", "America/Denver")
        self.assertEqual(manifest["status"], "starting")
        self.assertIsNone(manifest["finalizedAt"])
        self.assertFalse(manifest["coverage"]["complete"])
        self.assertEqual(manifest["coverage"]["sides"]["call"]["missing"], [])
        recorder.atomic_json(self.root / "state.json", manifest)
        self.assertEqual(json.loads((self.root / "state.json").read_text()), manifest)
        spans = {"call": [{"startMs": 0, "endMs": 60000}],
                 "mic": [{"startMs": 10, "endMs": 30000}]}
        coverage = recorder.calculate_coverage(spans, spans, 60000, [])
        self.assertFalse(coverage["complete"])
        self.assertTrue(coverage["sides"]["mic"]["missing"])

    def test_sample_jitter_preserves_tail_but_internal_gap_is_incomplete(self):
        spans = {"call": [{"startMs": 0, "endMs": 60032}],
                 "mic": [{"startMs": 20, "endMs": 59980}]}
        coverage = recorder.calculate_coverage(spans, spans, 60000, [])
        self.assertTrue(coverage["complete"])
        self.assertEqual(coverage["sides"]["call"]["capturedMs"], 60032)
        spans["mic"] = [{"startMs": 20, "endMs": 30000},
                        {"startMs": 30500, "endMs": 60000}]
        self.assertFalse(recorder.calculate_coverage(spans, spans, 60000, [
            {"side": "mic", "startMs": 30000, "endMs": 30500, "reason": "capture_restarted"}
        ])["complete"])

    def test_long_capture_allows_only_bounded_final_sample_clock_drift(self):
        duration = 20588792
        actual = {
            "call": [{"startMs": 1, "endMs": 20578176.0625}],
            "mic": [{"startMs": 4, "endMs": 20567085.6875}],
        }
        coverage = recorder.calculate_coverage(actual, actual, duration, [])
        self.assertTrue(coverage["complete"])
        self.assertEqual(coverage["sides"]["call"]["missing"], [])
        self.assertEqual(coverage["sides"]["mic"]["missing"], [])
        self.assertGreaterEqual(recorder.capture_end_tolerance(duration), 21707)
        self.assertLessEqual(recorder.capture_end_tolerance(duration),
                             recorder.MAX_CAPTURE_END_TOLERANCE_MS)

        beyond_budget = {
            "call": [{"startMs": 0, "endMs": duration}],
            "mic": [{"startMs": 0, "endMs": duration - recorder.MAX_CAPTURE_END_TOLERANCE_MS - 1}],
        }
        coverage = recorder.calculate_coverage(beyond_budget, beyond_budget, duration, [])
        self.assertFalse(coverage["complete"])
        self.assertEqual(coverage["sides"]["mic"]["missing"], [{
            "startMs": duration - recorder.MAX_CAPTURE_END_TOLERANCE_MS - 1,
            "endMs": duration,
            "reason": "capture_ended_early",
        }])

        late_start = {
            "call": [{"startMs": 0, "endMs": duration}],
            "mic": [{"startMs": recorder.EDGE_TOLERANCE_MS + 1, "endMs": duration}],
        }
        coverage = recorder.calculate_coverage(late_start, late_start, duration, [])
        self.assertFalse(coverage["complete"])
        self.assertEqual(coverage["sides"]["mic"]["missing"][0]["reason"], "capture_started_late")

    def test_capture_end_tolerance_boundaries_do_not_weaken_other_evidence(self):
        self.assertEqual(recorder.capture_end_tolerance(60000), recorder.EDGE_TOLERANCE_MS)
        self.assertEqual(recorder.capture_end_tolerance(1000000), 1500)
        self.assertEqual(recorder.capture_end_tolerance(30000000),
                         recorder.MAX_CAPTURE_END_TOLERANCE_MS)

        duration = 1000000
        tolerance = recorder.capture_end_tolerance(duration)
        for end in (duration - tolerance, duration + tolerance):
            with self.subTest(end=end):
                spans = {side: [{"startMs": 0, "endMs": end}] for side in recorder.SIDES}
                self.assertTrue(recorder.calculate_coverage(spans, spans, duration, [])["complete"])

        for end, reason in ((duration - tolerance - 0.0625, "capture_ended_early"),
                            (duration + tolerance + 0.0625, "capture_clock_mismatch")):
            with self.subTest(end=end):
                spans = {side: [{"startMs": 0, "endMs": end}] for side in recorder.SIDES}
                coverage = recorder.calculate_coverage(spans, spans, duration, [])
                self.assertFalse(coverage["complete"])
                reasons = [item["reason"] for item in coverage["sides"]["mic"]["missing"]]
                if reason == "capture_clock_mismatch":
                    # The range is outside public duration and clips away, but
                    # has_missing still blocks READY.
                    self.assertEqual(reasons, [])
                else:
                    self.assertEqual(reasons, [reason])

        captured = {side: [{"startMs": 0, "endMs": duration}] for side in recorder.SIDES}
        transcribed = {
            "call": captured["call"],
            "mic": [{"startMs": 0, "endMs": duration - 0.0625}],
        }
        self.assertFalse(recorder.calculate_coverage(captured, transcribed, duration, [])["complete"])

    def test_untranscribed_audio_and_missing_side_never_ready(self):
        spans = {"call": [{"startMs": 0, "endMs": 60000}],
                 "mic": [{"startMs": 0, "endMs": 60000}]}
        processed = {"call": spans["call"], "mic": [{"startMs": 0, "endMs": 30000}]}
        self.assertFalse(recorder.calculate_coverage(spans, processed, 60000, [])["complete"])
        self.assertFalse(recorder.calculate_coverage({"call": [], "mic": []},
                                                    {"call": [], "mic": []}, 0, [])["complete"])

    def test_missing_ranges_are_ordered_disjoint_and_bounded(self):
        spans = {side: [{"startMs": 0, "endMs": 1000}] for side in recorder.SIDES}
        done = {side: [{"startMs": 0, "endMs": 400}] for side in recorder.SIDES}
        coverage = recorder.calculate_coverage(spans, done, 1000, [
            {"side": "call", "startMs": 1400, "endMs": 1500, "reason": "segmenter_failed"},
            {"side": "call", "startMs": 600, "endMs": 800, "reason": "capture_restarted"},
        ])
        self.assertEqual(coverage["sides"]["call"]["missing"], [
            {"startMs": 400, "endMs": 1000, "reason": "capture_restarted"}])
        self.assertFalse(coverage["complete"])
        outside = recorder.calculate_coverage(spans, spans, 1000, [
            {"side": "call", "startMs": 1400, "endMs": 1500, "reason": "segmenter_failed"}])
        self.assertEqual(outside["sides"]["call"]["missing"], [])
        self.assertFalse(outside["complete"])

    def test_only_exact_owned_modules_are_selected(self):
        modules = [
            {"index": 1, "name": "module-null-sink", "argument": "sink_name=record-call-owned"},
            {"index": 2, "name": "module-loopback", "argument": "source=record-call-owned.monitor sink=@DEFAULT_SINK@ latency_msec=50"},
            {"index": 3, "name": "module-null-sink", "argument": "sink_name=unrelated"}]
        self.assertTrue(recorder.module_owned(modules[0], 1, "module-null-sink", "record-call-owned"))
        self.assertTrue(recorder.module_owned(modules[1], 2, "module-loopback", "record-call-owned"))
        self.assertFalse(recorder.module_owned(modules[2], 3, "module-null-sink", "record-call-owned"))
        self.assertFalse(recorder.module_owned(modules[0], 3, "module-null-sink", "record-call-owned"))

    def test_window_audio_handles_quoted_paths_and_retains_final_tail(self):
        source = self.root / "audio ' ; $(ignored).wav"
        wav(source, 1250)
        fragments = [{"path": str(source), "startMs": 0, "endMs": 1250,
                      "sha256": recorder.file_hash(source)}]
        destination = self.root / "window.wav"
        recorder.write_window_audio(fragments, 0, 1250, destination)
        self.assertEqual(recorder.wav_duration(destination), 1250)
        self.assertEqual(recorder.file_hash(source), recorder.file_hash(destination))

    def test_changed_committed_audio_is_rejected(self):
        source = self.root / "audio.wav"
        wav(source)
        fragments = [{"path": str(source), "startMs": 0, "endMs": 1000,
                      "sha256": recorder.file_hash(source)}]
        wav(source, 1500)
        with self.assertRaises(recorder.Failure):
            recorder.write_window_audio(fragments, 0, 1000, self.root / "out.wav")

    def test_stale_unit_identity_is_not_live(self):
        state = {"bootId": "old", "invocationId": "aaa", "unit": "record-call-test.service"}
        self.assertFalse(recorder.owner_matches(state, "new", {"ActiveState": "active", "InvocationID": "aaa"}))
        self.assertFalse(recorder.owner_matches(state, "old", {"ActiveState": "active", "InvocationID": "bbb"}))
        self.assertTrue(recorder.owner_matches(state, "old", {"ActiveState": "active", "InvocationID": "aaa"}))

    def session(self, duration=1250, remote=True):
        directory = self.root / "recording"
        private = directory / ".record-call"
        private.mkdir(parents=True)
        (directory / "chunks").mkdir()
        (self.root / "control.json").write_text("{}")
        executable = self.root / "fake-asr"
        executable.write_text(f"#!{sys.executable}\n" + textwrap.dedent(f'''
            import json, pathlib, sys, time, wave
            root = pathlib.Path({str(self.root)!r})
            remote = '-F' in sys.argv
            audio = pathlib.Path(next(a[6:] for a in sys.argv if a.startswith('file=@'))) if remote else pathlib.Path(sys.argv[sys.argv.index('-f')+1])
            side = audio.stem
            index = audio.parent.parent.name
            counter = root / (side + '-attempts')
            count = int(counter.read_text()) + 1 if counter.exists() else 1
            counter.write_text(str(count))
            mode = json.loads((root / 'control.json').read_text())
            time.sleep(mode.get('sleep_' + side, 0))
            if mode.get('fail_' + side, 0) >= count:
                print('synthetic ASR failure', file=sys.stderr)
                sys.exit(17)
            value = {{'segments': [] if mode.get('silence') else [{{'start': 0.1, 'end': 0.2, 'text': side + ' window ' + index}}]}}
            if mode.get('trailing_padding_' + side):
                with wave.open(str(audio), 'rb') as source:
                    duration = source.getnframes() / source.getframerate()
                value['segments'].append({{'start': duration - 0.2, 'end': duration + 0.02, 'text': side + ' final tail ' + index}})
                value['segments'].append({{'start': duration + 0.02, 'end': duration + 0.12, 'text': '...'}})
            text = '{{' if mode.get('malformed_' + side) else json.dumps(value)
            if remote:
                print(text)
            elif not mode.get('missing_' + side):
                pathlib.Path(sys.argv[sys.argv.index('-of')+1] + '.json').write_text(text)
        '''))
        executable.chmod(0o700)
        source = Path(__file__).with_name("record-call.nix").read_text()
        config = {"python": sys.executable, "curl": str(executable), "whisper": str(executable)}
        for name in ("merge", "dedupe", "turns", "align", "retime"):
            begin = source.index(f'  {name}Py = pkgs.writeText "record-call-{name}.py" \'\'\n')
            body = source[begin:].split("\n", 1)[1].split("\n  '';", 1)[0]
            path = self.root / (name + ".py")
            path.write_text(textwrap.dedent(body))
            config[name] = str(path)
        manifest = recorder.new_manifest("test-id", "2026-10-06T15:00:00.000Z", "UTC")
        manifest["endedAt"] = recorder.datetime.fromtimestamp(
            recorder.timestamp(manifest["startedAt"]) + duration / 1000, recorder.timezone.utc
        ).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        fragments = {side: [] for side in recorder.SIDES}
        for side in recorder.SIDES:
            path = directory / "chunks" / (side + "_000000.wav")
            wav(path, duration)
            fragments[side].append({"path": str(path), "startMs": 0, "endMs": duration,
                                    "sha256": recorder.file_hash(path)})
        state = {"fragments": fragments, "gaps": [], "advanceMs": 30000, "windowMs": 45000,
                 "fragmentMs": 5000, "turnGap": 8, "whisperServerUrl": "http://synthetic.invalid" if remote else "",
                 "model": "unused", "vadModel": "unused", "runs": {side: [] for side in recorder.SIDES},
                 "sink": "record-call-test-id", "modules": {}}
        recorder.atomic_json(directory / "recording.json", manifest)
        recorder.atomic_json(private / "state.json", state)
        return recorder.Session(directory, config)

    def test_failed_side_resumes_without_repeating_success_or_text(self):
        session = self.session()
        (self.root / "control.json").write_text('{"fail_mic":1}')
        with self.assertRaises(recorder.Failure) as error:
            session.process_window(0, 1250, 1250)
        self.assertEqual(error.exception.side, "mic")
        self.assertFalse((session.private / "windows/000000/done.json").exists())
        session.finalize()
        self.assertEqual(session.manifest["status"], "ready")
        self.assertEqual((self.root / "call-attempts").read_text(), "1")
        self.assertEqual((self.root / "mic-attempts").read_text(), "2")
        text = (session.directory / "transcript.raw.txt").read_text()
        self.assertEqual(text.count("call window 000000"), 1)
        self.assertEqual(text.count("mic window 000000"), 1)
        snapshot = (session.directory / "transcript.turns.txt").read_bytes()
        session.finalize()
        self.assertEqual((session.directory / "transcript.turns.txt").read_bytes(), snapshot)
        self.assertEqual((self.root / "mic-attempts").read_text(), "2")

    def test_recovery_passes_padded_asr_and_finishes_remaining_audio_once(self):
        session = self.session(duration=90000)
        session.process_window(0, 45000, 30000)
        first = session.private / "windows/000000/done.json"
        first_receipt = first.read_bytes()
        (self.root / "control.json").write_text('{"fail_mic":2}')
        with self.assertRaises(recorder.Failure):
            session.process_window(1, 75000, 60000)
        second_call = session.private / "windows/000001/call.ok.json"
        second_call_receipt = second_call.read_bytes()
        (self.root / "control.json").write_text('{"trailing_padding_mic":true}')
        session.finalize()
        self.assertEqual(session.manifest["status"], "ready")
        self.assertTrue(session.manifest["coverage"]["complete"])
        for side in recorder.SIDES:
            self.assertEqual(session.manifest["coverage"]["sides"][side]["transcribedMs"], 90000)
        self.assertEqual(first.read_bytes(), first_receipt)
        self.assertEqual(second_call.read_bytes(), second_call_receipt)
        text = (session.directory / "transcript.raw.txt").read_text()
        for index in range(3):
            for side in recorder.SIDES:
                self.assertEqual(text.count(f"{side} window {index:06d}"), 1)
        self.assertEqual(text.count("mic final tail 000002"), 1)
        self.assertNotIn("...", text)
        self.assertNotIn("mic final tail 000001", text)
        self.assertEqual((self.root / "call-attempts").read_text(), "3")
        self.assertEqual((self.root / "mic-attempts").read_text(), "4")
        finalized = (session.directory / "transcript.turns.txt").read_bytes()
        session.finalize()
        self.assertEqual((session.directory / "transcript.turns.txt").read_bytes(), finalized)
        self.assertEqual((self.root / "call-attempts").read_text(), "3")
        self.assertEqual((self.root / "mic-attempts").read_text(), "4")

    def test_shorter_side_padding_cannot_enter_merged_transcript(self):
        session = self.session(duration=90000)
        mic = session.directory / "chunks/mic_000000.wav"
        wav(mic, 89500)
        session.state["fragments"]["mic"] = [{
            "path": str(mic),
            "startMs": 0,
            "endMs": 89500,
            "sha256": recorder.file_hash(mic),
        }]
        session.persist()
        (self.root / "control.json").write_text('{"trailing_padding_mic":true}')
        session.finalize()
        self.assertEqual(session.manifest["status"], "ready")
        self.assertTrue(session.manifest["coverage"]["complete"])
        self.assertEqual(session.manifest["coverage"]["sides"]["mic"]["captureEndMs"], 89500)
        transcript = (session.directory / "transcript.raw.txt").read_text()
        self.assertNotIn("mic final tail", transcript)
        self.assertNotIn("...", transcript)

    def asr_events(self, output):
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        for event in events:
            self.assertEqual(set(event), {"event", "level", "provider", "side", "windowIndex",
                                          "outcome", "code", "durationMs"})
            self.assertEqual(event["event"], "record_call_asr_attempt")
            self.assertIn(event["provider"], ("remote", "local"))
            self.assertIn(event["side"], recorder.SIDES)
            self.assertEqual(event["windowIndex"], 0)
            self.assertIsInstance(event["durationMs"], int)
            self.assertGreaterEqual(event["durationMs"], 0)
            self.assertLess(len(json.dumps(event)), 300)
            self.assertNotIn(str(self.root), json.dumps(event))
            self.assertNotIn("synthetic.invalid", json.dumps(event))
        return events

    def test_asr_observes_actual_success_and_nonzero_attempts_without_relogging_receipts(self):
        session = self.session()
        (self.root / "control.json").write_text('{"fail_mic":1}')
        output = io.StringIO()
        with redirect_stdout(output):
            with self.assertRaises(recorder.Failure) as error:
                session.process_window(0, 1250, 1250)
            self.assertEqual(error.exception.code, "asr_exit")
            session.finalize()
            session.finalize()
        events = self.asr_events(output)
        self.assertEqual([(event["side"], event["outcome"], event["code"]) for event in events], [
            ("call", "success", "ok"), ("mic", "failure", "asr_exit"), ("mic", "success", "ok")])
        self.assertTrue(all(event["provider"] == "remote" for event in events))
        self.assertEqual([event["level"] for event in events], ["info", "warning", "info"])

    def test_timeout_observation_retains_successful_side_and_retries_only_timed_out_side(self):
        session = self.session()
        (self.root / "control.json").write_text('{"sleep_mic":5}')
        original_wait = subprocess.Popen.wait

        def short_fixture_timeout(child, timeout=None):
            if child.args[0] == session.config["curl"] and timeout is not None:
                timeout = min(timeout, 0.15)
            return original_wait(child, timeout=timeout)

        output = io.StringIO()
        with redirect_stdout(output):
            with patch.object(subprocess.Popen, "wait", short_fixture_timeout), self.assertRaises(recorder.Failure) as error:
                session.process_window(0, 1250, 1250)
            self.assertEqual(error.exception.code, "asr_timeout")
            self.assertEqual(error.exception.side, "mic")
            window = session.private / "windows/000000"
            self.assertEqual(recorder.read_json(window / "failure.json"), error.exception.public())
            self.assertFalse((window / "mic.ok.json").exists())
            self.assertFalse((window / "done.json").exists())
            receipt = (window / "call.ok.json").read_bytes()
            (self.root / "control.json").write_text('{}')
            session.finalize()
        self.assertEqual((window / "call.ok.json").read_bytes(), receipt)
        self.assertEqual((self.root / "call-attempts").read_text(), "1")
        self.assertEqual((self.root / "mic-attempts").read_text(), "2")
        self.assertEqual(session.manifest["status"], "ready")
        events = self.asr_events(output)
        self.assertEqual([(event["side"], event["code"]) for event in events], [
            ("call", "ok"), ("mic", "asr_timeout"), ("mic", "ok")])
        self.assertGreaterEqual(events[1]["durationMs"], 100)

    def test_local_silence_is_observed_as_success_without_transcript_content(self):
        session = self.session(remote=False)
        (self.root / "control.json").write_text('{"silence":true}')
        output = io.StringIO()
        with redirect_stdout(output):
            session.finalize()
        events = self.asr_events(output)
        self.assertEqual(len(events), 2)
        self.assertTrue(all(event["provider"] == "local" and event["code"] == "ok" for event in events))
        self.assertEqual(session.manifest["source"]["transcript"]["speechTurns"], 0)

    def test_logging_failure_never_turns_failed_asr_into_success(self):
        session = self.session()
        (self.root / "control.json").write_text('{"fail_mic":1}')
        with patch("builtins.print", side_effect=BrokenPipeError("synthetic closed journal")):
            with self.assertRaises(recorder.Failure) as error:
                session.process_window(0, 1250, 1250)
        self.assertEqual(error.exception.code, "asr_exit")
        window = session.private / "windows/000000"
        self.assertTrue((window / "call.ok.json").exists())
        self.assertFalse((window / "mic.ok.json").exists())
        self.assertFalse((window / "done.json").exists())
        self.assertEqual(recorder.read_json(window / "failure.json")["code"], "asr_exit")
        self.assertNotEqual(session.manifest["status"], "ready")

    def test_cleanup_warning_is_visible_without_changing_ready_artifacts(self):
        session = self.session()
        with redirect_stdout(io.StringIO()):
            session.finalize()
        session.state.update({"bootId": recorder.boot_id(), "invocationId": "cleanup-warning",
                              "unit": "record-call-synthetic.service"})
        recorder.atomic_json(session.private / "state.json", session.state)
        paths = [session.directory / "recording.json", *session.directory.glob("transcript*.txt")]
        before = {path.name: path.read_bytes() for path in paths}
        output = io.StringIO()
        with patch.object(recorder, "owner_properties", return_value={"InvocationID": "cleanup-warning"}), \
             patch.object(recorder.Session, "command", side_effect=OSError("private account path must not be logged")), \
             patch.dict(os.environ, {"INVOCATION_ID": "cleanup-warning"}), redirect_stdout(output):
            recorder.cleanup_after_owner(session.directory, session.config)
        event = json.loads(output.getvalue())
        self.assertEqual(set(event), {"event", "level", "outcome", "code", "durationMs"})
        self.assertEqual({key: event[key] for key in ("event", "level", "outcome", "code")}, {
            "event": "record_call_module_cleanup", "level": "warning", "outcome": "failure",
            "code": "owned_module_cleanup_unavailable"})
        self.assertIsInstance(event["durationMs"], int)
        self.assertGreaterEqual(event["durationMs"], 0)
        self.assertNotIn("private account", output.getvalue())
        self.assertEqual({path.name: path.read_bytes() for path in paths}, before)
        state = recorder.read_json(session.private / "state.json")
        self.assertEqual(state["cleanupWarning"], "owned_module_cleanup_unavailable")
        self.assertEqual(state["cleanupCompletedInvocationId"], "cleanup-warning")

    def test_final_window_is_committed_once_and_full_tail_transcribed(self):
        session = self.session(duration=45000)
        session.finalize()
        self.assertEqual(len(list((session.private / "windows").glob("*/done.json"))), 1)
        self.assertEqual(session.manifest["coverage"]["sides"]["call"]["transcribedMs"], 45000)
        self.assertEqual((self.root / "call-attempts").read_text(), "1")

    def test_successful_silence_has_empty_committed_transcript(self):
        session = self.session(remote=False)
        (self.root / "control.json").write_text('{"silence":true}')
        session.finalize()
        transcript = session.manifest["source"]["transcript"]
        self.assertEqual(session.manifest["status"], "ready")
        self.assertEqual(transcript["speechTurns"], 0)
        self.assertEqual(transcript["bytes"], 0)
        self.assertEqual(transcript["sha256"], recorder.hashlib.sha256(b"").hexdigest())

    def test_local_exit_zero_missing_output_cannot_commit(self):
        session = self.session(remote=False)
        (self.root / "control.json").write_text('{"missing_mic":true}')
        with self.assertRaises(recorder.Failure) as error:
            session.finalize()
        self.assertEqual(error.exception.code, "invalid_asr_output")
        self.assertFalse((session.private / "windows/000000/done.json").exists())

    def test_malformed_remote_output_and_required_turns_failure_block_ready(self):
        session = self.session()
        (self.root / "control.json").write_text('{"malformed_call":true}')
        with self.assertRaises(recorder.Failure):
            session.finalize()
        (self.root / "control.json").write_text('{}')
        Path(session.config["turns"]).write_text("raise SystemExit(12)\n")
        with self.assertRaises(recorder.Failure) as error:
            session.finalize()
        self.assertEqual(error.exception.code, "turns_failed")
        self.assertNotEqual(session.manifest["status"], "ready")
        self.assertIsNone(session.manifest["source"]["transcript"])

    def test_crash_after_window_commit_rebuilds_without_asr_replay(self):
        session = self.session()
        session.process_window(0, 1250, 1250)
        restored = recorder.Session(session.directory, session.config)
        restored.finalize()
        self.assertEqual((self.root / "call-attempts").read_text(), "1")
        self.assertEqual((self.root / "mic-attempts").read_text(), "1")
        self.assertEqual(restored.manifest["status"], "ready")

    def assert_final_window_recovery(self, duration):
        session = self.session(duration=duration)
        persist = session.persist

        def crash_before_ready_commit():
            if session.manifest["status"] == "ready":
                raise RuntimeError("synthetic crash before READY commit")
            persist()

        with patch.object(session, "persist", side_effect=crash_before_ready_commit):
            with self.assertRaises(RuntimeError):
                session.finalize()
        before = {str(path.relative_to(session.directory)): path.read_bytes()
                  for path in (session.private / "windows").rglob("*") if path.is_file()}
        transcripts = {name: (session.directory / name).read_bytes()
                       for name in ("transcript.raw.txt", "transcript.txt", "transcript.turns.txt")}
        counts = {side: (self.root / (side + "-attempts")).read_text() for side in recorder.SIDES}
        restored = recorder.Session(session.directory, session.config)
        self.assertEqual(restored.manifest["status"], "finalizing")
        restored.finalize()
        self.assertEqual(restored.manifest["status"], "ready")
        self.assertEqual({side: (self.root / (side + "-attempts")).read_text() for side in recorder.SIDES}, counts)
        self.assertEqual({str(path.relative_to(session.directory)): path.read_bytes()
                          for path in (session.private / "windows").rglob("*") if path.is_file()}, before)
        self.assertEqual({name: (session.directory / name).read_bytes() for name in transcripts}, transcripts)

    def test_crash_after_final_45_second_window_does_not_replay_tail(self):
        self.assert_final_window_recovery(45000)

    def test_crash_after_final_75_second_window_does_not_replay_tail(self):
        self.assert_final_window_recovery(75000)

    def test_crash_after_partial_31_second_window_does_not_replay_tail(self):
        self.assert_final_window_recovery(31000)

    def test_crash_after_partial_61_second_window_does_not_replay_tail(self):
        self.assert_final_window_recovery(61000)

    def test_resume_preserves_nonfinal_30_second_emission_receipt(self):
        session = self.session(duration=75000)
        session.process_window(0, 45000, 30000)
        receipt = session.private / "windows/000000/done.json"
        before = receipt.read_bytes()
        restored = recorder.Session(session.directory, session.config)
        restored.finalize()
        self.assertEqual(receipt.read_bytes(), before)
        self.assertEqual((self.root / "call-attempts").read_text(), "2")
        self.assertEqual((self.root / "mic-attempts").read_text(), "2")
        self.assertEqual(restored.manifest["coverage"]["sides"]["call"]["transcribedMs"], 75000)
        raw = (session.directory / "transcript.raw.txt").read_text()
        self.assertEqual(raw.count("call window 000000"), 1)
        self.assertEqual(raw.count("call window 000001"), 1)

    def test_overlapping_committed_emission_receipts_are_not_certified(self):
        session = self.session(duration=75000)
        session.process_window(0, 45000, 30000)
        session.process_window(1, 75000, 75000)
        session.process_window(2, 75000, 75000)
        with self.assertRaises(recorder.Failure) as error:
            session.finalize()
        self.assertEqual(error.exception.code, "window_receipt_invalid")
        self.assertEqual((self.root / "call-attempts").read_text(), "3")
        self.assertEqual((self.root / "mic-attempts").read_text(), "3")

    def test_new_retry_owner_waits_for_controller_writer_lock_handoff(self):
        session = self.session()
        session.process_window(0, 1250, 1250)
        config = self.root / "retry-config.json"
        config.write_text(json.dumps(session.config))
        marker = self.root / "entered-writer-lock"
        script = self.root / "retry-child.py"
        script.write_text(textwrap.dedent(f'''
            import importlib.util, os, pathlib, sys
            from contextlib import contextmanager
            spec = importlib.util.spec_from_file_location('recorder', {str(Path(__file__).with_name('record-call-session.py'))!r})
            recorder = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(recorder)
            original = recorder.locked
            @contextmanager
            def observed(path, blocking=False):
                pathlib.Path({str(marker)!r}).touch()
                with original(path, blocking=blocking):
                    yield
            recorder.locked = observed
            os.environ['INVOCATION_ID'] = 'synthetic-retry-handoff'
            session = recorder.Session({str(session.directory)!r}, recorder.read_json({str(config)!r}))
            raise SystemExit(session.run(retry=True))
        '''))
        child = None
        try:
            with recorder.locked(session.private / "writer.lock"):
                child = subprocess.Popen([sys.executable, str(script)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                deadline = recorder.time.monotonic() + 5
                while not marker.exists() and recorder.time.monotonic() < deadline:
                    recorder.time.sleep(0.01)
                self.assertTrue(marker.exists())
                with self.assertRaises(subprocess.TimeoutExpired):
                    child.wait(timeout=0.15)
            output, error = child.communicate(timeout=10)
            self.assertEqual(child.returncode, 0, error.decode())
            self.assertEqual(recorder.read_json(session.directory / "recording.json")["status"], "ready")
            self.assertEqual((self.root / "call-attempts").read_text(), "1")
            self.assertEqual((self.root / "mic-attempts").read_text(), "1")
            self.assertEqual(len(list((session.private / "windows").glob("*/done.json"))), 1)
        finally:
            if child is not None:
                if child.poll() is None:
                    child.kill()
                child.communicate(timeout=5)

    def test_changed_audio_after_window_commit_prevents_recovery(self):
        session = self.session()
        session.process_window(0, 1250, 1250)
        wav(session.directory / "chunks/call_000000.wav", 2000)
        with self.assertRaises(recorder.Failure) as error:
            session.finalize()
        self.assertEqual(error.exception.code, "audio_changed")
        self.assertEqual((self.root / "call-attempts").read_text(), "1")

    def test_failed_child_launch_reaps_only_children_already_acquired(self):
        unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        child = None
        try:
            with self.assertRaises(OSError):
                with recorder.owned_children() as children:
                    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
                    children.append(child)
                    raise OSError("synthetic second child launch failure")
            self.assertIsNotNone(child.poll())
            self.assertIsNone(unrelated.poll())
        finally:
            unrelated.terminate()
            unrelated.wait()

    def test_command_lock_serializes_mutating_commands(self):
        with recorder.locked(self.root / "lock"):
            with self.assertRaises(recorder.Failure) as error:
                with recorder.locked(self.root / "lock"):
                    self.fail("a second writer acquired the lock")
        self.assertEqual(error.exception.code, "recording_busy")

    def synthetic_capture(self, session, fail_loopback=False, fail_first_call=False):
        """Real child pipes/ffmpeg, fake PCM producer and fake pactl. No audio IO."""
        producer = self.root / "synthetic-pcm"
        producer.write_text(f"#!{sys.executable}\n" + textwrap.dedent(f'''
            import pathlib, sys, time
            counter = pathlib.Path({str(self.root / 'call-started')!r})
            fail = {fail_first_call!r} and '--target=31' in sys.argv and not counter.exists()
            if '--target=31' in sys.argv:
                counter.touch()
            count = 0
            while True:
                sys.stdout.buffer.write(b'\\x01\\x00' * 160)
                sys.stdout.buffer.flush()
                time.sleep(0.01)
                count += 1
                if fail and count == 20:
                    sys.exit(9)
        '''))
        producer.chmod(0o700)
        pactl = self.root / "synthetic-pactl"
        modules = self.root / "modules.json"
        modules.write_text(json.dumps([
            {"index": 11, "name": "module-null-sink", "argument": "sink_name=unrelated"},
            {"index": 12, "name": "module-loopback", "argument": "source=unrelated.monitor"}]))
        pactl.write_text(f"#!{sys.executable}\n" + textwrap.dedent(f'''
            import json, pathlib, sys
            path = pathlib.Path({str(modules)!r})
            modules = json.loads(path.read_text())
            args = sys.argv[1:]
            if args[0] == 'load-module':
                if {fail_loopback!r} and args[1] == 'module-loopback':
                    sys.exit(9)
                index = max(m['index'] for m in modules) + 1
                modules.append({{'index':index,'name':args[1],'argument':' '.join(args[2:])}})
                path.write_text(json.dumps(modules))
                print(index)
            elif args[0] == 'unload-module':
                path.write_text(json.dumps([m for m in modules if m['index'] != int(args[1])]))
            elif args[0] == 'get-default-source':
                print('fixture-mic')
            elif args[-1] == 'modules':
                print(json.dumps(modules))
            elif args[-1] == 'sources':
                sink = next(m['argument'].split()[0].split('=',1)[1] for m in modules if m['index'] > 12 and m['name'] == 'module-null-sink')
                print(json.dumps([{{'index':31,'name':sink+'.monitor'}},{{'index':32,'name':'fixture-mic'}}]))
            elif args[-1] == 'sinks':
                sink = next(m['argument'].split()[0].split('=',1)[1] for m in modules if m['index'] > 12 and m['name'] == 'module-null-sink')
                print(json.dumps([{{'index':33,'name':sink}}]))
            else:
                print('[]')
        '''))
        pactl.chmod(0o700)
        ffmpeg = shutil.which("ffmpeg")
        if ffmpeg is None:
            self.fail("Synthetic capture regression requires Nix-provided ffmpeg")
        session.config.update({"pwRecord": str(producer), "pactl": str(pactl), "ffmpeg": ffmpeg})
        session.state.update({"fragments": {side: [] for side in recorder.SIDES}, "fragmentMs": 100,
                              "runs": {side: [] for side in recorder.SIDES}, "modules": {}})
        for path in (session.directory / "chunks").iterdir():
            path.unlink()
        session.manifest["endedAt"] = None
        session.persist()

    def test_owned_capture_flushes_tail_and_leaves_unrelated_resources_alive(self):
        session = self.session()
        self.synthetic_capture(session)
        unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        timer = recorder.threading.Timer(0.65, session.stop_event.set)
        try:
            timer.start()
            session.capture()
            self.assertIsNone(unrelated.poll())
            self.assertFalse(session.captures)
            self.assertEqual([m["index"] for m in json.loads((self.root / "modules.json").read_text())], [11, 12])
            self.assertIsNotNone(session.manifest["endedAt"])
            self.assertIsNone(session.manifest["finalizedAt"])
            for side in recorder.SIDES:
                self.assertTrue(session.state["fragments"][side])
                self.assertTrue(all(Path(fragment["path"]).exists() for fragment in session.state["fragments"][side]))
            session.finalize()
            self.assertEqual(session.manifest["status"], "ready")
            self.assertTrue(session.manifest["coverage"]["complete"])
            self.assertLess(recorder.timestamp(session.manifest["endedAt"]), recorder.timestamp(session.manifest["finalizedAt"]))
        finally:
            timer.cancel()
            unrelated.terminate()
            unrelated.wait()

    def test_capture_marker_is_accepted_by_existing_diarize_and_retime_consumers(self):
        session = self.session()
        self.synthetic_capture(session)
        timer = recorder.threading.Timer(0.65, session.stop_event.set)
        try:
            timer.start()
            with patch.object(recorder, "utc_now", side_effect=[
                    "2026-10-06T15:00:00.123Z", "2026-10-06T15:00:00.773Z"]):
                session.capture()
        finally:
            timer.cancel()
        marker = (session.directory / ".started-at").read_text()
        transcript = self.root / "legacy-transcript.txt"
        transcript.write_text("[00:00:01] Synthetic call\n")
        result = subprocess.run([sys.executable, session.config["retime"], str(transcript), marker],
                                env={**os.environ, "TZ": "UTC"}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(transcript.read_text(), "[15:00:01] Synthetic call\n")
        diarization = self.root / "diarization.json"
        diarization.write_text('[{"start":0,"end":2,"speaker":"SPEAKER_00"}]')
        aligned = self.root / "aligned.txt"
        result = subprocess.run([sys.executable, session.config["align"], str(transcript), str(diarization),
                                 marker, str(aligned)], env={**os.environ, "TZ": "UTC"},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(aligned.read_text(), "[15:00:01] Speaker 1: Synthetic call\n")
        self.assertEqual(marker, "1791298800")
        self.assertEqual(session.manifest["startedAt"], "2026-10-06T15:00:00.123Z")

    def test_partial_startup_cleans_only_acquired_owned_module(self):
        session = self.session()
        self.synthetic_capture(session, fail_loopback=True)
        with patch.dict(os.environ, {"INVOCATION_ID": "synthetic-test"}):
            self.assertEqual(session.run(), 1)
        self.assertEqual(session.manifest["status"], "incomplete")
        self.assertIsNone(session.manifest["endedAt"])
        self.assertIsNone(session.manifest["finalizedAt"])
        self.assertFalse(session.manifest["failure"]["retryable"])
        self.assertEqual([m["index"] for m in json.loads((self.root / "modules.json").read_text())], [11, 12])

    def test_second_capture_launch_failure_does_not_claim_finalization_or_retry(self):
        session = self.session()
        self.synthetic_capture(session)
        original = session.launch_capture

        def launch(side):
            if side == "mic":
                raise OSError("synthetic second capture launch failure")
            original(side)

        with patch.object(session, "launch_capture", side_effect=launch), \
             patch.dict(os.environ, {"INVOCATION_ID": "synthetic-test"}):
            self.assertEqual(session.run(), 1)
        self.assertEqual(session.manifest["status"], "incomplete")
        self.assertIsNone(session.manifest["endedAt"])
        self.assertIsNone(session.manifest["finalizedAt"])
        self.assertFalse(session.manifest["failure"]["retryable"])
        self.assertFalse(session.captures)
        self.assertEqual([m["index"] for m in json.loads((self.root / "modules.json").read_text())], [11, 12])

    def test_capture_restart_retains_permanent_gap_after_successful_transcription(self):
        session = self.session()
        self.synthetic_capture(session, fail_first_call=True)
        timer = recorder.threading.Timer(1.1, session.stop_event.set)
        try:
            timer.start()
            session.capture()
            self.assertEqual(len(session.state["runs"]["call"]), 2)
            self.assertTrue(any(gap["reason"] == "capture_restarted" for gap in session.state["gaps"]))
            with self.assertRaises(recorder.Failure) as error:
                session.finalize()
            self.assertEqual(error.exception.code, "incomplete_audio_coverage")
            self.assertFalse(session.manifest["coverage"]["complete"])
            self.assertEqual((self.root / "call-attempts").read_text(), "1")
            self.assertEqual((self.root / "mic-attempts").read_text(), "1")
        finally:
            timer.cancel()

    def test_unlisted_or_partially_listed_audio_never_counts_as_finalized(self):
        session = self.session()
        original = session.state["fragments"]["call"][0]
        session.state["fragments"]["call"] = []
        listing = session.private / "closed.csv"
        session.state["runs"]["call"] = [{"list": str(listing), "offsetMs": 0, "seen": [], "index": 0}]
        listing.write_text('')
        session.collect_fragments()
        self.assertEqual(session.state["fragments"]["call"], [])
        row = f'{original["path"]},0.000000,1.250000'
        listing.write_text(row)
        session.collect_fragments()
        self.assertEqual(session.state["fragments"]["call"], [])
        listing.write_text(row + '\n')
        session.collect_fragments()
        self.assertEqual(len(session.state["fragments"]["call"]), 1)

    def test_even_short_unlisted_tail_blocks_ready(self):
        session = self.session()
        wav(session.directory / "chunks/call_000001.wav", 100)
        with self.assertRaises(recorder.Failure) as error:
            session.finalize()
        self.assertEqual(error.exception.code, "unfinalized_audio")
        self.assertNotEqual(session.manifest["status"], "ready")
        session.collect_fragments()
        self.assertEqual(len(session.state["fragments"]["call"]), 1)

    def test_no_state_stop_never_invokes_process_or_module_cleanup(self):
        with patch.object(recorder, "current_directory", return_value=None), \
             patch.object(recorder, "state_root", return_value=self.root), \
             patch.object(recorder.subprocess, "run") as command:
            recorder.stop({})
        command.assert_not_called()

    def test_ready_cleanup_and_repeated_cleanup_preserve_public_revision_and_transcript(self):
        session = self.session()
        session.finalize()
        session.state.update({"bootId": recorder.boot_id(), "invocationId": "owned-ready-cleanup",
                              "unit": "record-call-synthetic.service"})
        recorder.atomic_json(session.private / "state.json", session.state)
        public_files = [session.directory / "recording.json", *session.directory.glob("transcript*.txt")]
        before = {path.name: path.read_bytes() for path in public_files}
        owner = {"ActiveState": "deactivating", "InvocationID": "owned-ready-cleanup"}
        with patch.object(recorder, "owner_properties", return_value=owner), \
             patch.object(recorder.Session, "cleanup_modules") as cleanup, \
             patch.dict(os.environ, {"INVOCATION_ID": "owned-ready-cleanup"}):
            for attempt in range(2):
                with self.subTest(attempt=attempt):
                    recorder.cleanup_after_owner(session.directory, session.config)
                    self.assertEqual({path.name: path.read_bytes() for path in public_files}, before)
                    state = recorder.read_json(session.private / "state.json")
                    self.assertEqual(state["cleanupCompletedInvocationId"], "owned-ready-cleanup")
        self.assertEqual(cleanup.call_count, 2)

    def test_status_reports_finalization_progress_from_durable_receipts(self):
        session = self.session(duration=90000)
        session.process_window(0, 45000, 30000)
        session.manifest["status"] = "finalizing"
        session.state.update({
            "bootId": recorder.boot_id(),
            "invocationId": "progress-owner",
            "unit": "record-call-progress.service",
        })
        session.persist()
        public_before = (session.directory / "recording.json").read_bytes()
        with patch.object(recorder, "owner_properties", return_value={
                "ActiveState": "active", "InvocationID": "progress-owner"}):
            value = recorder.status(session.directory, session.config)
        self.assertEqual(value["status"], "finalizing")
        self.assertEqual(value["finalization"], {
            "completedWindows": 1,
            "totalWindows": 3,
        })
        self.assertEqual((session.directory / "recording.json").read_bytes(), public_before)

    def isolated_cli(self, config, *arguments, invocation=""):
        config_path = self.root / "cli-config.json"
        config_path.write_text(json.dumps(config))
        environment = {**os.environ, "XDG_STATE_HOME": str(self.root / "state"),
                       "XDG_RUNTIME_DIR": str(self.root / "runtime"), "INVOCATION_ID": invocation}
        return subprocess.run([sys.executable, str(Path(__file__).with_name("record-call-session.py")),
                               "--config", str(config_path), *map(str, arguments)],
                              env=environment, capture_output=True, text=True, timeout=10)

    def test_legacy_status_and_start_leave_shell_text_unevaluated_and_unchanged(self):
        legacy = self.root / "runtime/record-call/session.env"
        legacy.parent.mkdir(parents=True)
        sentinel = self.root / "must-not-execute"
        original = f"SESSION_DIR='$(touch {sentinel})'\ntouch '{sentinel}'\n".encode()
        legacy.write_bytes(original)
        result = self.isolated_cli({}, "status", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"status": "incomplete", "failure": {
            "stage": "recovery", "code": "legacy_recording_state", "retryable": False}})
        output = self.root / "new-recording"
        result = self.isolated_cli({}, "start", output)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stderr)["failure"]["code"], "recording_already_active")
        self.assertEqual(legacy.read_bytes(), original)
        self.assertFalse(sentinel.exists())
        self.assertFalse(output.exists())

    def test_stale_status_stop_and_cleanup_never_signal_unload_or_rewrite_evidence(self):
        session = self.session()
        session.manifest.update({"status": "recording", "endedAt": None, "finalizedAt": None})
        systemctl = self.root / "fixture-systemctl"
        command_log = self.root / "systemctl-calls.jsonl"
        properties = self.root / "properties.json"
        systemctl.write_text(f"#!{sys.executable}\n" + textwrap.dedent(f'''
            import json, pathlib, sys
            with pathlib.Path({str(command_log)!r}).open('a') as output:
                output.write(json.dumps(sys.argv[1:]) + '\\n')
            for key, value in json.loads(pathlib.Path({str(properties)!r}).read_text()).items():
                print(key + '=' + value)
        '''))
        systemctl.chmod(0o700)
        forbidden = self.root / "forbidden-pactl"
        sentinel = self.root / "must-not-unload"
        forbidden.write_text(f"#!{sys.executable}\nfrom pathlib import Path\nPath({str(sentinel)!r}).touch()\n")
        forbidden.chmod(0o700)
        config = {**session.config, "systemctl": str(systemctl), "pactl": str(forbidden)}
        recorder.atomic_json(self.root / "state/record-call/current.json", {"directory": str(session.directory)})
        for stale_boot, current_invocation, cleanup_invocation in (
                (True, "owner-a", "owner-a"), (False, "owner-b", "owner-a"),
                (False, "owner-b", "owner-b"), (False, "owner-b", "")):
            with self.subTest(stale_boot=stale_boot, current=current_invocation, cleanup=cleanup_invocation):
                session.state.update({"bootId": "old-boot" if stale_boot else recorder.boot_id(),
                                      "invocationId": "owner-a", "unit": "record-call-fixture.service"})
                session.persist()
                properties.write_text(json.dumps({"ActiveState": "active", "InvocationID": current_invocation}))
                before = {str(path.relative_to(session.directory)): path.read_bytes()
                          for path in session.directory.rglob("*") if path.is_file()}
                result = self.isolated_cli(config, "status", "--json")
                self.assertEqual(result.returncode, 0, result.stderr)
                value = json.loads(result.stdout)
                self.assertEqual(value["status"], "incomplete")
                self.assertIsNone(value["endedAt"])
                self.assertIsNone(value["finalizedAt"])
                self.assertFalse(value["failure"]["retryable"])
                self.assertEqual(value["failure"]["code"], "recording_owner_lost")
                for arguments, code in ((("stop",), "recording_owner_lost"),
                                        (("_cleanup", session.directory), "cleanup_owner_mismatch")):
                    result = self.isolated_cli(config, *arguments, invocation=cleanup_invocation)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertEqual(json.loads(result.stderr)["failure"]["code"], code)
                after = {str(path.relative_to(session.directory)): path.read_bytes()
                         for path in session.directory.rglob("*") if path.is_file()}
                self.assertEqual(after, before)
                self.assertFalse(sentinel.exists())
        commands = [json.loads(line) for line in command_log.read_text().splitlines()]
        self.assertEqual(commands, [["--user", "show", "record-call-fixture.service",
                                     "--property=ActiveState,InvocationID"]] * 12)

    def test_transient_unit_contains_descendants_and_never_interpolates_paths(self):
        session = self.session()
        session.config["systemdRun"] = "/synthetic/systemd-run"
        with patch.object(recorder, "state_root", return_value=self.root), \
             patch.object(recorder.subprocess, "run") as command:
            recorder.launch_unit(session, self.root / "config ' file.json", False)
        arguments = command.call_args.args[0]
        self.assertIn("--property=KillMode=control-group", arguments)
        self.assertIn("--property=UMask=0077", arguments)
        self.assertEqual(arguments[-1], str(session.directory))
        self.assertFalse(command.call_args.kwargs.get("shell", False))

    def test_widget_actual_status_handler_and_command_routing(self):
        widget = Path(__file__).parent.parent / "desktop/dms-plugins/record-call/RecordCallWidget.qml"
        script = r'''
            const fs = require('fs');
            const assert = require('assert');
            const text = fs.readFileSync(process.argv[1], 'utf8');
            const body = text.match(/onExited: \(exitCode, exitStatus\) => \{([\s\S]*?)\n        \}\n    \}/)[1];
            const status = new Function('root', 'exitCode', 'exitStatus', body);
            const toggle = new Function('root', 'toggleProc', text.match(/function toggle\(\) \{([\s\S]*?)\n    \}/)[1]);
            const startNew = new Function('root', 'toggleProc', text.match(/function startNew\(\) \{([\s\S]*?)\n    \}/)[1]);
            const rightClick = new Function('root', 'return ' + text.match(/pillRightClickAction: (.*)/)[1]);
            const tooltip = new Function('root', text.match(/function tooltipText\(\) \{([\s\S]*?)\n    \}/)[1]);
            const statusText = new Function('root', text.match(/function statusText\(\) \{([\s\S]*?)\n    \}/)[1]);
            let root = {_pollOut: JSON.stringify({status:'recording',startedAt:'2026-10-06T15:00:00Z',outputDir:'/a call'})};
            status(root, 0, 0);
            assert.strictEqual(root.phase, 'recording');
            assert.strictEqual(root.startedAt, 1791298800);
            root._pollOut = JSON.stringify({status:'finalizing',startedAt:'2026-10-06T15:00:00Z',outputDir:'/a call',
                finalization:{completedWindows:80,totalWindows:686}});
            status(root, 0, 0);
            assert.strictEqual(root.phase, 'finalizing');
            assert.strictEqual(root.completedWindows, 80);
            assert.strictEqual(root.totalWindows, 686);
            assert.strictEqual(root.finalizationPercent, 11);
            assert.strictEqual(statusText(root), 'Finalizing 11%');
            assert.strictEqual(tooltip(root), 'Finalizing transcript — 80 of 686 windows (11%)');
            let toggleProcess = {running:false};
            root.finalizing = true;
            toggle(root, toggleProcess);
            assert.strictEqual(toggleProcess.running, false);
            root._pollOut = JSON.stringify({status:'incomplete',outputDir:"/a call '; $ignored",failure:{code:'asr_exit',retryable:true}});
            status(root, 0, 0);
            root.finalizing = false;
            toggle(root, toggleProcess);
            assert.deepStrictEqual(toggleProcess.command, ['record-call','retry',"/a call '; $ignored"]);
            root.startNew = () => startNew(root, toggleProcess);
            root.failureText = () => 'Speech recognition failed';
            assert.ok(tooltip(root).includes('right-click to start another recording'));
            rightClick(root)();
            assert.deepStrictEqual(toggleProcess.command, ['record-call','start']);
            root._pollOut = '{';
            status(root, 0, 0);
            assert.strictEqual(root.phase, 'incomplete');
            assert.strictEqual(root.failureCode, 'status_unavailable');
            assert.strictEqual(root.retryable, false);
            assert.strictEqual(root.completedWindows, 0);
            assert.strictEqual(root.totalWindows, 0);
            assert.strictEqual(root.finalizationPercent, 0);
            toggleProcess = {running:false};
            toggle(root, toggleProcess);
            assert.strictEqual(toggleProcess.running, false);
            rightClick(root)();
            assert.strictEqual(toggleProcess.running, false);
            root._pollOut = JSON.stringify({status:'incomplete',failure:{code:'legacy_recording_state',retryable:false}});
            status(root, 0, 0);
            toggle(root, toggleProcess);
            assert.strictEqual(toggleProcess.running, false);
            rightClick(root)();
            assert.strictEqual(toggleProcess.running, false);
            assert.strictEqual(tooltip(root), 'An older recording needs review before a new one can start');
            root._pollOut = JSON.stringify({status:'ready'});
            status(root, 0, 0);
            root.recording = false;
            toggle(root, toggleProcess);
            assert.deepStrictEqual(toggleProcess.command, ['record-call','start']);
            root.recording = true;
            toggle(root, toggleProcess);
            assert.deepStrictEqual(toggleProcess.command, ['record-call','stop']);
            toggleProcess = {running:false};
            rightClick(root)();
            assert.strictEqual(toggleProcess.running, false);
            root.recording = false;
            root.finalizing = true;
            rightClick(root)();
            assert.strictEqual(toggleProcess.running, false);
            root.finalizing = false;
            root.toggleBusy = true;
            rightClick(root)();
            assert.strictEqual(toggleProcess.running, false);
        '''
        result = subprocess.run(["node", "-e", script, str(widget)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
