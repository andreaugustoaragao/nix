"""Recorder regressions: synthetic files/processes only, never system audio."""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import shutil
import shlex
import sys
import tempfile
import textwrap
import unittest
import wave
from zoneinfo import ZoneInfo
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
        output.writeframes(b"\xe8\x03" * (milliseconds * 16))


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
        self.assertEqual(coverage["sides"]["mic"]["sampleClockShortfallMs"], 30000)
        self.assertEqual(coverage["sides"]["mic"]["missing"], [])

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

    def test_continuous_capture_shortfall_does_not_invent_a_missing_tail(self):
        # Both readers stayed active until stop. Their WAV sample clocks lagged
        # wall time after an in-call stall, so the loss cannot be placed at stop.
        duration = 2084975
        spans = {
            "call": [{"startMs": 4, "endMs": 2075587.0625}],
            "mic": [{"startMs": 19, "endMs": 2078716.6875}],
        }
        coverage = recorder.calculate_coverage(spans, spans, duration, [])
        self.assertFalse(coverage["complete"])
        for side, expected in (("call", 9387.9375), ("mic", 6258.3125)):
            self.assertEqual(coverage["sides"][side]["sampleClockShortfallMs"], expected)
            self.assertEqual(coverage["sides"][side]["missing"], [])

    def test_long_capture_drift_cannot_claim_complete_audio(self):
        duration = 20588792
        actual = {
            "call": [{"startMs": 1, "endMs": 20578176.0625}],
            "mic": [{"startMs": 4, "endMs": 20567085.6875}],
        }
        coverage = recorder.calculate_coverage(actual, actual, duration, [])
        self.assertFalse(coverage["complete"])
        self.assertEqual(coverage["sides"]["call"]["missing"], [])
        self.assertEqual(coverage["sides"]["mic"]["missing"], [])
        self.assertEqual(recorder.capture_end_tolerance(duration), recorder.EDGE_TOLERANCE_MS)

        beyond_budget = {
            "call": [{"startMs": 0, "endMs": duration}],
            "mic": [{"startMs": 0, "endMs": duration - recorder.MAX_CAPTURE_END_TOLERANCE_MS - 1}],
        }
        coverage = recorder.calculate_coverage(beyond_budget, beyond_budget, duration, [])
        self.assertFalse(coverage["complete"])
        self.assertEqual(coverage["sides"]["mic"]["missing"], [])
        self.assertEqual(coverage["sides"]["mic"]["sampleClockShortfallMs"],
                         recorder.MAX_CAPTURE_END_TOLERANCE_MS + 1)

        late_start = {
            "call": [{"startMs": 0, "endMs": duration}],
            "mic": [{"startMs": recorder.EDGE_TOLERANCE_MS + 1, "endMs": duration}],
        }
        coverage = recorder.calculate_coverage(late_start, late_start, duration, [])
        self.assertFalse(coverage["complete"])
        self.assertEqual(coverage["sides"]["mic"]["missing"][0]["reason"], "capture_started_late")

    def test_capture_end_tolerance_boundaries_do_not_weaken_other_evidence(self):
        self.assertEqual(recorder.capture_end_tolerance(60000), recorder.EDGE_TOLERANCE_MS)
        self.assertEqual(recorder.capture_end_tolerance(1000000), recorder.EDGE_TOLERANCE_MS)
        self.assertEqual(recorder.capture_end_tolerance(30000000), recorder.EDGE_TOLERANCE_MS)

        duration = 1000000
        tolerance = recorder.capture_end_tolerance(duration)
        for end in (duration - tolerance, duration + tolerance):
            with self.subTest(end=end):
                spans = {side: [{"startMs": 0, "endMs": end}] for side in recorder.SIDES}
                self.assertTrue(recorder.calculate_coverage(spans, spans, duration, [])["complete"])

        for end, reason in ((duration - tolerance - 0.0625, "sample_clock_shortfall"),
                            (duration + tolerance + 0.0625, "capture_clock_mismatch")):
            with self.subTest(end=end):
                spans = {side: [{"startMs": 0, "endMs": end}] for side in recorder.SIDES}
                coverage = recorder.calculate_coverage(spans, spans, duration, [])
                self.assertFalse(coverage["complete"])
                reasons = [item["reason"] for item in coverage["sides"]["mic"]["missing"]]
                # Neither a sample deficit of unknown location nor an
                # out-of-range clock excess is a known missing interval.
                self.assertEqual(reasons, [])
                if reason == "sample_clock_shortfall":
                    self.assertEqual(coverage["sides"]["mic"]["sampleClockShortfallMs"],
                                     tolerance + 0.0625)

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

    def test_brief_located_gaps_in_long_call_are_accepted_but_remain_visible(self):
        # A real 29-minute call had a short routing uncertainty and capture
        # clock restart during its first seven seconds. Every retained sample
        # was transcribed; the missing audio must remain visible in coverage.
        duration = 1750804
        spans = {
            "call": [{"startMs": 16, "endMs": 5220.375},
                     {"startMs": 6877, "endMs": 1750851.6875}],
            "mic": [{"startMs": 31, "endMs": 5406.0625},
                    {"startMs": 7141, "endMs": 1750026.6875}],
        }
        gaps = [
            {"side": "call", "startMs": 1651, "endMs": 2704, "reason": "routing_uncertain"},
            {"side": "call", "startMs": 6857, "endMs": 6877, "reason": "capture_restarted"},
            {"side": "mic", "startMs": 7126, "endMs": 7141, "reason": "capture_restarted"},
        ]
        coverage = recorder.calculate_coverage(spans, spans, duration, gaps)
        self.assertFalse(coverage["complete"])
        self.assertTrue(coverage["acceptedMinorGaps"])
        self.assertEqual([gap["reason"] for gap in coverage["sides"]["call"]["missing"]],
                         ["routing_uncertain", "capture_gap"])
        self.assertEqual(coverage["sides"]["mic"]["missing"][0]["reason"], "capture_gap")

    def test_minor_gap_budget_does_not_accept_substantive_or_uncertain_loss(self):
        duration = 600000
        whole = {side: [{"startMs": 0, "endMs": duration}] for side in recorder.SIDES}
        for start, end, reason in ((10000, 12001, "routing_uncertain"),
                                   (10000, 12000, "not_transcribed"),
                                   (10000, 11000, "reader_failed"),
                                   (duration + 1, duration + 2, "capture_restarted")):
            with self.subTest(start=start, end=end, reason=reason):
                coverage = recorder.calculate_coverage(whole, whole, duration, [
                    {"side": "call", "startMs": start, "endMs": end, "reason": reason}
                ])
                self.assertFalse(coverage["acceptedMinorGaps"])
        short = recorder.calculate_coverage(whole, {
            "call": whole["call"], "mic": [{"startMs": 0, "endMs": duration - 1}]
        }, duration, [{"side": "call", "startMs": 10000,
                       "endMs": 11000, "reason": "routing_uncertain"}])
        self.assertFalse(short["acceptedMinorGaps"])
        self.assertFalse(recorder.calculate_coverage(whole, whole, 60000, [
            {"side": "call", "startMs": 10000, "endMs": 11000, "reason": "routing_uncertain"}
        ])["acceptedMinorGaps"])

    def test_overlapped_fault_and_untranscribed_audio_cannot_become_minor_gaps(self):
        duration = 600000
        whole = {side: [{"startMs": 0, "endMs": duration}] for side in recorder.SIDES}
        overlapped_fault = recorder.calculate_coverage(whole, whole, duration, [
            {"side": "call", "startMs": 10000, "endMs": 11000, "reason": "routing_uncertain"},
            {"side": "call", "startMs": 10500, "endMs": 10600, "reason": "reader_failed"},
        ])
        self.assertFalse(overlapped_fault["acceptedMinorGaps"])
        shifted = {"call": [{"startMs": 500, "endMs": duration + 500}], "mic": whole["mic"]}
        overlapped_asr = recorder.calculate_coverage(whole, shifted, duration, [
            {"side": "call", "startMs": 0, "endMs": 1000, "reason": "routing_uncertain"}
        ])
        self.assertFalse(overlapped_asr["acceptedMinorGaps"])

    def test_overlapping_restart_preserves_the_measured_capture_gap(self):
        duration = 600000
        spans = {"call": [{"startMs": 0, "endMs": 10000},
                          {"startMs": 11000, "endMs": duration}],
                 "mic": [{"startMs": 0, "endMs": duration}]}
        coverage = recorder.calculate_coverage(spans, spans, duration, [
            {"side": "call", "startMs": 10900, "endMs": 11003,
             "reason": "capture_restarted"}
        ])
        self.assertTrue(coverage["acceptedMinorGaps"])
        self.assertEqual(coverage["sides"]["call"]["missing"], [
            {"startMs": 10000, "endMs": 11000, "reason": "capture_gap"},
            {"startMs": 11000, "endMs": 11003, "reason": "capture_restarted"},
        ])

    def test_adjacent_minor_gaps_cannot_hide_one_long_interruption(self):
        duration = 600000
        whole = {side: [{"startMs": 0, "endMs": duration}] for side in recorder.SIDES}
        coverage = recorder.calculate_coverage(whole, whole, duration, [
            {"side": "call", "startMs": 10000, "endMs": 11500,
             "reason": "routing_uncertain"},
            {"side": "call", "startMs": 11500, "endMs": 13000,
             "reason": "capture_restarted"},
        ])
        self.assertFalse(coverage["acceptedMinorGaps"])

    def test_missing_ranges_are_ordered_disjoint_and_bounded(self):
        spans = {side: [{"startMs": 0, "endMs": 1000}] for side in recorder.SIDES}
        done = {side: [{"startMs": 0, "endMs": 400}] for side in recorder.SIDES}
        coverage = recorder.calculate_coverage(spans, done, 1000, [
            {"side": "call", "startMs": 1400, "endMs": 1500, "reason": "segmenter_failed"},
            {"side": "call", "startMs": 600, "endMs": 800, "reason": "capture_restarted"},
        ])
        self.assertEqual(coverage["sides"]["call"]["missing"], [
            {"startMs": 400, "endMs": 1000, "reason": "not_transcribed"}])
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

    def test_audio_activity_gate_rejects_silence_and_single_spikes(self):
        silence = self.root / "silence.wav"
        with wave.open(str(silence), "wb") as output:
            output.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            output.writeframes(b"\x00\x00" * (45 * 16000))
        self.assertFalse(recorder.has_audio_activity(silence))

        spike = self.root / "spike.wav"
        with wave.open(str(spike), "wb") as output:
            output.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            output.writeframes(b"\x00\x00" * (45 * 16000 - 1) + b"\xff\x7f")
        self.assertFalse(recorder.has_audio_activity(spike))

        speech = self.root / "speech.wav"
        with wave.open(str(speech), "wb") as output:
            output.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            output.writeframes(b"\xe8\x03" * 1600 + b"\x00\x00" * (45 * 16000 - 1600))
        self.assertTrue(recorder.has_audio_activity(speech))

    def test_changed_committed_audio_is_rejected(self):
        source = self.root / "audio.wav"
        wav(source)
        fragments = [{"path": str(source), "startMs": 0, "endMs": 1000,
                      "sha256": recorder.file_hash(source)}]
        wav(source, 1500)
        with self.assertRaises(recorder.Failure):
            recorder.write_window_audio(fragments, 0, 1000, self.root / "out.wav")

    def test_fluid_diarization_response_is_strictly_normalized(self):
        session = self.session()
        source = self.root / "diarization-response.json"
        source.write_text(json.dumps({"speaker_segments": [
            {"start": 0, "end": 1.25, "speaker": " Speaker_1 ", "text": "hello"},
            {"start": 1.25, "end": 2, "speaker": "Speaker_2"},
        ]}))
        result = subprocess.run(
            [sys.executable, session.config["diarizationResponse"], str(source)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [
            {"start": 0.0, "end": 1.25, "speaker": "Speaker_1"},
            {"start": 1.25, "end": 2.0, "speaker": "Speaker_2"},
        ])

        for value in (
            {},
            {"speaker_segments": []},
            {"speaker_segments": [{"start": -1, "end": 2, "speaker": "Speaker_1"}]},
            {"speaker_segments": [{"start": 2, "end": 1, "speaker": "Speaker_1"}]},
            {"speaker_segments": [{"start": 0, "end": 0, "speaker": "Speaker_1"}]},
            {"speaker_segments": [{"start": 0, "end": 1, "speaker": ""}]},
        ):
            with self.subTest(value=value):
                source.write_text(json.dumps(value))
                result = subprocess.run(
                    [sys.executable, session.config["diarizationResponse"], str(source)],
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Invalid FluidAudio diarization response", result.stderr)

    def test_call_fragment_concatenation_handles_quoted_paths(self):
        session = self.session()
        second = session.directory / "chunks/call_000001.wav"
        wav(second, 750)
        start = session.state["fragments"]["call"][0]["endMs"]
        session.state["fragments"]["call"].append({
            "path": str(second), "startMs": start, "endMs": start + 750,
            "sha256": recorder.file_hash(second),
        })
        session.persist_state()
        output = self.root / "joined ' call.wav"
        result = subprocess.run(
            [
                sys.executable,
                session.config["concatCall"],
                str(session.directory / "chunks"),
                str(output),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(recorder.wav_duration(output), 2000)

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
            value = {{'segments': [] if mode.get('silence') else [{{'start': 0.1, 'end': 0.2,
                     'text': 'Please schedule the follow up' if side == 'mic' and mode.get('distinct_mic') else side + ' window ' + index}}]}}
            if mode.get('multiline_speech') and side == 'call':
                value['segments'][0]['text'] = 'First sentence.\\nSecond sentence.\\r\\nThird sentence.\\u2028Final sentence.'
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
        diarizer = self.root / "fake-diarizer"
        diarizer.write_text(f"#!{sys.executable}\n" + textwrap.dedent(f'''
            import json, pathlib, subprocess, sys
            root = pathlib.Path({str(self.root)!r})
            directory = pathlib.Path(sys.argv[1])
            counter = root / 'diarization-attempts'
            count = int(counter.read_text()) + 1 if counter.exists() else 1
            counter.write_text(str(count))
            mode = json.loads((root / 'control.json').read_text())
            if mode.get('diarization_corrupt_then_fail'):
                (directory / 'transcript.diarized.turns.txt').write_text('partial replacement')
                sys.exit(17)
            if not mode.get('diarization_success'):
                print('synthetic diarization failure', file=sys.stderr)
                sys.exit(17)
            lines = (directory / 'transcript.txt').read_text().splitlines()
            labeled = [
                line if '] Me: ' in line else line.replace('] ', '] Speaker 1: ', 1)
                for line in lines
            ]
            text = '\\n'.join(labeled) + ('\\n' if labeled else '')
            segments = [{{'start': 0.0, 'end': 999.0 if mode.get('diarization_invalid_timeline') else 1.0,
                         'speaker': 'Speaker_1'}}]
            if mode.get('diarization_unlabeled'):
                text = '\\n'.join(lines) + ('\\n' if lines else '')
            if mode.get('diarization_partial_labels'):
                labeled = [line if 'Later remote speech' not in line else line.replace('] Speaker 1: ', '] ', 1)
                           for line in labeled]
                text = '\\n'.join(labeled) + ('\\n' if labeled else '')
            (directory / 'diarization.response.json').write_text(json.dumps({{
                'text': text, 'speaker_segments': segments
            }}))
            (directory / 'diarization.json').write_text(json.dumps(segments))
            (directory / 'transcript.diarized.txt').write_text(text)
            subprocess.run([sys.executable, str(root / 'turns.py'),
                            str(directory / 'transcript.diarized.txt'),
                            str(directory / 'transcript.diarized.turns.txt'), '8',
                            str(directory / 'transcript.offsets.json')], check=True)
            if mode.get('diarization_truncated_turns'):
                (directory / 'transcript.diarized.turns.txt').write_text('[15:00:00] Speaker 1:\\n  Different speech\\n\\n')
        '''))
        diarizer.chmod(0o700)
        source = Path(__file__).with_name("record-call.nix").read_text()
        config = {
            "python": sys.executable,
            "curl": str(executable),
            "whisper": str(executable),
            "diarize": str(diarizer),
            "defaultDiarizationServerUrl": "http://synthetic.invalid",
            "diarizationModel": "synthetic-diarization",
        }
        helpers = {
            "merge": "record-call-merge.py",
            "diarizationResponse": "record-call-diarization-response.py",
            "concatCall": "record-call-concat.py",
            "dedupe": "record-call-dedupe.py",
            "turns": "record-call-turns.py",
            "align": "record-call-align.py",
            "retime": "record-call-retime.py",
        }
        for name, filename in helpers.items():
            begin = source.index(f'  {name}Py = pkgs.writeText "{filename}" \'\'\n')
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
        state = {"recordingId": "test-id", "fragments": fragments, "gaps": [], "advanceMs": 30000, "windowMs": 45000,
                 "fragmentMs": 5000, "turnGap": 8, "whisperServerUrl": "http://synthetic.invalid" if remote else "",
                 "diarizationServerUrl": "http://synthetic.invalid",
                 "diarizationModel": "synthetic-diarization", "finalizationStage": "capturing",
                 "diarization": {"status": "pending", "attempts": 0, "failure": None},
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

    def test_diarization_failure_is_best_effort_and_base_transcript_stays_ready(self):
        session = self.session()
        session.finalize()
        self.assertEqual(session.manifest["status"], "ready")
        self.assertEqual(session.manifest["source"]["transcript"]["path"], "transcript.turns.txt")
        self.assertEqual(session.state["diarization"]["status"], "failed")
        self.assertEqual(session.state["diarization"]["attempts"], 1)
        self.assertTrue(session.state["diarization"]["failure"]["retryable"])
        session.finalize()
        self.assertEqual((self.root / "diarization-attempts").read_text(), "1")

    def test_diarization_is_skipped_when_server_is_disabled(self):
        session = self.session()
        session.state["diarizationServerUrl"] = ""
        session.persist()
        session.finalize()
        self.assertEqual(session.manifest["status"], "ready")
        self.assertEqual(session.state["diarization"]["status"], "skipped")
        self.assertEqual(session.state["diarization"]["reason"], "disabled")
        self.assertFalse((self.root / "diarization-attempts").exists())

    def test_automatic_diarization_publishes_speaker_transcript_and_preserves_me(self):
        session = self.session()
        (self.root / "control.json").write_text('{"diarization_success":true,"distinct_mic":true}')
        session.finalize()
        self.assertEqual(session.manifest["status"], "ready")
        published = session.manifest["source"]["transcript"]["path"]
        self.assertRegex(published, r"^transcript\.diarized\.[0-9a-f]{32}\.turns\.txt$")
        self.assertEqual(session.state["diarization"]["status"], "ready")
        self.assertEqual(session.state["diarization"]["speakers"], 1)
        text = (session.directory / published).read_text()
        self.assertIn("Speaker 1:\n  call window", text)
        self.assertIn("Me:\n  Please schedule the follow up", text)

    def test_diarization_audio_preserves_capture_gap_for_speaker_alignment(self):
        session = self.session(duration=1000)
        second = session.directory / "chunks/call_000001.wav"
        wav(second, 1000)
        session.state["fragments"]["call"].append({
            "path": str(second), "startMs": 2500, "endMs": 3500,
            "sha256": recorder.file_hash(second),
        })
        session.persist_state()
        audio = self.root / "diarization-input.wav"
        subprocess.run([sys.executable, session.config["concatCall"],
                        str(session.directory / "chunks"), str(audio)], check=True)
        with wave.open(str(audio), "rb") as source:
            self.assertEqual(source.getnframes(), 56000)
            self.assertNotEqual(source.readframes(16000), b"\0" * 32000)
            self.assertEqual(source.readframes(24000), b"\0" * 48000)
            self.assertNotEqual(source.readframes(16000), b"\0" * 32000)

        segments = [{"start": 0, "end": 1, "speaker": "SPEAKER_00"},
                    {"start": 2.5, "end": 3.5, "speaker": "SPEAKER_01"}]
        (session.directory / "transcript.txt").write_text("[15:00:00] Before gap\n[15:00:03] After gap\n")
        offsets = session.directory / "transcript.offsets.json"
        recorder.atomic_json(offsets, [500, 3000])
        diarization = self.root / "segments.json"
        recorder.atomic_json(diarization, segments)
        aligned = session.directory / "transcript.diarized.txt"
        subprocess.run([sys.executable, session.config["align"], str(session.directory / "transcript.txt"),
                        str(diarization), str(int(recorder.timestamp(session.manifest["startedAt"]))),
                        str(aligned), str(offsets)], check=True, env={**os.environ, "TZ": "UTC"})
        self.assertEqual(aligned.read_text(),
                         "[15:00:00] Speaker 1: Before gap\n[15:00:03] Speaker 2: After gap\n")
        turns = session.directory / "transcript.diarized.turns.txt"
        subprocess.run([sys.executable, session.config["turns"], str(aligned), str(turns), "8", str(offsets)],
                       check=True, stdout=subprocess.DEVNULL)
        self.assertEqual(session.validate_diarization(turns, segments), 2)

    def assert_multiline_speech_retained(self, salvage):
        session = self.session()
        (self.root / 'control.json').write_text('{"multiline_speech":true}')
        if salvage:
            session.manifest['endedAt'] = None
            session.salvage_retained()
            self.assertEqual(session.manifest['status'], 'incomplete')
        else:
            session.finalize()
            self.assertEqual(session.manifest['status'], 'ready')
        raw = (session.directory / 'transcript.txt').read_text()
        self.assertIn('First sentence. Second sentence. Third sentence. Final sentence.', raw)
        self.assertEqual(len(raw.splitlines()), len(recorder.read_json(session.directory / 'transcript.offsets.json')))
        attempts = (self.root / 'call-attempts').read_text()
        session.assemble()
        self.assertEqual((self.root / 'call-attempts').read_text(), attempts)

    def test_multiline_asr_can_finalize_with_consistent_offsets(self):
        self.assert_multiline_speech_retained(False)

    def test_multiline_asr_can_salvage_with_consistent_offsets(self):
        self.assert_multiline_speech_retained(True)

    def test_assembly_keeps_exact_offset_identity_after_dedupe_in_repeated_hour(self):
        session = self.session()
        # Valid merged lines around Denver's repeated 01:30 hour. The first
        # short occurrence is a duplicate; the second belongs an hour later.
        window = session.private / 'windows/000000'
        window.mkdir(parents=True)
        text = window / 'text.txt'
        text.write_text('[01:29:59] The team will review the delivery plan on Friday.\n'
                        '[01:30:00] The team will review the delivery plan.\n'
                        '[01:30:00] The team will review the delivery plan.\n')
        offsets = window / 'offsets.json'
        recorder.atomic_json(offsets, [9000, 10000, 3610000])
        recorder.atomic_json(window / 'done.json', {
            'sha256': recorder.file_hash(text), 'offsetsSha256': recorder.file_hash(offsets)})
        session.assemble()
        self.assertEqual(recorder.read_json(session.directory / 'transcript.offsets.json'), [9000, 3610000])
        self.assertIn('[01:30:00] Them:', (session.directory / 'transcript.turns.txt').read_text())

    def public_transform(self, session, command, target):
        source = Path(__file__).with_name('record-call.nix').read_text()
        functions = []
        for name in ('transcript_offsets', 'cmd_' + command):
            body = source.split('            ' + name + '() {\n', 1)[1].split('\n            }', 1)[0]
            body = body.replace("''${", '${').replace('${dedupePy}', shlex.quote(session.config['dedupe'])).replace('${turnsPy}', shlex.quote(session.config['turns']))
            functions.append(name + '() {\n' + body + '\n}')
        script = 'set -euo pipefail\n' + '\n'.join(functions) + '\ncmd_' + command + ' "$@"'
        result = subprocess.run([shutil.which('bash'), '-c', script, '--', str(target)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_public_transforms_keep_repeated_hour_speech_and_offsets_together(self):
        session = self.session()
        transcript = session.directory / 'transcript.txt'
        transcript.write_text('[01:29:59] The team will review the delivery plan on Friday.\n'
                              '[01:30:00] The team will review the delivery plan.\n'
                              '[01:30:00] The team will review the delivery plan.\n')
        offsets = session.directory / 'transcript.offsets.json'
        recorder.atomic_json(offsets, [9000, 10000, 3610000])
        self.public_transform(session, 'dedupe', session.directory)
        self.assertEqual(recorder.read_json(offsets), [9000, 3610000])
        self.assertEqual(len(transcript.read_text().splitlines()), 2)
        self.public_transform(session, 'turns', session.directory)
        self.assertEqual((session.directory / 'transcript.turns.txt').read_text().count('Them:\n'), 2)
        aligned = session.directory / 'transcript.diarized.txt'
        aligned.write_text(transcript.read_text().replace('] ', '] Speaker 1: '))
        self.public_transform(session, 'dedupe', aligned)
        self.assertEqual(recorder.read_json(offsets), [9000, 3610000])
        self.assertEqual(recorder.read_json(session.directory / 'transcript.diarized.offsets.json'), [9000, 3610000])
        self.public_transform(session, 'turns', session.directory)
        self.assertEqual((session.directory / 'transcript.diarized.turns.txt').read_text().count('Speaker 1:\n'), 2)

    def test_diarization_retry_cannot_overwrite_published_transcript(self):
        session = self.session()
        (self.root / "control.json").write_text('{"diarization_success":true}')
        session.finalize()
        published = session.manifest["source"]["transcript"]
        snapshot = (session.directory / published["path"]).read_bytes()
        (self.root / "control.json").write_text('{"diarization_corrupt_then_fail":true}')
        self.assertFalse(session.attempt_diarization())
        self.assertEqual(session.manifest["source"]["transcript"], published)
        self.assertEqual((session.directory / published["path"]).read_bytes(), snapshot)
        self.assertEqual(recorder.file_hash(session.directory / published["path"]), published["sha256"])

    def test_legacy_stable_diarization_is_protected_before_retry(self):
        session = self.session()
        (self.root / "control.json").write_text('{"diarization_success":true}')
        session.finalize()
        stable = session.directory / "transcript.diarized.turns.txt"
        original = stable.read_bytes()
        legacy = session.transcript_descriptor(stable)
        session.manifest["source"]["transcript"] = legacy
        session.state["diarization"]["transcript"] = legacy
        session.persist()
        (self.root / "control.json").write_text('{"diarization_corrupt_then_fail":true}')
        self.assertFalse(session.attempt_diarization())
        protected = session.manifest["source"]["transcript"]
        self.assertNotEqual(protected["path"], stable.name)
        self.assertEqual((session.directory / protected["path"]).read_bytes(), original)
        self.assertEqual(recorder.file_hash(session.directory / protected["path"]), protected["sha256"])

    def test_diarization_rejects_bad_timeline_and_unlabeled_remote_speech(self):
        session = self.session()
        session.finalize()
        for defect in ("diarization_invalid_timeline", "diarization_unlabeled", "diarization_truncated_turns"):
            with self.subTest(defect=defect):
                (self.root / "control.json").write_text(json.dumps({"diarization_success": True, defect: True}))
                self.assertFalse(session.attempt_diarization())
                self.assertEqual(session.state["diarization"]["status"], "failed")
                self.assertEqual(session.manifest["source"]["transcript"]["path"], "transcript.turns.txt")

    def test_diarization_rejects_partial_remote_labels(self):
        session = self.session()
        session.finalize()
        with (session.directory / "transcript.txt").open("a") as output:
            output.write("[15:00:02] Later remote speech\n")
        offsets = session.directory / "transcript.offsets.json"
        recorder.atomic_json(offsets, recorder.read_json(offsets) + [2000])
        (self.root / "control.json").write_text('{"diarization_success":true,"diarization_partial_labels":true}')
        self.assertFalse(session.attempt_diarization())
        self.assertEqual(session.state["diarization"]["status"], "failed")

    def test_diarization_only_retry_never_replays_asr(self):
        session = self.session()
        session.finalize()
        asr_attempts = {
            side: (self.root / (side + "-attempts")).read_text()
            for side in recorder.SIDES
        }
        base_revision = session.manifest["revision"]
        (self.root / "control.json").write_text('{"diarization_success":true}')
        self.assertTrue(session.attempt_diarization())
        self.assertEqual(session.state["diarization"]["status"], "ready")
        self.assertEqual(session.state["diarization"]["attempts"], 2)
        self.assertGreater(session.manifest["revision"], base_revision)
        self.assertEqual(
            {
                side: (self.root / (side + "-attempts")).read_text()
                for side in recorder.SIDES
            },
            asr_attempts,
        )

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

    def test_silent_call_skips_server_and_retains_receipt_when_microphone_retries(self):
        session = self.session()
        fragment = session.state["fragments"]["call"][0]
        with wave.open(fragment["path"], "wb") as audio:
            audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            audio.writeframes(b"\x00\x00" * (1250 * 16))
        fragment["sha256"] = recorder.file_hash(fragment["path"])
        (self.root / "control.json").write_text('{"fail_call":99,"fail_mic":1}')
        output = io.StringIO()
        with redirect_stdout(output):
            with self.assertRaises(recorder.Failure) as error:
                session.process_window(0, 1250, 1250)
            self.assertEqual(error.exception.side, "mic")
            window = session.private / "windows/000000"
            receipt = (window / "call.ok.json").read_bytes()
            session.finalize()
            session.finalize()
        self.assertFalse((self.root / "call-attempts").exists())
        self.assertEqual((self.root / "mic-attempts").read_text(), "2")
        self.assertEqual((window / "call.ok.json").read_bytes(), receipt)
        self.assertEqual(recorder.read_json(window / "call.json"), {"segments": []})
        self.assertTrue(session.manifest["coverage"]["complete"])
        self.assertEqual(session.manifest["status"], "ready")
        self.assertNotIn("call window", (session.directory / "transcript.txt").read_text())
        events = self.asr_events(output)
        self.assertEqual([(event["side"], event["code"]) for event in events], [
            ("call", "silence"), ("mic", "asr_exit"), ("mic", "ok")])

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
             patch.object(recorder, "organize_recording", return_value=session.directory), \
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
        self.assertEqual(session.state["diarization"]["status"], "skipped")
        self.assertEqual(session.state["diarization"]["reason"], "no_speech")
        self.assertFalse((self.root / "diarization-attempts").exists())

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
            raise SystemExit(session.run(mode="retry"))
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
            completed = session.directory.with_name(session.directory.name + "-transcribed")
            self.assertEqual(recorder.read_json(completed / "recording.json")["status"], "ready")
            self.assertEqual((self.root / "call-attempts").read_text(), "1")
            self.assertEqual((self.root / "mic-attempts").read_text(), "1")
            self.assertEqual(len(list((completed / ".record-call/windows").glob("*/done.json"))), 1)
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

    def synthetic_capture(self, session, fail_loopback=False, fail_first_call=False, stall_first_call=False):
        """Real child pipes/ffmpeg, fake PCM producer and fake pactl. No audio IO."""
        producer = self.root / "synthetic-pcm"
        producer.write_text(f"#!{sys.executable}\n" + textwrap.dedent(f'''
            import pathlib, signal, sys, time
            # PipeWire 1.6.9's pw-cat returns EXIT_FAILURE unless playback
            # drained, including an intentional SIGTERM while recording.
            signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
            counter = pathlib.Path({str(self.root / 'call-started')!r})
            first_call = '--target=31' in sys.argv and not counter.exists()
            fail = {fail_first_call!r} and first_call
            stall = {stall_first_call!r} and first_call
            if '--target=31' in sys.argv:
                counter.touch()
            count = 0
            while True:
                sys.stdout.buffer.write(b'\\xe8\\x03' * 160)
                sys.stdout.buffer.flush()
                time.sleep(0.01)
                count += 1
                if fail and count == 20:
                    sys.exit(9)
                if stall and count == 20:
                    pathlib.Path({str(self.root / 'call-stalled')!r}).touch()
                    time.sleep(30)
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
            elif args == ['list', 'short', 'modules']:
                # Native modules may have multiline arguments. Only actual
                # module rows have a numeric ID and tab-separated name.
                print('1\\tlibpipewire-module-rt\\t{{\\n nice.level = -11\\n}}\\t')
                for module in modules:
                    print(str(module['index']) + '\\t' + module['name'] + '\\t' + module['argument'] + '\\t')
            elif args[-1] == 'modules':
                # The installed pactl omits module indices from JSON.
                print(json.dumps([{{k: v for k, v in m.items() if k != 'index'}} for m in modules]))
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

    def test_long_fragments_expose_live_sample_progress_before_close(self):
        session = self.session()
        self.synthetic_capture(session)
        session.state['fragmentMs'] = 30000
        session.setup_audio()
        try:
            session.launch_capture('call')
            path = session.directory / 'chunks/call_000000.wav'
            deadline = recorder.time.monotonic() + 3
            sizes = set()
            while recorder.time.monotonic() < deadline:
                sizes.add(path.stat().st_size if path.exists() else 0)
                if len([size for size in sizes if size > 78]) >= 2:
                    break
                recorder.time.sleep(0.05)
            # The watchdog must see samples during an open long fragment,
            # before FFmpeg's default 256 KiB buffer would fill after 8s.
            self.assertGreaterEqual(len([size for size in sizes if size > 78]), 2)
            self.assertIsNone(session.capture_health('call'))
        finally:
            session.stop_capture('call')
            session.cleanup_modules()

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
            self.assertFalse(session.state["gaps"])
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

    def test_owned_module_cleanup_recovers_ids_missing_from_durable_state(self):
        session = self.session()
        self.synthetic_capture(session)
        session.setup_audio()
        # Simulate a crash between module creation and persisting its ID.
        session.state['modules'] = {}
        session.cleanup_modules()
        self.assertEqual([m['index'] for m in json.loads((self.root / 'modules.json').read_text())], [11, 12])
        self.assertNotIn('cleanupWarning', session.state)

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
        transcript.write_text("[00:00:01] Synthetic call\n[00:00:01] Me: Local microphone\n")
        result = subprocess.run([sys.executable, session.config["retime"], str(transcript), marker],
                                env={**os.environ, "TZ": "UTC"}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            transcript.read_text(),
            "[15:00:01] Synthetic call\n[15:00:01] Me: Local microphone\n",
        )
        diarization = self.root / "diarization.json"
        diarization.write_text('[{"start":0,"end":2,"speaker":"SPEAKER_00"}]')
        aligned = self.root / "aligned.txt"
        result = subprocess.run([sys.executable, session.config["align"], str(transcript), str(diarization),
                                 marker, str(aligned)], env={**os.environ, "TZ": "UTC"},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            aligned.read_text(),
            "[15:00:01] Speaker 1: Synthetic call\n[15:00:01] Me: Local microphone\n",
        )
        self.assertEqual(marker, "1791298800")
        self.assertEqual(session.manifest["startedAt"], "2026-10-06T15:00:00.123Z")

    def test_diarization_alignment_survives_midnight_and_dst_fallback(self):
        session = self.session()
        zone = ZoneInfo("America/Denver")
        for start, stamps in (
            (recorder.datetime(2026, 10, 9, 23, 59, 50, tzinfo=zone), ("23:59:59", "00:00:10")),
            (recorder.datetime(2026, 11, 1, 1, 59, 50, tzinfo=zone, fold=0), ("01:59:59", "01:00:10")),
        ):
            with self.subTest(start=start):
                source = self.root / "cross-boundary.txt"
                source.write_text(f"[{stamps[0]}] Before\n[{stamps[1]}] After\n")
                segments = self.root / "cross-boundary.json"
                segments.write_text(json.dumps([
                    {"start": 8, "end": 12, "speaker": "first"},
                    {"start": 18, "end": 22, "speaker": "second"},
                ]))
                output = self.root / "cross-boundary.aligned.txt"
                result = subprocess.run([sys.executable, session.config["align"], str(source), str(segments),
                                         str(int(start.timestamp())), str(output)],
                                        env={**os.environ, "TZ": "America/Denver"},
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_text(),
                                 f"[{stamps[0]}] Speaker 1: Before\n[{stamps[1]}] Speaker 2: After\n")

    def test_elapsed_sidecar_disambiguates_repeated_dst_hour_and_turn_gaps(self):
        session = self.session()
        zone = ZoneInfo("America/Denver")
        start = recorder.datetime(2026, 11, 1, 1, 29, 50, tzinfo=zone, fold=0)
        source = self.root / "repeated-hour.txt"
        source.write_text("[01:30:00] Before\n[01:30:01] After\n")
        offsets = self.root / "repeated-hour.offsets.json"
        offsets.write_text("[10000, 3611000]")
        segments = self.root / "repeated-hour.segments.json"
        segments.write_text(json.dumps([
            {"start": 9, "end": 11, "speaker": "first"},
            {"start": 3610, "end": 3612, "speaker": "second"},
        ]))
        aligned = self.root / "repeated-hour.aligned.txt"
        result = subprocess.run([sys.executable, session.config["align"], str(source), str(segments),
                                 str(int(start.timestamp())), str(aligned), str(offsets)],
                                env={**os.environ, "TZ": "America/Denver"}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(aligned.read_text(),
                         "[01:30:00] Speaker 1: Before\n[01:30:01] Speaker 2: After\n")
        same_speaker = self.root / "repeated-hour.same-speaker.txt"
        same_speaker.write_text("[01:30:00] Speaker 1: Before\n[01:30:01] Speaker 1: After\n")
        turns = self.root / "repeated-hour.turns.txt"
        result = subprocess.run([sys.executable, session.config["turns"], str(same_speaker), str(turns),
                                 "8", str(offsets)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(turns.read_text().count("Speaker 1:"), 2)
        deduped = self.root / "repeated-hour.deduped.txt"
        deduped.write_text("[01:30:00] Repeated words\n[01:30:01] Repeated words\n")
        result = subprocess.run([sys.executable, session.config["dedupe"], str(deduped), str(offsets)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(deduped.read_text().splitlines()), 2)

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
        collect = session.collect_fragments

        def stop_after_restarted_audio():
            collect()
            runs = session.state["runs"]["call"]
            if len(runs) == 2 and any(
                fragment["startMs"] >= runs[-1]["offsetMs"]
                for fragment in session.state["fragments"]["call"]
            ):
                session.stop_event.set()

        # Stop on evidence of the restart, not on machine-dependent startup
        # timing. The timer only bounds a broken test's runtime.
        timer = recorder.threading.Timer(15, session.stop_event.set)
        try:
            timer.start()
            with patch.object(session, "collect_fragments", side_effect=stop_after_restarted_audio):
                session.capture()
            self.assertEqual(len(session.state["runs"]["call"]), 2)
            self.assertTrue(any(gap["reason"] == "capture_process_exited" for gap in session.state["gaps"]))
            with self.assertRaises(recorder.Failure) as error:
                session.finalize()
            self.assertEqual(error.exception.code, "incomplete_audio_coverage")
            self.assertFalse(session.manifest["coverage"]["complete"])
            self.assertEqual((self.root / "call-attempts").read_text(), "1")
            self.assertEqual((self.root / "mic-attempts").read_text(), "1")
        finally:
            timer.cancel()

    def test_unexpected_reader_exit_cannot_be_accepted_as_a_minor_gap(self):
        session = self.session()
        duration = 600000
        session.manifest["endedAt"] = recorder.datetime.fromtimestamp(
            recorder.timestamp(session.manifest["startedAt"]) + duration / 1000,
            recorder.timezone.utc,
        ).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        spans = {
            "call": [{"startMs": 0, "endMs": 9800},
                     {"startMs": 10050, "endMs": duration}],
            "mic": [{"startMs": 0, "endMs": duration}],
        }
        session.state["fragments"] = spans
        done = session.private / "windows" / "000000"
        done.mkdir(parents=True)
        recorder.atomic_json(done / "done.json", {"coverage": spans})
        with patch.object(session, "elapsed", side_effect=[10000, 10050]), \
             patch.object(session, "stop_capture"), \
             patch.object(session, "collect_fragments"), \
             patch.object(session, "launch_capture"):
            session.restart_capture("call", "capture_process_exited")
        self.assertEqual(session.state["gaps"][0]["reason"], "capture_process_exited")
        self.assertFalse(session.manifest["coverage"]["acceptedMinorGaps"])
        with patch.object(session, "verify_retained_audio"), \
             patch.object(session, "transcribe_retained_audio"), \
             patch.object(session, "attempt_diarization"):
            with self.assertRaises(recorder.Failure) as error:
                session.finalize()
        self.assertEqual(error.exception.code, "incomplete_audio_coverage")

    def test_retained_transcription_is_labeled_even_when_capture_coverage_fails(self):
        session = self.session()
        original = session.directory
        session.state.update({"bootId": recorder.boot_id(), "invocationId": "gap-owner",
                              "unit": "record-call-gap-owner.service", "directoryBaseName": original.name,
                              "directoryPath": str(original)})
        session.state["gaps"].append({"side": "call", "startMs": 200, "endMs": 300,
                                      "reason": "capture_process_exited"})
        session.persist_state()
        runtime = self.root / "runtime"
        runtime.mkdir()
        recorder.atomic_json(runtime / "current.json", {"recordingId": "test-id", "directory": str(original)})
        with patch.object(recorder, "state_root", return_value=runtime), \
             patch.object(session, "collect_fragments"), \
             patch.object(session, "cleanup_modules"), \
             patch.object(session, "attempt_diarization") as diarize, \
             patch.dict(os.environ, {"INVOCATION_ID": "gap-owner"}):
            self.assertEqual(session.run("retry"), 1)
            self.assertEqual(recorder.current_directory(), session.directory)
        diarize.assert_not_called()
        self.assertEqual(session.directory.name, original.name + "-transcribed")
        self.assertEqual(session.manifest["status"], "incomplete")
        self.assertEqual(session.manifest["failure"]["code"], "incomplete_audio_coverage")
        self.assertEqual(session.manifest["source"]["transcript"]["path"], "transcript.turns.txt")
        self.assertFalse(session.manifest["coverage"]["complete"])

    def test_stopped_owner_recovers_ready_cleanup_without_changing_public_revision(self):
        session = self.session()
        original = session.directory
        transcript = original / "transcript.turns.txt"
        transcript.write_text("[15:00:00] A call.\n")
        descriptor = {"path": transcript.name, "sha256": recorder.file_hash(transcript),
                      "bytes": transcript.stat().st_size, "speechTurns": 1}
        session.manifest.update({"status": "ready", "revision": 9})
        session.manifest["source"]["transcript"] = descriptor
        session.state.update({"bootId": "previous-boot", "invocationId": "crashed-owner",
                              "unit": "record-call-crashed-owner.service", "directoryBaseName": original.name,
                              "directoryPath": str(original)})
        session.persist_state()
        recorder.atomic_json(original / "recording.json", session.manifest)
        public_before = (original / "recording.json").read_bytes()
        (session.private / "writer.lock").touch()
        runtime = self.root / "runtime"
        runtime.mkdir()
        with patch.object(recorder, "state_root", return_value=runtime), \
             patch.object(recorder, "boot_id", return_value="current-boot"), \
             patch.object(recorder, "owner_properties", return_value={"ActiveState": "inactive"}), \
             patch.object(recorder.Session, "cleanup_modules") as cleanup:
            transcribed = recorder.organize_recording(original, session.config)
            self.assertEqual((transcribed / "recording.json").read_bytes(), public_before)
            self.assertEqual(recorder.read_json(transcribed / ".record-call/state.json")
                             ["cleanupCompletedInvocationId"], "crashed-owner")
            processed = recorder.organize_recording(transcribed, session.config, "test-id", 9,
                                                    descriptor["sha256"], processed=True)
        cleanup.assert_not_called()
        self.assertEqual(processed.name, original.name + "-transcribed-processed")

    def test_approved_incomplete_publication_keeps_failure_and_adds_processed(self):
        session = self.session()
        original = session.directory
        transcript = original / "transcript.turns.txt"
        transcript.write_text("[15:00:00] Retained speech.\n")
        descriptor = {"path": transcript.name, "sha256": recorder.file_hash(transcript),
                      "bytes": transcript.stat().st_size, "speechTurns": 1}
        session.manifest.update({"status": "incomplete", "revision": 9,
                                 "finalizedAt": "2026-10-12T19:07:19Z",
                                 "failure": {"stage": "capture", "code": "incomplete_audio_coverage",
                                             "retryable": False}})
        session.manifest["source"]["transcript"] = descriptor
        session.state.update({"finalizationStage": "transcribed", "invocationId": "finished",
                              "cleanupCompletedInvocationId": "finished"})
        recorder.atomic_json(original / "recording.json", session.manifest)
        session.persist_state()
        (session.private / "writer.lock").touch()
        runtime = self.root / "runtime"
        runtime.mkdir()
        with patch.object(recorder, "state_root", return_value=runtime):
            transcribed = recorder.organize_recording(original, session.config)
            processed = recorder.organize_recording(transcribed, session.config, "test-id", 9,
                                                    descriptor["sha256"], processed=True,
                                                    expected_path=descriptor["path"])
        self.assertEqual(processed.name, original.name + "-transcribed-processed")
        self.assertEqual(recorder.read_json(processed / "recording.json")["status"], "incomplete")
        self.assertEqual(recorder.read_json(processed / "recording.json")["failure"]["code"],
                         "incomplete_audio_coverage")

    def test_legacy_incomplete_transcription_receipts_allow_a_published_milestone(self):
        session = self.session()
        original = session.directory
        mic = session.state["fragments"]["mic"][0]
        wav(Path(mic["path"]), 1000)
        mic.update({"endMs": 1000, "sha256": recorder.file_hash(mic["path"])})
        session.persist_state()
        session.transcribe_retained_audio()
        session.refresh_coverage()
        self.assertEqual(session.state["finalizationStage"], "transcribing")
        self.assertEqual(session.manifest["coverage"]["sides"]["mic"]["capturedMs"], 1000)
        self.assertEqual(session.manifest["coverage"]["sides"]["mic"]["transcribedMs"], 1000)
        descriptor = session.manifest["source"]["transcript"]
        session.manifest.update({"status": "incomplete", "finalizedAt": "2026-10-12T19:07:19Z",
                                 "failure": {"stage": "capture", "code": "incomplete_audio_coverage",
                                             "retryable": False}})
        session.state.update({"invocationId": "finished", "cleanupCompletedInvocationId": "finished"})
        session.persist()
        revision = session.manifest["revision"]
        (session.private / "writer.lock").touch()
        runtime = self.root / "runtime"
        runtime.mkdir()
        with patch.object(recorder, "state_root", return_value=runtime):
            session.manifest["coverage"]["sides"]["mic"]["transcribedMs"] -= 1
            recorder.atomic_json(original / "recording.json", session.manifest)
            self.assertEqual(recorder.organize_recording(original, session.config), original)
            with self.assertRaises(recorder.Failure) as failure:
                recorder.organize_recording(original, session.config, "test-id", revision,
                                            descriptor["sha256"], processed=True)
            self.assertEqual(failure.exception.code, "transcript_not_ready")
            session.manifest["coverage"]["sides"]["mic"]["transcribedMs"] = 1000
            recorder.atomic_json(original / "recording.json", session.manifest)
            transcribed = recorder.organize_recording(original, session.config)
            processed = recorder.organize_recording(transcribed, session.config, "test-id", revision,
                                                    descriptor["sha256"], processed=True,
                                                    expected_path=descriptor["path"])
        self.assertEqual(processed.name, original.name + "-transcribed-processed")
        self.assertEqual(recorder.read_json(processed / "recording.json")["revision"], revision)

    def test_identical_text_in_a_new_diarized_artifact_revokes_processed(self):
        session = self.session()
        original = session.directory
        first = original / "transcript.diarized.0123456789abcdef0123456789abcdef.turns.txt"
        first.write_text("[15:00:00] Speaker 1: Same words.\n")
        descriptor = {"path": first.name, "sha256": recorder.file_hash(first),
                      "bytes": first.stat().st_size, "speechTurns": 1}
        session.manifest.update({"status": "ready", "revision": 5})
        session.manifest["source"]["transcript"] = descriptor
        session.state.update({"invocationId": "finished", "cleanupCompletedInvocationId": "finished"})
        recorder.atomic_json(original / "recording.json", session.manifest)
        session.persist_state()
        (session.private / "writer.lock").touch()
        runtime = self.root / "runtime"
        runtime.mkdir()
        with patch.object(recorder, "state_root", return_value=runtime):
            diarized = recorder.organize_recording(original, session.config)
            processed = recorder.organize_recording(diarized, session.config, "test-id", 5,
                                                    descriptor["sha256"], processed=True)
            second = processed / "transcript.diarized.abcdef0123456789abcdef0123456789.turns.txt"
            second.write_bytes((processed / first.name).read_bytes())
            replacement = {**descriptor, "path": second.name}
            manifest = recorder.read_json(processed / "recording.json")
            manifest["revision"] += 1
            manifest["source"]["transcript"] = replacement
            recorder.atomic_json(processed / "recording.json", manifest)
            revised = recorder.organize_recording(processed, session.config)
        self.assertEqual(revised, diarized)
        state = recorder.read_json(revised / ".record-call/state.json")
        self.assertNotIn("processedTranscriptSha", state)
        self.assertNotIn("processedTranscriptPath", state)

    def test_replacement_collision_retains_receipt_for_later_descriptor_removal(self):
        session = self.session()
        original = session.directory
        first = original / "transcript.diarized.0123456789abcdef0123456789abcdef.turns.txt"
        first.write_text("[15:00:00] Speaker 1: Same words.\n")
        descriptor = {"path": first.name, "sha256": recorder.file_hash(first),
                      "bytes": first.stat().st_size, "speechTurns": 1}
        session.manifest.update({"status": "ready", "revision": 5})
        session.manifest["source"]["transcript"] = descriptor
        session.state.update({"invocationId": "finished", "cleanupCompletedInvocationId": "finished"})
        recorder.atomic_json(original / "recording.json", session.manifest)
        session.persist_state()
        (session.private / "writer.lock").touch()
        runtime = self.root / "runtime"
        runtime.mkdir()
        with patch.object(recorder, "state_root", return_value=runtime):
            diarized = recorder.organize_recording(original, session.config)
            processed = recorder.organize_recording(diarized, session.config, "test-id", 5,
                                                    descriptor["sha256"], processed=True)
            second = processed / "transcript.diarized.abcdef0123456789abcdef0123456789.turns.txt"
            second.write_bytes((processed / first.name).read_bytes())
            changed = recorder.read_json(processed / "recording.json")
            changed["revision"] = 6
            changed["source"]["transcript"] = {**descriptor, "path": second.name}
            recorder.atomic_json(processed / "recording.json", changed)
            diarized.mkdir()
            with self.assertRaises(recorder.Failure) as collision:
                recorder.organize_recording(processed, session.config)
            self.assertEqual(collision.exception.code, "milestone_name_exists")
            pending = recorder.read_json(processed / ".record-call/state.json")
            self.assertTrue(pending["processedRevocationPending"])
            self.assertEqual(pending["processedTranscriptSha"], descriptor["sha256"])
            self.assertEqual(pending["processedTranscriptPath"], descriptor["path"])
            changed["revision"] = 7
            changed["status"] = "incomplete"
            changed["source"]["transcript"] = None
            recorder.atomic_json(processed / "recording.json", changed)
            diarized.rmdir()
            cleared = recorder.organize_recording(processed, session.config, "test-id", 7,
                                                  descriptor["sha256"], invalidate_processed=True,
                                                  expected_path=descriptor["path"])
        self.assertEqual(cleared, original)
        self.assertFalse(processed.exists())
        state = recorder.read_json(original / ".record-call/state.json")
        self.assertNotIn("processedRevocationPending", state)
        self.assertNotIn("processedTranscriptSha", state)
        self.assertNotIn("processedTranscriptPath", state)

    def test_clearing_a_changed_transcript_removes_unverified_milestones(self):
        session = self.session()
        original = session.directory
        transcript = original / "transcript.turns.txt"
        transcript.write_text("[15:00:00] Original.\n")
        descriptor = {"path": transcript.name, "sha256": recorder.file_hash(transcript),
                      "bytes": transcript.stat().st_size, "speechTurns": 1}
        session.manifest.update({"status": "ready", "revision": 5})
        session.manifest["source"]["transcript"] = descriptor
        session.state.update({"invocationId": "finished", "cleanupCompletedInvocationId": "finished"})
        recorder.atomic_json(original / "recording.json", session.manifest)
        session.persist_state()
        (session.private / "writer.lock").touch()
        runtime = self.root / "runtime"
        runtime.mkdir()
        config_path = self.root / "config.json"
        recorder.atomic_json(config_path, session.config)
        with patch.object(recorder, "state_root", return_value=runtime):
            transcribed = recorder.organize_recording(original, session.config)
            processed = recorder.organize_recording(transcribed, session.config, "test-id", 5,
                                                    descriptor["sha256"], processed=True)
            (processed / transcript.name).write_text("[15:00:00] Changed without a manifest update.\n")
            output = io.StringIO()
            with patch.object(sys, "argv", ["record-call", "--config", str(config_path), "clear-processed",
                                            str(processed), "--expected-id", "test-id", "--expected-revision", "5",
                                            "--expected-sha", descriptor["sha256"],
                                            "--expected-path", descriptor["path"]]), \
                 redirect_stdout(output):
                self.assertEqual(recorder.main(), 0)
            cleared = Path(json.loads(output.getvalue())["outputDir"])
        self.assertEqual(cleared, original)
        self.assertEqual(recorder.read_json(cleared / "recording.json")["revision"], 5)
        self.assertNotIn("processedTranscriptSha", recorder.read_json(cleared / ".record-call/state.json"))

    def test_stale_pointer_finds_base_after_committed_processed_revocation(self):
        session = self.session()
        original = session.directory
        transcript = original / "transcript.turns.txt"
        transcript.write_text("[15:00:00] Original.\n")
        descriptor = {"path": transcript.name, "sha256": recorder.file_hash(transcript),
                      "bytes": transcript.stat().st_size, "speechTurns": 1}
        session.manifest.update({"status": "ready", "revision": 5})
        session.manifest["source"]["transcript"] = descriptor
        session.state.update({"invocationId": "finished", "cleanupCompletedInvocationId": "finished"})
        recorder.atomic_json(original / "recording.json", session.manifest)
        session.persist_state()
        (session.private / "writer.lock").touch()
        runtime = self.root / "runtime"
        runtime.mkdir()
        with patch.object(recorder, "state_root", return_value=runtime):
            transcribed = recorder.organize_recording(original, session.config)
            processed = recorder.organize_recording(transcribed, session.config, "test-id", 5,
                                                    descriptor["sha256"], processed=True)
            recorder.atomic_json(runtime / "current.json", {"recordingId": "test-id",
                                                         "directory": str(processed)})
            changed = recorder.read_json(processed / "recording.json")
            changed.update({"status": "incomplete", "revision": 6,
                            "finalizedAt": "2026-10-12T19:07:19Z",
                            "failure": {"stage": "recovery", "code": "transcript_missing", "retryable": False}})
            changed["coverage"]["complete"] = False
            changed["source"]["transcript"] = None
            recorder.atomic_json(processed / "recording.json", changed)
            with self.assertRaises(recorder.Failure) as mismatch:
                recorder.organize_recording(processed, session.config, "test-id", 6,
                                            "0" * 64, invalidate_processed=True,
                                            expected_path=descriptor["path"])
            self.assertEqual(mismatch.exception.code, "recording_changed")
            real_rename = recorder.rename_noreplace

            def renamed_then_failed(*args):
                real_rename(*args)
                raise OSError("synthetic error after kernel rename")

            with patch.object(recorder, "rename_noreplace", side_effect=renamed_then_failed):
                with self.assertRaises(OSError):
                    recorder.organize_recording(processed, session.config, "test-id", 6,
                                                descriptor["sha256"], invalidate_processed=True,
                                                expected_path=descriptor["path"])
            self.assertFalse(processed.exists())
            self.assertTrue(original.is_dir())
            self.assertEqual(recorder.read_json(runtime / "current.json")["directory"], str(processed))
            self.assertEqual(recorder.current_directory(), original)
            self.assertEqual(recorder.status(recorder.current_directory(), session.config)["recordingId"], "test-id")

    def test_missing_descriptor_revocation_retries_after_target_collision(self):
        session = self.session()
        original = session.directory
        transcript = original / "transcript.turns.txt"
        transcript.write_text("[15:00:00] Original.\n")
        descriptor = {"path": transcript.name, "sha256": recorder.file_hash(transcript),
                      "bytes": transcript.stat().st_size, "speechTurns": 1}
        session.manifest.update({"status": "ready", "revision": 5})
        session.manifest["source"]["transcript"] = descriptor
        session.state.update({"invocationId": "finished", "cleanupCompletedInvocationId": "finished"})
        recorder.atomic_json(original / "recording.json", session.manifest)
        session.persist_state()
        (session.private / "writer.lock").touch()
        runtime = self.root / "runtime"
        runtime.mkdir()
        with patch.object(recorder, "state_root", return_value=runtime):
            transcribed = recorder.organize_recording(original, session.config)
            processed = recorder.organize_recording(transcribed, session.config, "test-id", 5,
                                                    descriptor["sha256"], processed=True)
            changed = recorder.read_json(processed / "recording.json")
            changed.update({"status": "incomplete", "revision": 6})
            changed["source"]["transcript"] = None
            recorder.atomic_json(processed / "recording.json", changed)
            original.mkdir()
            with self.assertRaises(recorder.Failure) as collision:
                recorder.organize_recording(processed, session.config, "test-id", 6,
                                            descriptor["sha256"], invalidate_processed=True,
                                            expected_path=descriptor["path"])
            self.assertEqual(collision.exception.code, "milestone_name_exists")
            pending = recorder.read_json(processed / ".record-call/state.json")
            self.assertTrue(pending["processedRevocationPending"])
            self.assertEqual(pending["processedTranscriptSha"], descriptor["sha256"])
            self.assertEqual(pending["processedTranscriptPath"], descriptor["path"])
            with self.assertRaises(recorder.Failure) as collision:
                recorder.organize_recording(processed, session.config)
            self.assertEqual(collision.exception.code, "milestone_name_exists")
            original.rmdir()
            cleared = recorder.organize_recording(processed, session.config, "test-id", 6,
                                                  descriptor["sha256"], invalidate_processed=True,
                                                  expected_path=descriptor["path"])
        self.assertEqual(cleared, original)
        self.assertFalse(processed.exists())
        state = recorder.read_json(original / ".record-call/state.json")
        self.assertNotIn("processedRevocationPending", state)
        self.assertNotIn("processedTranscriptSha", state)
        self.assertNotIn("processedTranscriptPath", state)

    def test_committed_descriptor_revocation_recovers_failed_final_state_write(self):
        session = self.session()
        original = session.directory
        transcript = original / "transcript.turns.txt"
        transcript.write_text("[15:00:00] Original.\n")
        descriptor = {"path": transcript.name, "sha256": recorder.file_hash(transcript),
                      "bytes": transcript.stat().st_size, "speechTurns": 1}
        session.manifest.update({"status": "ready", "revision": 5})
        session.manifest["source"]["transcript"] = descriptor
        session.state.update({"invocationId": "finished", "cleanupCompletedInvocationId": "finished"})
        recorder.atomic_json(original / "recording.json", session.manifest)
        session.persist_state()
        (session.private / "writer.lock").touch()
        runtime = self.root / "runtime"
        runtime.mkdir()
        with patch.object(recorder, "state_root", return_value=runtime):
            transcribed = recorder.organize_recording(original, session.config)
            processed = recorder.organize_recording(transcribed, session.config, "test-id", 5,
                                                    descriptor["sha256"], processed=True)
            changed = recorder.read_json(processed / "recording.json")
            changed.update({"status": "incomplete", "revision": 6})
            changed["source"]["transcript"] = None
            recorder.atomic_json(processed / "recording.json", changed)
            real_write = recorder.atomic_json_at

            def fail_final_write(directory, name, value):
                if (name == "state.json" and value.get("directoryPath") == str(original)
                        and not value.get("processedRevocationPending")):
                    raise OSError("synthetic final state write failure")
                return real_write(directory, name, value)

            with patch.object(recorder, "atomic_json_at", side_effect=fail_final_write):
                with self.assertRaises(OSError):
                    recorder.organize_recording(processed, session.config, "test-id", 6,
                                                descriptor["sha256"], invalidate_processed=True,
                                                expected_path=descriptor["path"])
            self.assertFalse(processed.exists())
            self.assertTrue(original.exists())
            pending = recorder.read_json(original / ".record-call/state.json")
            self.assertTrue(pending["processedRevocationPending"])
            self.assertEqual(pending["processedTranscriptSha"], descriptor["sha256"])
            cleared = recorder.organize_recording(original, session.config, "test-id", 6,
                                                  descriptor["sha256"], invalidate_processed=True,
                                                  expected_path=descriptor["path"])
        self.assertEqual(cleared, original)
        state = recorder.read_json(original / ".record-call/state.json")
        self.assertEqual(state["directoryPath"], str(original))
        self.assertNotIn("processedRevocationPending", state)
        self.assertNotIn("processedTranscriptSha", state)
        self.assertNotIn("processedTranscriptPath", state)

    def test_milestone_renames_wait_for_cleanup_and_preserve_current_pointer(self):
        session = self.session()
        transcript = session.directory / "transcript.diarized.0123456789abcdef0123456789abcdef.turns.txt"
        transcript.write_text("[15:00:00] Speaker 1: Finished.\n")
        descriptor = {"path": transcript.name, "sha256": recorder.file_hash(transcript),
                      "bytes": transcript.stat().st_size, "speechTurns": 1}
        session.manifest.update({"status": "ready", "revision": 7})
        session.manifest["source"]["transcript"] = descriptor
        session.state["diarization"] = {"status": "ready", "transcript": descriptor}
        session.state["finalizationStage"] = "complete"
        session.state["invocationId"] = "owned-invocation"
        listing = session.private / "call-0000.csv"
        listing.write_text("")
        session.state["runs"]["call"] = [{"list": str(listing)}]
        recorder.atomic_json(session.directory / "recording.json", session.manifest)
        recorder.atomic_json(session.private / "state.json", session.state)
        (session.private / "writer.lock").touch()
        runtime = self.root / "runtime"
        runtime.mkdir()
        recorder.atomic_json(runtime / "current.json", {
            "recordingId": "test-id", "directory": str(session.directory)})
        target = session.directory.with_name(session.directory.name + "-transcribed-diarized")
        with patch.object(recorder, "state_root", return_value=runtime), \
             patch.object(recorder, "owner_properties", return_value={"ActiveState": "inactive"}), \
             redirect_stdout(io.StringIO()):
            with self.assertRaises(recorder.Failure) as error:
                recorder.organize_recording(session.directory, session.config)
            self.assertEqual(error.exception.code, "recording_busy")
            session.state["cleanupCompletedInvocationId"] = "owned-invocation"
            recorder.atomic_json(session.private / "state.json", session.state)
            target.mkdir()
            with self.assertRaises(recorder.Failure) as error:
                recorder.organize_recording(session.directory, session.config)
            self.assertEqual(error.exception.code, "milestone_name_exists")
            self.assertTrue(session.directory.exists())
            target.rmdir()
            recorder.organize_recording(session.directory, session.config)
            self.assertFalse(session.directory.exists())
            self.assertTrue(target.exists())
            self.assertEqual(recorder.current_directory(), target)

            moved_state = recorder.read_json(target / ".record-call/state.json")
            self.assertEqual(moved_state["directoryPath"], str(target))
            self.assertTrue(all(Path(fragment["path"]).is_file()
                                for side in recorder.SIDES for fragment in moved_state["fragments"][side]))
            self.assertEqual(moved_state["runs"]["call"][0]["list"], str(target / ".record-call/call-0000.csv"))
            recorder.atomic_json(runtime / "current.json", {
                "recordingId": "test-id", "directory": str(session.directory)})
            self.assertEqual(recorder.current_directory(), target)
            processed = recorder.organize_recording(target, session.config, "test-id", 7,
                                                    descriptor["sha256"], processed=True)
            self.assertEqual(processed.name, "recording-transcribed-diarized-processed")
            self.assertTrue(processed.exists())
            self.assertFalse(target.exists())
            self.assertEqual(recorder.current_directory(), processed)
            self.assertEqual(recorder.read_json(processed / ".record-call/state.json")["processedTranscriptSha"],
                             descriptor["sha256"])
            recorder.organize_recording(processed, session.config, "test-id", 7,
                                        descriptor["sha256"], processed=True)
            self.assertTrue(processed.exists())
            self.assertEqual(recorder.read_json(runtime / "current.json")["directory"], str(processed))
            self.assertFalse(recorder.Session(processed, session.config).attempt_diarization())
            self.assertEqual(recorder.organize_recording(processed, session.config), processed)
            self.assertTrue(processed.exists())
            self.assertEqual(recorder.read_json(processed / "recording.json")["source"]["transcript"], descriptor)
            updated = processed / "transcript.diarized.abcdef0123456789abcdef0123456789.turns.txt"
            updated.write_text("[15:00:00] Speaker 2: Updated labels.\n")
            replacement = {"path": updated.name, "sha256": recorder.file_hash(updated),
                           "bytes": updated.stat().st_size, "speechTurns": 1}
            manifest = recorder.read_json(processed / "recording.json")
            manifest["revision"] += 1
            manifest["source"]["transcript"] = replacement
            recorder.atomic_json(processed / "recording.json", manifest)
            state = recorder.read_json(processed / ".record-call/state.json")
            state["diarization"] = {"status": "ready", "transcript": replacement}
            recorder.atomic_json(processed / ".record-call/state.json", state)
            revised = recorder.organize_recording(processed, session.config)
            self.assertEqual(revised, target)
            self.assertFalse(processed.exists())
            self.assertEqual(recorder.current_directory(), target)

    def test_transcribed_folder_is_visible_while_initial_diarization_runs(self):
        session = self.session()
        original = session.directory
        target = original.with_name(original.name + "-transcribed")
        session.state.update({"bootId": recorder.boot_id(), "invocationId": "initial-owner",
                              "unit": "record-call-initial.service", "directoryBaseName": original.name,
                              "directoryPath": str(original)})
        session.persist_state()
        (self.root / "control.json").write_text('{"diarization_success":true}')
        runtime = self.root / "runtime"
        runtime.mkdir()
        recorder.atomic_json(runtime / "current.json", {"recordingId": "test-id", "directory": str(original)})
        real_diarization = session.attempt_diarization

        def paused_diarization():
            self.assertFalse(original.exists())
            self.assertTrue(target.is_dir())
            self.assertEqual(session.directory, target)
            self.assertEqual(recorder.current_directory(), target)
            self.assertEqual(session.manifest["status"], "finalizing")
            self.assertEqual(recorder.read_json(target / "recording.json")["status"], "finalizing")
            self.assertTrue(all(Path(fragment["path"]).is_file()
                                for side in recorder.SIDES for fragment in session.state["fragments"][side]))
            return real_diarization()

        owner = {"ActiveState": "active", "InvocationID": "initial-owner"}
        original_organizer = recorder.organize_recording

        def checked_organization(*args, **kwargs):
            stored = recorder.read_json(original / ".record-call/state.json")
            manifest = recorder.read_json(original / "recording.json")
            self.assertEqual(stored["invocationId"], "initial-owner")
            self.assertEqual(os.environ.get("INVOCATION_ID"), "initial-owner")
            self.assertTrue(recorder.owner_matches(stored, recorder.boot_id(), owner))
            self.assertEqual(stored["finalizationStage"], "transcribed")
            self.assertEqual(manifest["status"], "finalizing")
            self.assertTrue(manifest["coverage"]["complete"] or manifest["coverage"].get("acceptedMinorGaps"))
            self.assertEqual(manifest["source"]["transcript"]["path"], "transcript.turns.txt")
            return original_organizer(*args, **kwargs)

        with patch.object(recorder, "state_root", return_value=runtime), \
             patch.object(recorder, "owner_properties", return_value=owner), \
             patch.object(recorder, "organize_recording", side_effect=checked_organization), \
             patch.object(session, "attempt_diarization", side_effect=paused_diarization), \
             patch.dict(os.environ, {"INVOCATION_ID": "initial-owner"}), \
             recorder.locked(session.private / "writer.lock"):
            session.finalize()
        self.assertEqual(session.manifest["status"], "ready")
        self.assertEqual(session.state["diarization"]["status"], "ready")
        diarized = target.with_name(target.name + "-diarized")
        # A new call may take the global pointer before ExecStopPost runs.
        recorder.atomic_json(runtime / "current.json", {"recordingId": "later", "directory": str(self.root / "later")})
        with patch.object(recorder, "state_root", return_value=runtime), \
             patch.object(recorder, "owner_properties", return_value=owner), \
             patch.object(recorder.Session, "cleanup_modules"), \
             patch.dict(os.environ, {"INVOCATION_ID": "initial-owner"}):
            recorder.cleanup_after_owner(original, session.config, "test-id")
        self.assertFalse(target.exists())
        self.assertEqual(recorder.read_json(runtime / "current.json")["recordingId"], "later")
        self.assertEqual(recorder.read_json(diarized / ".record-call/state.json")["cleanupCompletedInvocationId"],
                         "initial-owner")

    def test_post_rename_failure_keeps_one_owned_directory_and_finishes_diarization(self):
        session = self.session()
        original = session.directory
        transcribed = original.with_name(original.name + "-transcribed")
        diarized = original.with_name(original.name + "-transcribed-diarized")
        session.state.update({"bootId": recorder.boot_id(), "invocationId": "rename-owner",
                              "unit": "record-call-rename.service", "directoryBaseName": original.name,
                              "directoryPath": str(original)})
        session.persist_state()
        (self.root / "control.json").write_text('{"diarization_success":true}')
        runtime = self.root / "runtime"
        runtime.mkdir()
        recorder.atomic_json(runtime / "current.json", {"recordingId": "test-id", "directory": str(original)})
        real_rename = recorder.rename_noreplace

        def renamed_then_failed(*args):
            real_rename(*args)
            raise OSError("synthetic error after kernel rename")

        with patch.object(recorder, "state_root", return_value=runtime), \
             patch.object(recorder, "rename_noreplace", side_effect=renamed_then_failed), \
             patch.dict(os.environ, {"INVOCATION_ID": "rename-owner"}), \
             recorder.locked(session.private / "writer.lock"):
            session.finalize()
        self.assertFalse(original.exists())
        self.assertEqual(session.directory, transcribed)
        self.assertEqual(session.manifest["status"], "ready")
        self.assertEqual(session.state["diarization"]["status"], "ready")
        self.assertTrue((transcribed / session.manifest["source"]["transcript"]["path"]).is_file())
        with patch.object(recorder, "state_root", return_value=runtime), \
             patch.object(recorder, "owner_properties", return_value={"InvocationID": "rename-owner"}), \
             patch.object(recorder.Session, "cleanup_modules"), \
             patch.dict(os.environ, {"INVOCATION_ID": "rename-owner"}):
            recorder.cleanup_after_owner(original, session.config, "test-id")
        self.assertFalse(transcribed.exists())
        self.assertTrue(diarized.is_dir())
        self.assertEqual(recorder.read_json(runtime / "current.json")["directory"], str(diarized))
        self.assertEqual([path.name for path in self.root.iterdir() if (path / "recording.json").exists()],
                         [diarized.name])

    def test_stale_session_persistence_cannot_recreate_a_renamed_directory(self):
        session = self.session()
        original = session.directory
        target = original.with_name(original.name + "-transcribed")
        original.rename(target)
        for persist in (session.persist_state, session.persist):
            with self.assertRaises(recorder.Failure) as error:
                persist()
            self.assertEqual(error.exception.code, "recording_directory_changed")
        self.assertFalse(original.exists())
        self.assertTrue(target.is_dir())

    def test_transcription_and_later_diarization_have_distinct_directory_labels(self):
        session = self.session()
        text = session.directory / "transcript.turns.txt"
        text.write_text("[15:00:00] A call.\n")
        transcript = {"path": text.name, "sha256": recorder.file_hash(text),
                      "bytes": text.stat().st_size, "speechTurns": 1}
        session.manifest["status"] = "ready"
        session.manifest["source"]["transcript"] = transcript
        session.state.update({"invocationId": "finished", "cleanupCompletedInvocationId": "finished"})
        recorder.atomic_json(session.directory / "recording.json", session.manifest)
        recorder.atomic_json(session.private / "state.json", session.state)
        (session.private / "writer.lock").touch()
        runtime = self.root / "runtime"
        runtime.mkdir()
        with patch.object(recorder, "state_root", return_value=runtime):
            transcribed = recorder.organize_recording(session.directory, session.config)
            self.assertEqual(transcribed.name, "recording-transcribed")
            updated = transcribed / "transcript.diarized.0123456789abcdef0123456789abcdef.turns.txt"
            updated.write_text("[15:00:00] Speaker 1: A call.\n")
            labeled = {"path": updated.name, "sha256": recorder.file_hash(updated),
                       "bytes": updated.stat().st_size, "speechTurns": 1}
            manifest = recorder.read_json(transcribed / "recording.json")
            manifest["source"]["transcript"] = labeled
            recorder.atomic_json(transcribed / "recording.json", manifest)
            state = recorder.read_json(transcribed / ".record-call/state.json")
            state["diarization"] = {"status": "ready", "transcript": labeled}
            recorder.atomic_json(transcribed / ".record-call/state.json", state)
            diarized = recorder.organize_recording(transcribed, session.config)
            self.assertEqual(diarized.name, "recording-transcribed-diarized")
            self.assertFalse(transcribed.exists())

    def test_organization_rejects_linked_directories_and_mismatched_private_state(self):
        session = self.session()
        transcript = session.directory / "transcript.turns.txt"
        transcript.write_text("[15:00:00] A call.\n")
        session.manifest["status"] = "ready"
        session.manifest["source"]["transcript"] = {
            "path": transcript.name, "sha256": recorder.file_hash(transcript),
            "bytes": transcript.stat().st_size, "speechTurns": 1}
        session.state.update({"invocationId": "finished", "cleanupCompletedInvocationId": "finished"})
        recorder.atomic_json(session.directory / "recording.json", session.manifest)
        recorder.atomic_json(session.private / "state.json", session.state)
        (session.private / "writer.lock").touch()
        runtime = self.root / "runtime"
        with patch.object(recorder, "state_root", return_value=runtime):
            state = recorder.read_json(session.private / "state.json")
            state["recordingId"] = "another-id"
            recorder.atomic_json(session.private / "state.json", state)
            with self.assertRaises(recorder.Failure) as error:
                recorder.organize_recording(session.directory, session.config)
            self.assertEqual(error.exception.code, "recording_state_mismatch")
            recorder.atomic_json(session.private / "state.json", session.state)
            external_private = self.root / "external-private"
            session.private.rename(external_private)
            session.private.symlink_to(external_private, target_is_directory=True)
            before = (external_private / "state.json").read_bytes()
            with self.assertRaises(OSError):
                recorder.organize_recording(session.directory, session.config)
            self.assertEqual((external_private / "state.json").read_bytes(), before)
            session.private.unlink()
            external_private.rename(session.private)
            external_recording = self.root / "external-recording"
            session.directory.rename(external_recording)
            session.directory.symlink_to(external_recording, target_is_directory=True)
            with self.assertRaises(OSError):
                recorder.organize_recording(session.directory, session.config)
            self.assertTrue(external_recording.exists())

    def test_explicit_base_ending_in_a_milestone_word_recovers_a_stale_pointer(self):
        runtime = self.root / "runtime"
        for ending in ("-transcribed", "-transcribed-diarized", "-transcribed-processed",
                       "-transcribed-diarized-processed"):
            with self.subTest(ending=ending):
                session = self.session()
                original = session.directory
                base = original.with_name(original.name + ending)
                original.rename(base)
                state = recorder.read_json(base / ".record-call/state.json")
                recorder.rebase_state_paths(state, original, base)
                state.update({"directoryBaseName": base.name, "invocationId": "finished",
                              "cleanupCompletedInvocationId": "finished"})
                recorder.atomic_json(base / ".record-call/state.json", state)
                transcript = base / "transcript.turns.txt"
                transcript.write_text("[15:00:00] A call.\n")
                manifest = recorder.read_json(base / "recording.json")
                manifest["status"] = "ready"
                manifest["source"]["transcript"] = {
                    "path": transcript.name, "sha256": recorder.file_hash(transcript),
                    "bytes": transcript.stat().st_size, "speechTurns": 1}
                recorder.atomic_json(base / "recording.json", manifest)
                (base / ".record-call/writer.lock").touch()
                recorder.atomic_json(runtime / "record-call/current.json", {
                    "recordingId": "test-id", "directory": str(base)})
                with patch.object(recorder, "state_root", return_value=runtime / "record-call"):
                    target = recorder.organize_recording(base, session.config)
                    self.assertEqual(target.name, base.name + "-transcribed")
                    recorder.atomic_json(runtime / "record-call/current.json", {
                        "recordingId": "test-id", "directory": str(base)})
                    self.assertEqual(recorder.current_directory(), target)
                shutil.rmtree(target)

    def test_organization_rejects_fifo_leaves_without_waiting_for_a_writer(self):
        session = self.session()
        transcript = session.directory / "transcript.turns.txt"
        transcript.write_text("[15:00:00] A call.\n")
        session.manifest["status"] = "ready"
        session.manifest["source"]["transcript"] = {
            "path": transcript.name, "sha256": recorder.file_hash(transcript),
            "bytes": transcript.stat().st_size, "speechTurns": 1}
        session.state.update({"invocationId": "finished", "cleanupCompletedInvocationId": "finished"})
        recorder.atomic_json(session.directory / "recording.json", session.manifest)
        recorder.atomic_json(session.private / "state.json", session.state)
        (session.private / "writer.lock").touch()
        code = ("import importlib.util,sys; "
                "s=importlib.util.spec_from_file_location('recorder',sys.argv[1]); "
                "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
                "m.organize_recording(sys.argv[2],{})")
        for leaf in (session.directory / "recording.json", session.private / "state.json",
                     session.private / "writer.lock", transcript):
            with self.subTest(leaf=leaf.name):
                saved = leaf.with_name(leaf.name + ".saved")
                leaf.rename(saved)
                os.mkfifo(leaf)
                try:
                    result = subprocess.run([sys.executable, "-c", code, str(Path(recorder.__file__)),
                                             str(session.directory)],
                                            env={**os.environ, "XDG_STATE_HOME": str(self.root / "state")},
                                            capture_output=True, timeout=2)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertTrue(session.directory.exists())
                finally:
                    leaf.unlink()
                    saved.rename(leaf)

    def test_live_reader_stall_is_restarted_and_never_becomes_ready(self):
        session = self.session()
        self.synthetic_capture(session, stall_first_call=True)
        collect = session.collect_fragments

        def stop_after_recovered_audio():
            collect()
            runs = session.state["runs"]["call"]
            if len(runs) == 2 and any(
                fragment["startMs"] >= runs[-1]["offsetMs"]
                for fragment in session.state["fragments"]["call"]
            ):
                session.stop_event.set()

        timer = recorder.threading.Timer(10, session.stop_event.set)
        try:
            timer.start()
            with patch.object(recorder, "CAPTURE_STALL_SECONDS", 0.6), \
                 patch.object(session, "collect_fragments", side_effect=stop_after_recovered_audio):
                session.capture()
            self.assertTrue((self.root / "call-stalled").exists())
            self.assertEqual(len(session.state["runs"]["call"]), 2)
            self.assertTrue(any(issue["side"] == "call" and issue["code"] == "capture_stalled"
                                for issue in session.state["captureIssues"]))
            issue = next(issue for issue in session.state["captureIssues"] if issue["code"] == "capture_stalled")
            gap = next(gap for gap in session.state["gaps"] if gap["side"] == "call")
            self.assertLess(gap["startMs"], issue["atMs"])
            self.assertGreaterEqual(gap["endMs"], issue["atMs"])
            with self.assertRaises(recorder.Failure) as error:
                session.finalize()
            self.assertEqual(error.exception.code, "incomplete_audio_coverage")
        finally:
            timer.cancel()

    def test_restart_persists_suspected_stall_before_stopping_reader(self):
        session = self.session()
        session.capture_activity["call"] = {"changedAt": recorder.time.monotonic() - 0.5}
        with patch.object(session, "elapsed", return_value=1000), \
             patch.object(session, "stop_capture", side_effect=RuntimeError("reader stop failed")):
            with self.assertRaisesRegex(RuntimeError, "reader stop failed"):
                session.restart_capture("call", "capture_stalled")
        saved = recorder.read_json(session.private / "state.json")
        issue = saved["captureIssues"][-1]
        gap = saved["gaps"][-1]
        self.assertEqual(issue["code"], "capture_stalled")
        self.assertLess(gap["startMs"], issue["atMs"])
        self.assertGreaterEqual(gap["endMs"], issue["atMs"])

    def test_clock_lag_detects_loss_below_long_session_end_tolerance(self):
        duration = 4 * 60 * 60 * 1000
        retained = duration - 20000
        spans = {side: [{"startMs": 0, "endMs": retained}] for side in recorder.SIDES}
        self.assertFalse(recorder.calculate_coverage(spans, spans, duration, [])["complete"])

        session = self.session()
        session.state["runs"]["call"] = [{"offsetMs": 0}]
        path = str(session.directory / "chunks/call_000000.wav")
        session.capture_activity["call"] = {"index": 0, "bytes": 0,
                                            "changedAt": recorder.time.monotonic(),
                                            "fragmentEndMs": None, "clockAnchor": None}
        session.state["fragments"]["call"] = [{"path": path, "startMs": 0, "endMs": duration - 500}]
        with patch.object(session, "elapsed", return_value=duration):
            self.assertIsNone(session.capture_health("call"))
        session.state["fragments"]["call"].append(
            {"path": path, "startMs": duration - 500, "endMs": duration + 60000 - 3500})
        with patch.object(session, "elapsed", return_value=duration + 60000):
            self.assertEqual(session.capture_health("call"), "capture_clock_lag")

    def test_late_collection_of_closed_fragment_does_not_fake_clock_loss(self):
        session = self.session()
        path = session.directory / "chunks/call_000000.wav"
        session.state["runs"]["call"] = [{"offsetMs": 0}]
        session.state["fragments"]["call"] = [{"path": str(path), "startMs": 0, "endMs": 6000}]
        session.capture_activity["call"] = {"index": 0, "bytes": 0,
                                            "changedAt": recorder.time.monotonic(),
                                            "lastCheckedAt": recorder.time.monotonic() - 5,
                                            "fragmentEndMs": 1000, "clockAnchor": (1000, 500)}
        with patch.object(session, "elapsed", return_value=10000):
            self.assertIsNone(session.capture_health("call"))

    def test_startup_sample_pause_cannot_become_a_long_ready_recording(self):
        session = self.session()
        path = str(session.directory / "chunks/call_000000.wav")
        session.state["runs"]["call"] = [{"offsetMs": 0}]
        session.state["fragments"]["call"] = [{"path": path, "startMs": 0, "endMs": 5000}]
        session.capture_activity["call"] = {"index": 0, "bytes": 0,
                                            "changedAt": recorder.time.monotonic(),
                                            "fragmentEndMs": None, "clockAnchor": None}
        with patch.object(session, "elapsed", return_value=8000):
            self.assertEqual(session.capture_health("call"), "capture_clock_lag")

    def test_transient_browser_route_failure_does_not_end_audio_capture(self):
        session = self.session()
        self.synthetic_capture(session)
        route_calls = 0

        def route():
            nonlocal route_calls
            route_calls += 1
            if route_calls == 1:
                raise subprocess.TimeoutExpired("pactl", 5)

        timer = recorder.threading.Timer(1.4, session.stop_event.set)
        try:
            timer.start()
            with patch.object(session, "route", side_effect=route):
                session.capture()
            self.assertGreaterEqual(route_calls, 2)
            self.assertEqual(session.manifest["status"], "finalizing")
            self.assertNotIn("routingWarning", session.state)
            self.assertTrue(any(gap["side"] == "call" and gap["reason"] == "routing_uncertain"
                                for gap in session.state["gaps"]))
            self.assertFalse(session.manifest["coverage"]["complete"])
            self.assertTrue(all(session.state["fragments"][side] for side in recorder.SIDES))
        finally:
            timer.cancel()

    def test_sustained_missing_browser_stream_marks_uncertain_call_audio(self):
        session = self.session()
        with patch.object(session, "elapsed", return_value=0):
            session.observe_browser_stream(0)
        self.assertNotIn("routingWarning", session.state)
        with patch.object(session, "elapsed", return_value=11000):
            session.observe_browser_stream(0)
        self.assertEqual(session.state["routingWarning"], "browser_stream_missing")
        with patch.object(session, "elapsed", return_value=12000):
            session.observe_browser_stream(1)
        self.assertNotIn("routingWarning", session.state)
        self.assertTrue(any(gap["side"] == "call" and gap["reason"] == "routing_uncertain"
                            for gap in session.state["gaps"]))
        self.assertFalse(session.manifest["coverage"]["complete"])

    def test_changed_default_microphone_restarts_capture_and_keeps_gap(self):
        session = self.session()
        self.synthetic_capture(session)
        timer = recorder.threading.Timer(1.4, session.stop_event.set)
        try:
            timer.start()
            with patch.object(session, "default_mic_source", side_effect=[32, 99]):
                session.capture()
            self.assertEqual(session.state["sources"]["mic"], 99)
            self.assertTrue(any(issue["side"] == "mic" and issue["code"] == "microphone_source_changed"
                                for issue in session.state["captureIssues"]))
            self.assertTrue(any(gap["side"] == "mic" and gap["reason"] == "capture_restarted"
                                for gap in session.state["gaps"]))
            self.assertFalse(session.manifest["coverage"]["complete"])
        finally:
            timer.cancel()

    def test_transient_default_microphone_lookup_failure_remains_in_coverage(self):
        session = self.session()
        self.synthetic_capture(session)
        calls = 0
        def source():
            nonlocal calls
            calls += 1
            if calls == 1:
                raise subprocess.TimeoutExpired("pactl", 5)
            return 32
        timer = recorder.threading.Timer(1.4, session.stop_event.set)
        try:
            timer.start()
            with patch.object(session, "default_mic_source", side_effect=source):
                session.capture()
            self.assertGreaterEqual(calls, 2)
            self.assertNotIn("micSourceWarning", session.state)
            self.assertTrue(any(gap["side"] == "mic" and gap["reason"] == "microphone_source_uncertain"
                                for gap in session.state["gaps"]))
            self.assertFalse(session.manifest["coverage"]["complete"])
        finally:
            timer.cancel()

    def test_stop_signals_both_readers_before_waiting_for_either(self):
        session = self.session()
        events = []

        class Reader:
            def __init__(self, side):
                self.side = side
                self.stopped = False

            def poll(self):
                return -15 if self.stopped else None

            def terminate(self):
                events.append("signal-" + self.side)
                self.stopped = True

            def wait(self, timeout=None):
                events.append("wait-" + self.side)
                return -15

        class Segmenter:
            def wait(self, timeout=None):
                return 0

        def launch(side):
            session.captures[side] = (Reader(side), Segmenter())

        session.stop_event.set()
        with patch.object(session, "setup_audio"), patch.object(session, "launch_capture", side_effect=launch), \
             patch.object(session, "collect_fragments"), patch.object(session, "cleanup_modules"):
            session.capture()
        self.assertEqual(events[:2], ["signal-call", "signal-mic"])
        self.assertEqual(events[2:], ["wait-call", "wait-mic"])
        self.assertFalse(session.state["gaps"])

    def test_unexpected_reader_exit_at_stop_is_not_declared_complete(self):
        session = self.session()

        class ExitedReader:
            def poll(self):
                return 9

            def wait(self, timeout=None):
                return 9

        class Segmenter:
            def wait(self, timeout=None):
                return 0

        session.captures["call"] = (ExitedReader(), Segmenter())
        session.stop_capture("call")
        self.assertTrue(any(gap["side"] == "call" and gap["reason"] == "reader_failed"
                            for gap in session.state["gaps"]))

    def test_reader_exit_one_without_a_stop_request_is_still_a_failure(self):
        session = self.session()
        child = subprocess.Popen([sys.executable, '-c', 'raise SystemExit(1)'])
        child.wait(timeout=5)
        segmenter = subprocess.Popen([sys.executable, '-c', 'pass'])
        session.captures['call'] = (child, segmenter)
        session.stop_capture('call')
        self.assertTrue(any(gap['reason'] == 'reader_failed' for gap in session.state['gaps']))

    def test_unexpected_exit_code_after_a_stop_request_is_still_a_failure(self):
        session = self.session()
        child = subprocess.Popen([sys.executable, '-c', 'raise SystemExit(9)'])
        child.wait(timeout=5)
        segmenter = subprocess.Popen([sys.executable, '-c', 'pass'])
        session.captures['call'] = (child, segmenter)
        session.capture_stop_requested.add('call')
        session.stop_capture('call')
        self.assertTrue(any(gap['reason'] == 'reader_failed' for gap in session.state['gaps']))

    def test_unknown_end_salvages_closed_audio_without_claiming_complete_capture(self):
        session = self.session()
        session.manifest.update({"status": "incomplete", "endedAt": None, "finalizedAt": None,
                                 "failure": {"stage": "recovery", "code": "capture_end_unknown", "retryable": False}})
        session.persist()
        unlisted = session.directory / "chunks/call_000001.wav"
        wav(unlisted, 200)
        unlisted_hash = recorder.file_hash(unlisted)

        session.salvage_retained()
        self.assertEqual(session.manifest["status"], "incomplete")
        self.assertEqual(session.manifest["failure"]["code"], "capture_end_unknown")
        self.assertIsNone(session.manifest["endedAt"])
        self.assertIsNone(session.manifest["finalizedAt"])
        self.assertFalse(session.manifest["coverage"]["complete"])
        self.assertTrue(session.manifest["coverage"]["captureEndUnknown"])
        self.assertEqual(session.manifest["coverage"]["sides"]["call"]["capturedMs"], 1250)
        self.assertEqual(session.manifest["coverage"]["sides"]["call"]["transcribedMs"], 1250)
        self.assertGreater(session.manifest["source"]["transcript"]["speechTurns"], 0)
        self.assertEqual(recorder.file_hash(unlisted), unlisted_hash)
        self.assertEqual((self.root / "call-attempts").read_text(), "1")
        session.salvage_retained()
        self.assertEqual((self.root / "call-attempts").read_text(), "1")
        self.assertFalse(recorder.status(session.directory, session.config)["salvageable"])

    def test_unknown_end_without_closed_audio_refuses_salvage(self):
        session = self.session()
        session.manifest["endedAt"] = None
        session.state["fragments"] = {side: [] for side in recorder.SIDES}
        with self.assertRaises(recorder.Failure) as error:
            session.salvage_retained()
        self.assertEqual(error.exception.code, "no_retained_audio")

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

    def test_public_salvage_accepts_a_closed_receipt_before_its_first_state_snapshot(self):
        session = self.session()
        original = session.state['fragments']['call'][0]
        session.manifest.update(status='incomplete', endedAt=None)
        session.state['fragments'] = {side: [] for side in recorder.SIDES}
        listing = session.private / 'call-0000.csv'
        session.state['runs']['call'] = [{'list': str(listing), 'offsetMs': 0, 'seen': [], 'index': 0}]
        listing.write_text(f'{original["path"]},0.000000,1.250000\n')
        session.persist()
        before = (session.private / 'state.json').read_bytes()
        self.assertTrue(recorder.status(session.directory, session.config)['salvageable'])
        self.assertEqual((session.private / 'state.json').read_bytes(), before)
        with patch.object(recorder, 'state_root', return_value=self.root), \
             patch.object(recorder, 'current_directory', return_value=None), \
             patch.object(recorder, 'owner_properties', return_value={'ActiveState': 'inactive'}), \
             patch.object(recorder, 'launch_unit') as launch:
            recorder.salvage(session.directory, session.config, self.root / 'config.json')
        self.assertEqual(launch.call_args.args[2], 'salvage')
        # The worker, after ownership handoff, reconciles before transcription.
        with recorder.locked(session.private / 'writer.lock'):
            session.collect_fragments()
            session.salvage_retained()
        self.assertEqual(session.manifest['status'], 'incomplete')
        self.assertIsNone(session.manifest['endedAt'])
        self.assertGreater(session.manifest['source']['transcript']['speechTurns'], 0)

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
        (self.root / "control.json").write_text('{"diarization_success":true}')
        session.finalize()
        self.assertEqual(session.state["diarization"]["status"], "ready")
        session.state.update({"bootId": recorder.boot_id(), "invocationId": "owned-ready-cleanup",
                              "unit": "record-call-synthetic.service"})
        recorder.atomic_json(session.private / "state.json", session.state)
        public_files = [session.directory / "recording.json", *session.directory.glob("transcript*.txt")]
        before = {path.name: path.read_bytes() for path in public_files}
        runtime = self.root / "runtime"
        runtime.mkdir()
        recorder.atomic_json(runtime / "current.json", {
            "recordingId": "test-id", "directory": str(session.directory)})
        organized = session.directory.with_name(session.directory.name + "-transcribed-diarized")
        owner = {"ActiveState": "deactivating", "InvocationID": "owned-ready-cleanup"}
        with patch.object(recorder, "owner_properties", return_value=owner), \
             patch.object(recorder, "state_root", return_value=runtime), \
             patch.object(recorder.Session, "cleanup_modules") as cleanup, \
             patch.dict(os.environ, {"INVOCATION_ID": "owned-ready-cleanup"}):
            for attempt in range(2):
                with self.subTest(attempt=attempt):
                    recorder.cleanup_after_owner(session.directory if attempt == 0 else organized, session.config)
                    self.assertEqual({name: (organized / name).read_bytes() for name in before}, before)
                    state = recorder.read_json(organized / ".record-call/state.json")
                    self.assertEqual(state["cleanupCompletedInvocationId"], "owned-ready-cleanup")
                    self.assertEqual(recorder.current_directory(), organized)
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
            "stage": "capturing",
        })
        self.assertEqual((session.directory / "recording.json").read_bytes(), public_before)

    def test_status_tracks_diarization_owner_without_revoking_ready_transcript(self):
        session = self.session()
        session.finalize()
        session.state.update({
            "bootId": recorder.boot_id(),
            "invocationId": "diarization-owner",
            "unit": "record-call-diarization.service",
            "diarization": {
                "status": "running",
                "attempts": 2,
                "startedAt": recorder.utc_now(),
                "finishedAt": None,
                "failure": None,
            },
        })
        session.persist_state()
        public_before = (session.directory / "recording.json").read_bytes()
        with patch.object(recorder, "owner_properties", return_value={
                "ActiveState": "active", "InvocationID": "diarization-owner"}):
            value = recorder.status(session.directory, session.config)
        self.assertEqual(value["status"], "diarizing")
        self.assertEqual(value["diarization"]["status"], "running")

        with patch.object(recorder, "owner_properties", return_value={
                "ActiveState": "inactive", "InvocationID": ""}):
            value = recorder.status(session.directory, session.config)
        self.assertEqual(value["status"], "ready")
        self.assertEqual(value["diarization"]["status"], "failed")
        self.assertEqual(value["diarization"]["failure"]["code"], "diarization_owner_lost")
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
            recorder.launch_unit(session, self.root / "config ' file.json", "capture")
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
            root._pollOut = JSON.stringify({status:'recording',startedAt:'2026-10-06T15:00:00Z',
                captureIssues:[{side:'call',code:'capture_stalled',atMs:90000}],routingWarning:'routing_unavailable'});
            status(root, 0, 0);
            root.recording = true;
            root.elapsedText = () => '01:30';
            assert.strictEqual(root.captureIssueSides, 'call');
            assert.ok(tooltip(root).includes('audio capture was interrupted on call'));
            root.recording = false;
            let toggleProcess = {running:false};
            root.finalizing = true;
            toggle(root, toggleProcess);
            assert.strictEqual(toggleProcess.running, false);
            root._pollOut = JSON.stringify({status:'finalizing',outputDir:'/a call',
                finalization:{completedWindows:686,totalWindows:686,stage:'diarizing'},
                diarization:{status:'running',attempts:1}});
            status(root, 0, 0);
            assert.strictEqual(root.phase, 'diarizing');
            assert.strictEqual(root.diarizationStatus, 'running');
            assert.strictEqual(statusText(root), 'Diarizing');
            assert.strictEqual(tooltip(root), 'Identifying call participants...');
            root._pollOut = JSON.stringify({status:'incomplete',outputDir:"/a call '; $ignored",failure:{code:'asr_exit',retryable:true}});
            status(root, 0, 0);
            root.finalizing = false;
            toggle(root, toggleProcess);
            assert.deepStrictEqual(toggleProcess.command, ['record-call','retry',"/a call '; $ignored"]);
            root.startNew = () => startNew(root, toggleProcess);
            root.failureText = () => 'Speech recognition failed';
            assert.ok(tooltip(root).includes('right-click to start another recording'));
            root._pollOut = JSON.stringify({status:'incomplete',outputDir:'/retained recording',salvageable:true,
                failure:{code:'capture_end_unknown',retryable:false}});
            status(root, 0, 0);
            toggleProcess = {running:false};
            toggle(root, toggleProcess);
            assert.deepStrictEqual(toggleProcess.command, ['record-call','salvage','/retained recording']);
            assert.ok(tooltip(root).includes('partial transcript'));
            root._pollOut = JSON.stringify({status:'incomplete',failure:{code:'incomplete_audio_coverage',retryable:false},
                coverage:{sides:{call:{sampleClockShortfallMs:9387.9375},mic:{sampleClockShortfallMs:6258.3125}}}});
            status(root, 0, 0);
            assert.ok(tooltip(root).includes('call 9.4 s, mic 6.3 s'));
            assert.ok(tooltip(root).includes('position in the call is unknown'));
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
            root._pollOut = JSON.stringify({status:'ready',outputDir:"/a call '; $ignored",
                diarization:{status:'failed',attempts:1,failure:{code:'diarization_failed',retryable:true}}});
            status(root, 0, 0);
            root.recording = false;
            root.finalizing = false;
            toggleProcess = {running:false};
            toggle(root, toggleProcess);
            assert.deepStrictEqual(toggleProcess.command, ['record-call','retry-diarization',"/a call '; $ignored"]);
            assert.ok(tooltip(root).includes('participant labeling failed'));
            root.startNew = () => startNew(root, toggleProcess);
            rightClick(root)();
            assert.deepStrictEqual(toggleProcess.command, ['record-call','start']);
            root._pollOut = JSON.stringify({status:'ready'});
            status(root, 0, 0);
            root.recording = false;
            root._pollOut = JSON.stringify({status:'ready',coverage:{acceptedMinorGaps:true}});
            status(root, 0, 0);
            assert.strictEqual(root.minorGaps, true);
            assert.ok(tooltip(root).includes('Brief audio gaps were recorded'));
            root._pollOut = JSON.stringify({status:'ready'});
            status(root, 0, 0);
            assert.strictEqual(root.minorGaps, false);
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
