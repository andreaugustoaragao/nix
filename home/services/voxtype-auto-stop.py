#!/usr/bin/env python3
"""Auto-stop voxtype recording after a trailing silence pause following speech.

Subscribes to voxtype's 100 Hz audio-level socket ($XDG_RUNTIME_DIR/voxtype/audio.sock)
and counts actual 10 ms quiet frames received after speech has started. Disconnections
and idle gaps never count as silence.
"""

from __future__ import annotations

import argparse
import math
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import time
from typing import Callable

FRAME_STRUCT = struct.Struct("=Ifff")
FRAME_BYTES = FRAME_STRUCT.size
ACTIVE_STATES = frozenset({"recording", "streaming"})


class SilenceTracker:
    """State machine tracking speech onset and trailing silence frames."""

    def __init__(
        self,
        *,
        speech_dbfs: float = -34.0,
        resume_dbfs: float = -36.0,
        silence_dbfs: float = -40.0,
        min_speech_frames: int = 6,
        silence_frames_needed: int = 150,
    ) -> None:
        self.speech_dbfs = speech_dbfs
        self.resume_dbfs = resume_dbfs
        self.silence_dbfs = silence_dbfs
        self.min_speech_frames = min_speech_frames
        self.silence_frames_needed = silence_frames_needed
        self.reset()

    def reset(self) -> None:
        self.last_seq: int | None = None
        self.speech_frames = 0
        self.saw_speech = False
        self.quiet_frames = 0
        self.triggered = False

    def feed(self, seq: int, peak_dbfs: float) -> bool:
        if self.last_seq is not None and seq <= self.last_seq:
            self.reset()
        self.last_seq = seq

        if self.triggered or not math.isfinite(peak_dbfs):
            return False

        if not self.saw_speech:
            if peak_dbfs >= self.speech_dbfs:
                self.speech_frames += 1
                if self.speech_frames >= self.min_speech_frames:
                    self.saw_speech = True
                    self.quiet_frames = 0
            else:
                self.speech_frames = 0
            return False

        if peak_dbfs >= self.resume_dbfs:
            self.quiet_frames = 0
        elif peak_dbfs < self.silence_dbfs:
            self.quiet_frames += 1
            if self.quiet_frames >= self.silence_frames_needed:
                self.triggered = True
                return True

        return False


def is_recording_active(state_path: Path) -> bool:
    try:
        return state_path.read_text(encoding="utf-8").strip() in ACTIVE_STATES
    except OSError:
        return False


def run_stop(voxtype_bin: str) -> None:
    try:
        subprocess.run(
            [voxtype_bin, "record", "stop"],
            check=False,
            timeout=5,
            stdout=subprocess.DEVNULL,
            stderr=sys.stderr,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"voxtype-auto-stop: failed to stop recording: {exc}", file=sys.stderr)


def watch_once(
    socket_path: Path,
    state_path: Path,
    tracker: SilenceTracker,
    on_stop: Callable[[], None],
    *,
    poll_timeout: float = 0.25,
    max_triggers: int | None = None,
) -> int:
    """Connect once and process frames until EOF/error or max_triggers is reached."""
    triggers = 0
    buf = bytearray()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(poll_timeout)
        conn.connect(os.fspath(socket_path))
        while True:
            try:
                chunk = conn.recv(4096)
            except TimeoutError:
                tracker.reset()
                buf.clear()
                continue
            if not chunk:
                tracker.reset()
                return triggers
            buf.extend(chunk)
            while len(buf) >= FRAME_BYTES:
                seq, _min_s, _max_s, peak_dbfs = FRAME_STRUCT.unpack_from(buf, 0)
                del buf[:FRAME_BYTES]
                if tracker.feed(seq, peak_dbfs) and is_recording_active(state_path):
                    on_stop()
                    triggers += 1
                    if max_triggers is not None and triggers >= max_triggers:
                        return triggers


def watch_forever(
    socket_path: Path,
    state_path: Path,
    voxtype_bin: str,
    tracker: SilenceTracker,
    *,
    reconnect_delay: float = 0.25,
) -> None:
    while True:
        try:
            watch_once(
                socket_path,
                state_path,
                tracker,
                lambda: run_stop(voxtype_bin),
            )
        except OSError:
            tracker.reset()
        time.sleep(reconnect_delay)


def default_runtime_dir() -> Path:
    xdg = os.environ.get("XDG_RUNTIME_DIR")
    if xdg:
        return Path(xdg) / "voxtype"
    return Path(f"/run/user/{os.getuid()}/voxtype")


def main(argv: list[str] | None = None) -> int:
    runtime_dir = default_runtime_dir()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--voxtype-bin", default="voxtype")
    parser.add_argument("--socket", type=Path, default=runtime_dir / "audio.sock")
    parser.add_argument("--state-file", type=Path, default=runtime_dir / "state")
    parser.add_argument("--silence-ms", type=int, default=1500)
    parser.add_argument("--speech-dbfs", type=float, default=-34.0)
    parser.add_argument("--resume-dbfs", type=float, default=-36.0)
    parser.add_argument("--silence-dbfs", type=float, default=-40.0)
    parser.add_argument("--min-speech-ms", type=int, default=60)
    args = parser.parse_args(argv)

    tracker = SilenceTracker(
        speech_dbfs=args.speech_dbfs,
        resume_dbfs=args.resume_dbfs,
        silence_dbfs=args.silence_dbfs,
        min_speech_frames=max(1, round(args.min_speech_ms / 10)),
        silence_frames_needed=max(1, round(args.silence_ms / 10)),
    )
    watch_forever(args.socket, args.state_file, args.voxtype_bin, tracker)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
