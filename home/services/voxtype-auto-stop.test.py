#!/usr/bin/env python3
"""Unit tests for voxtype-auto-stop."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import socket
import sys
import tempfile
import threading
import unittest

MOD_PATH = Path(__file__).with_name("voxtype-auto-stop.py")
SPEC = importlib.util.spec_from_file_location("voxtype_auto_stop", MOD_PATH)
assert SPEC is not None and SPEC.loader is not None
MOD = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MOD
SPEC.loader.exec_module(MOD)


def pack_frames(levels: list[float], start_seq: int = 0) -> bytes:
    return b"".join(
        MOD.FRAME_STRUCT.pack(start_seq + idx, -0.1, 0.1, level)
        for idx, level in enumerate(levels)
    )


class SilenceTrackerTests(unittest.TestCase):
    def test_pre_speech_silence_and_single_key_click_do_not_trigger(self) -> None:
        tracker = MOD.SilenceTracker(min_speech_frames=6, silence_frames_needed=150)
        # 2.5s quiet, 20ms key click, then another 2.5s quiet: never armed.
        levels = [-60.0] * 250 + [-20.0, -22.0] + [-60.0] * 250
        triggered = [tracker.feed(i, lvl) for i, lvl in enumerate(levels)]
        self.assertFalse(any(triggered))

    def test_speech_then_trailing_silence_triggers_once(self) -> None:
        tracker = MOD.SilenceTracker(min_speech_frames=6, silence_frames_needed=150)
        levels = [-20.0] * 20 + [-60.0] * 200
        triggers = [i for i, lvl in enumerate(levels) if tracker.feed(i, lvl)]
        self.assertEqual(triggers, [20 + 150 - 1])

    def test_short_mid_sentence_pause_resets_counter(self) -> None:
        tracker = MOD.SilenceTracker(min_speech_frames=6, silence_frames_needed=150)
        levels = (
            [-20.0] * 20
            + [-60.0] * 100  # 1.0s pause: too short
            + [-25.0] * 10   # resumes speaking
            + [-60.0] * 150  # 1.5s pause: triggers here
        )
        triggers = [i for i, lvl in enumerate(levels) if tracker.feed(i, lvl)]
        self.assertEqual(triggers, [len(levels) - 1])

    def test_seq_reset_starts_new_recording_session(self) -> None:
        tracker = MOD.SilenceTracker(min_speech_frames=6, silence_frames_needed=10)
        first = [-20.0] * 10 + [-60.0] * 12
        second = [-20.0] * 8 + [-60.0] * 12
        self.assertTrue(any(tracker.feed(i, lvl) for i, lvl in enumerate(first)))
        self.assertTrue(any(tracker.feed(i, lvl) for i, lvl in enumerate(second)))


class SocketWatcherTests(unittest.TestCase):
    def test_disconnect_never_counts_as_silence(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            sock_path = Path(tmp) / "audio.sock"
            state_path = Path(tmp) / "state"
            state_path.write_text("recording\n", encoding="utf-8")

            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(sock_path))
            server.listen(1)

            def serve() -> None:
                conn, _ = server.accept()
                # Send speech + partial quiet (100 < 150), then drop connection.
                payload = pack_frames([-20.0] * 10 + [-60.0] * 100)
                conn.sendall(payload)
                conn.close()
                server.close()

            t = threading.Thread(target=serve, daemon=True)
            t.start()
            stops = 0
            tracker = MOD.SilenceTracker(min_speech_frames=6, silence_frames_needed=150)
            triggers = MOD.watch_once(
                sock_path,
                state_path,
                tracker,
                lambda: (_ for _ in ()).throw(AssertionError("unexpected stop")),
                poll_timeout=0.05,
            )
            t.join(timeout=2)
            self.assertEqual(triggers, 0)
            self.assertEqual(stops, 0)
            self.assertFalse(tracker.saw_speech)

    def test_partial_reads_and_active_state_trigger_stop(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            sock_path = Path(tmp) / "audio.sock"
            state_path = Path(tmp) / "state"
            state_path.write_text("recording\n", encoding="utf-8")

            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(sock_path))
            server.listen(1)

            payload = pack_frames([-20.0] * 10 + [-60.0] * 160)

            def serve() -> None:
                conn, _ = server.accept()
                # Send misaligned chunks to exercise frame reassembly.
                for idx in range(0, len(payload), 7):
                    conn.sendall(payload[idx : idx + 7])
                conn.close()
                server.close()

            t = threading.Thread(target=serve, daemon=True)
            t.start()
            stops: list[str] = []
            tracker = MOD.SilenceTracker(min_speech_frames=6, silence_frames_needed=150)
            triggers = MOD.watch_once(
                sock_path,
                state_path,
                tracker,
                lambda: stops.append("stop"),
                poll_timeout=0.05,
            )
            t.join(timeout=2)
            self.assertEqual(triggers, 1)
            self.assertEqual(stops, ["stop"])

    def test_idle_state_suppresses_stop_command(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            sock_path = Path(tmp) / "audio.sock"
            state_path = Path(tmp) / "state"
            state_path.write_text("idle\n", encoding="utf-8")

            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(sock_path))
            server.listen(1)

            def serve() -> None:
                conn, _ = server.accept()
                conn.sendall(pack_frames([-20.0] * 10 + [-60.0] * 160))
                conn.close()
                server.close()

            t = threading.Thread(target=serve, daemon=True)
            t.start()
            tracker = MOD.SilenceTracker(min_speech_frames=6, silence_frames_needed=150)
            triggers = MOD.watch_once(
                sock_path,
                state_path,
                tracker,
                lambda: (_ for _ in ()).throw(AssertionError("should not stop when idle")),
                poll_timeout=0.05,
            )
            t.join(timeout=2)
            self.assertEqual(triggers, 0)


if __name__ == "__main__":
    unittest.main()
