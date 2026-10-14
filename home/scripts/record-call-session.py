"""Owned record-call lifecycle. Only finalized, verified audio can become READY.

The public recording.json is an intake contract. Private state and immutable
window receipts live under .record-call. No shell state file is ever evaluated.
"""
import argparse
import array
import ctypes
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager, nullcontext
import csv
from datetime import datetime, timezone
import fcntl
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import wave
from zoneinfo import ZoneInfo, available_timezones

SIDES = ("call", "mic")
ACTIVE = ("starting", "recording", "finalizing", "diarizing")
EDGE_TOLERANCE_MS = 1000
MIN_MINOR_GAP_DURATION_MS = 5 * 60 * 1000
MAX_MINOR_GAP_MS = 2000
MAX_MINOR_GAPS_PER_SIDE_MS = 5000
MAX_MINOR_GAP_FRACTION = 0.005
MINOR_GAP_REASONS = frozenset((
    "capture_gap", "capture_restarted", "routing_uncertain", "microphone_source_uncertain",
))
MAX_CAPTURE_CLOCK_DRIFT_PPM = 1500
MAX_CAPTURE_END_TOLERANCE_MS = 30000
CAPTURE_STALL_SECONDS = 8
CAPTURE_CLOCK_SLACK_MS = 1500


class Failure(Exception):
    def __init__(self, stage, code, retryable=True, side=None, window=None):
        super().__init__(code)
        self.stage, self.code, self.retryable = stage, code, retryable
        self.side, self.window = side, window

    def public(self):
        result = {"stage": self.stage, "code": self.code, "retryable": self.retryable}
        if self.side is not None:
            result["side"] = self.side
        if self.window is not None:
            result["windowIndex"] = self.window
        return result


class DiarizationCoverageError(ValueError):
    def __init__(self, unlabeled, total):
        super().__init__(f"{unlabeled} of {total} remote speech lines have no speaker label")
        self.unlabeled, self.total = unlabeled, total


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def timestamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def boot_id():
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def capture_zone():
    candidates = [os.environ.get("TZ", "")]
    localtime = str(Path("/etc/localtime").resolve())
    if "/zoneinfo/" in localtime:
        candidates.append(localtime.split("/zoneinfo/", 1)[1])
    for candidate in candidates:
        if candidate and not candidate.startswith(("/", ":")):
            try:
                ZoneInfo(candidate)
                return candidate
            except (ValueError, KeyError):
                pass
    raise Failure("startup", "timezone_unavailable", False)


def read_json(path):
    with Path(path).open() as source:
        return json.load(source)


def atomic_bytes(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def atomic_json(path, data):
    atomic_bytes(path, (json.dumps(data, ensure_ascii=False, allow_nan=False) + "\n").encode())


def file_hash(path):
    with Path(path).open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


@contextmanager
def locked(path, blocking=False):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.open("a+") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError:
            raise Failure("recovery", "recording_busy") from None
        yield


def number(value):
    return isinstance(value, (float, int)) and not isinstance(value, bool) and math.isfinite(value)


def capture_end_tolerance(duration_ms):
    # The consumer's READY contract allows only a one-second edge difference.
    # A larger deficit may be clock drift or missing speech; neither is proven
    # complete from sample counts alone.
    return EDGE_TOLERANCE_MS


def validate_asr(path, duration_ms=None):
    try:
        data = read_json(path)
        if not isinstance(data, dict) or "error" in data:
            raise ValueError()
        key = "transcription" if "transcription" in data else "segments"
        segments = data[key]
        if not isinstance(segments, list):
            raise ValueError()
        spoken = 0
        for segment in segments:
            if key == "transcription":
                start, end = segment["offsets"]["from"], segment["offsets"]["to"]
            else:
                start, end = segment["start"], segment["end"]
            if not number(start) or not number(end) or start < 0 or end < start:
                raise ValueError()
            if duration_ms is not None:
                multiplier = 1 if key == "transcription" else 1000
                # Whisper may place a trailing padding segment just after the
                # audio ends. Apply the existing timing tolerance to both
                # bounds; the merger still excludes text outside emitted audio.
                if end * multiplier > duration_ms + 1000:
                    raise ValueError()
            text = segment["text"]
            if not isinstance(text, str):
                raise ValueError()
            spoken += bool(text.strip())
        return spoken
    except (OSError, ValueError, TypeError, KeyError):
        raise Failure("transcription", "invalid_asr_output") from None


def wav_duration(path):
    try:
        with wave.open(str(path), "rb") as source:
            if (source.getnchannels(), source.getsampwidth(), source.getframerate(), source.getcomptype()) != (1, 2, 16000, "NONE"):
                raise ValueError()
            frames = source.getnframes()
            if frames <= 0 or len(source.readframes(frames + 1)) != frames * 2:
                raise ValueError()
            return frames / 16
    except (OSError, EOFError, ValueError, wave.Error):
        raise Failure("capture", "invalid_audio", False) from None


def has_audio_activity(path):
    try:
        with wave.open(str(path), "rb") as source:
            rate = source.getframerate()
            frames = source.readframes(source.getnframes())
        samples = array.array("h")
        samples.frombytes(frames)
        if sys.byteorder != "little":
            samples.byteswap()
        # Sample at roughly 1 kHz: enough to reject empty windows without
        # adding material CPU cost to every overlapping ASR request.
        sampled = samples[::max(1, rate // 1000)]
        if not sampled:
            return False
        rms = math.sqrt(sum(sample * sample for sample in sampled) / len(sampled))
        active_ratio = sum(abs(sample) >= 200 for sample in sampled) / len(sampled)
        return rms >= 30 and active_ratio >= 0.0005
    except (OSError, EOFError, ValueError, wave.Error):
        raise Failure("capture", "invalid_audio", False) from None


def intervals(items):
    result = []
    for item in sorted(items, key=lambda value: value["startMs"]):
        start, end = item["startMs"], item["endMs"]
        if end <= start:
            continue
        if result and start <= result[-1]["endMs"] + 0.0625:
            result[-1]["endMs"] = max(result[-1]["endMs"], end)
        else:
            result.append({"startMs": start, "endMs": end})
    return result


def interval_size(items):
    return round(sum(item["endMs"] - item["startMs"] for item in intervals(items)), 4)


def uncovered(captured, covered):
    missing = []
    for span in intervals(captured):
        cursor = span["startMs"]
        for done in intervals(covered):
            if done["endMs"] <= cursor or done["startMs"] >= span["endMs"]:
                continue
            if done["startMs"] > cursor:
                missing.append({"startMs": cursor, "endMs": done["startMs"], "reason": "not_transcribed"})
            cursor = max(cursor, done["endMs"])
        if cursor < span["endMs"]:
            missing.append({"startMs": cursor, "endMs": span["endMs"], "reason": "not_transcribed"})
    return missing


def bounded_missing(items, duration_ms):
    """Return disjoint ranges without hiding an overlapping failure reason."""
    clipped = []
    for item in items:
        start, end = max(0, item["startMs"]), min(duration_ms, item["endMs"])
        if start < end:
            clipped.append({"startMs": start, "endMs": end, "reason": item["reason"]})
    points = sorted({point for item in clipped for point in (item["startMs"], item["endMs"])})
    result = []
    for start, end in zip(points, points[1:]):
        active = [item["reason"] for item in clipped if item["startMs"] <= start and item["endMs"] >= end]
        if not active:
            continue
        # Missing ASR and process faults take precedence over capture gaps;
        # capture gaps keep their exact measured span when routing uncertainty
        # or a brief restart overlaps them.
        reason = min(active, key=lambda value: (
            0 if value == "not_transcribed" else
            1 if value not in MINOR_GAP_REASONS else
            2 if value == "capture_gap" else 3, value))
        if result and result[-1]["endMs"] == start and result[-1]["reason"] == reason:
            result[-1]["endMs"] = end
        else:
            result.append({"startMs": start, "endMs": end, "reason": reason})
    return result


def accepts_minor_gaps(coverage, gaps, captured, transcribed):
    """Accept short, located capture interruptions without calling them complete."""
    duration = coverage["durationMs"]
    if coverage["complete"] or duration < MIN_MINOR_GAP_DURATION_MS:
        return False
    if not any(coverage["sides"][side]["missing"] for side in SIDES):
        return False
    # A stop/process fault outside the published interval must not disappear
    # when public missing ranges are clipped to the recording duration.
    if any(gap["side"] not in SIDES or gap["reason"] not in MINOR_GAP_REASONS
           or not 0 <= gap["startMs"] < gap["endMs"] <= duration
           for gap in gaps):
        return False
    budget = min(MAX_MINOR_GAPS_PER_SIDE_MS, duration * MAX_MINOR_GAP_FRACTION)
    for side in SIDES:
        value = coverage["sides"][side]
        start, end = value["captureStartMs"], value["captureEndMs"]
        missing = value["missing"]
        capture_gap_ms = sum(gap["endMs"] - gap["startMs"] for gap in missing
                             if gap["reason"] == "capture_gap")
        if (start is None or end is None or start < 0 or start > EDGE_TOLERANCE_MS
                or abs(end - duration) > capture_end_tolerance(duration)
                or value["capturedMs"] != value["transcribedMs"]
                or uncovered(captured[side], transcribed[side])
                or value.get("sampleClockShortfallMs") is not None
                or abs(end - start - value["capturedMs"] - capture_gap_ms) > 1
                or sum(gap["endMs"] - gap["startMs"] for gap in missing) > budget):
            return False
        continuous_start = None
        previous_end = None
        for gap in missing:
            if gap["reason"] not in MINOR_GAP_REASONS:
                return False
            if previous_end != gap["startMs"]:
                continuous_start = gap["startMs"]
            if gap["endMs"] - continuous_start > MAX_MINOR_GAP_MS:
                return False
            previous_end = gap["endMs"]
    return True


def calculate_coverage(captured, transcribed, duration_ms, gaps):
    result = {"complete": True, "durationMs": duration_ms, "sides": {}}
    end_tolerance = capture_end_tolerance(duration_ms)
    for side in SIDES:
        spans = intervals(captured[side])
        done = intervals(transcribed[side])
        start = spans[0]["startMs"] if spans else None
        end = spans[-1]["endMs"] if spans else None
        missing = uncovered(spans, done)
        side_gaps = [gap for gap in gaps if gap["side"] == side]
        missing.extend({key: gap[key] for key in ("startMs", "endMs", "reason")} for gap in side_gaps)
        if not spans:
            if duration_ms > 0:
                missing.append({"startMs": 0, "endMs": duration_ms, "reason": "no_audio"})
        else:
            for previous, following in zip(spans, spans[1:]):
                missing.append({"startMs": previous["endMs"], "endMs": following["startMs"], "reason": "capture_gap"})
            if start > EDGE_TOLERANCE_MS:
                missing.append({"startMs": 0, "endMs": start, "reason": "capture_started_late"})
            # A sample clock can drift from wall time throughout a long capture,
            # especially through virtualized PipeWire devices. Scale only the
            # final-edge tolerance: startup delays, internal gaps, explicit
            # process failures, and untranscribed audio remain exact failures.
            if end > duration_ms + end_tolerance:
                missing.append({"startMs": duration_ms, "endMs": end, "reason": "capture_clock_mismatch"})
        # WAV and segment timestamps advance only when samples arrive. A short
        # sample clock can reflect an underrun anywhere in a live capture; it
        # does not prove that the last seconds of the call are missing.
        shortfall = end is not None and end < duration_ms - end_tolerance
        has_missing = bool(missing) or shortfall
        missing = bounded_missing(missing, duration_ms)
        side_result = {"captureStartMs": start, "captureEndMs": end,
                       "capturedMs": interval_size(spans), "transcribedMs": interval_size(done),
                       "missing": missing}
        if shortfall:
            side_result["sampleClockShortfallMs"] = round(duration_ms - end, 4)
        result["sides"][side] = side_result
        # Clipping a stop failure outside the timestamp interval must not erase
        # its effect on readiness, even when no positive public range remains.
        result["complete"] &= bool(spans) and not has_missing and not side_gaps and side_result["capturedMs"] == side_result["transcribedMs"]
    result["acceptedMinorGaps"] = accepts_minor_gaps(result, gaps, captured, transcribed)
    return result


def new_manifest(recording_id, started, zone):
    return {"schemaVersion": 1, "recordingId": recording_id, "revision": 0,
            "status": "starting", "startedAt": started, "endedAt": None,
            "finalizedAt": None, "timeZone": zone,
            "source": {"kind": "record-call", "transcript": None},
            "coverage": calculate_coverage({side: [] for side in SIDES},
                                            {side: [] for side in SIDES}, 0, []),
            "failure": None}


def module_owned(module, index, kind, sink):
    try:
        arguments = dict(part.split("=", 1) for part in shlex.split(module.get("argument", "")) if "=" in part)
        key, value = ("sink_name", sink) if kind == "module-null-sink" else ("source", sink + ".monitor")
        return module["index"] == index and module["name"] == kind and arguments.get(key) == value
    except (ValueError, KeyError, TypeError):
        return False


def owner_matches(state, current_boot, properties):
    return bool(state.get("invocationId")) and state.get("bootId") == current_boot and properties.get("InvocationID") == state["invocationId"] and properties.get("ActiveState") in ("activating", "active", "deactivating")


def write_window_audio(fragments, start_ms, end_ms, destination):
    data = bytearray(round((end_ms - start_ms) * 16) * 2)
    for fragment in fragments:
        lo, hi = max(start_ms, fragment["startMs"]), min(end_ms, fragment["endMs"])
        if hi <= lo:
            continue
        path = Path(fragment["path"])
        if path.is_symlink() or file_hash(path) != fragment["sha256"]:
            raise Failure("recovery", "audio_changed", False)
        with wave.open(str(path), "rb") as source:
            source.setpos(round((lo - fragment["startMs"]) * 16))
            samples = source.readframes(round((hi - lo) * 16))
        offset = round((lo - start_ms) * 16) * 2
        data[offset:offset + len(samples)] = samples
    with wave.open(str(destination), "wb") as output:
        output.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        output.writeframes(data)


def intersect(fragments, start, end):
    return [{"startMs": max(start, item["startMs"]), "endMs": min(end, item["endMs"])}
            for item in fragments if item["endMs"] > start and item["startMs"] < end]


@contextmanager
def owned_children():
    children = []
    try:
        yield children
    finally:
        for child in children:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()


def journal_event(event):
    """Only fixed operation labels and numbers reach the owner's journal."""
    try:
        print(json.dumps(event, separators=(",", ":"), allow_nan=False), flush=True)
    except (OSError, ValueError):
        # A closed log stream cannot change ASR results or durable receipts.
        pass


@contextmanager
def observed_asr_attempts(provider, window):
    attempts = {}
    try:
        yield attempts
    finally:
        for side, attempt in attempts.items():
            success = attempt["code"] in ("ok", "silence")
            duration = round(max(0, attempt.get("finished", time.monotonic()) - attempt["started"]) * 1000)
            journal_event({"event": "record_call_asr_attempt", "level": "info" if success else "warning",
                           "provider": provider, "side": side, "windowIndex": window,
                           "outcome": "success" if success else "failure", "code": attempt["code"],
                           "durationMs": duration})


class Session:
    def __init__(self, directory, config):
        self.directory = Path(directory).resolve()
        self.private = self.directory / ".record-call"
        directory_stat = os.stat(self.directory, follow_symlinks=False)
        if not stat.S_ISDIR(directory_stat.st_mode):
            raise Failure("recovery", "recording_directory_changed", False)
        self.directory_identity = (directory_stat.st_dev, directory_stat.st_ino)
        self.config = config
        self.manifest = read_json(self.directory / "recording.json")
        self.state = read_json(self.private / "state.json")
        prior_directory = self.state.get("directoryPath")
        if prior_directory and Path(prior_directory) != self.directory:
            rebase_state_paths(self.state, Path(prior_directory), self.directory)
        self.captures = {}
        self.capture_activity = {}
        self.capture_stop_requested = set()
        self.stop_event = threading.Event()
        self.started_monotonic = time.monotonic()

    def command(self, name, *arguments, **kwargs):
        return subprocess.run([self.config[name], *map(str, arguments)], check=True, **kwargs)

    def persist(self):
        self.verify_directory_identity()
        self.manifest["revision"] += 1
        atomic_json(self.private / "state.json", self.state)
        atomic_json(self.directory / "recording.json", self.manifest)

    def persist_state(self):
        self.verify_directory_identity()
        atomic_json(self.private / "state.json", self.state)

    def verify_directory_identity(self):
        try:
            current = os.stat(self.directory, follow_symlinks=False)
        except FileNotFoundError:
            raise Failure("recovery", "recording_directory_changed", False) from None
        if not stat.S_ISDIR(current.st_mode) or (current.st_dev, current.st_ino) != self.directory_identity:
            raise Failure("recovery", "recording_directory_changed", False)

    def adopt_renamed_directory(self, original):
        base = recording_base_name(original, self.state)
        for suffix in ("-transcribed", "-transcribed-diarized", "-transcribed-processed",
                       "-transcribed-diarized-processed"):
            target = original.with_name(base + suffix)
            try:
                current = os.stat(target, follow_symlinks=False)
            except FileNotFoundError:
                continue
            if stat.S_ISDIR(current.st_mode) and (current.st_dev, current.st_ino) == self.directory_identity:
                # The kernel rename committed. Follow the same inode before a
                # metadata/fsync failure can cause a write at the stale path.
                self.directory = target
                self.private = target / ".record-call"
                rebase_state_paths(self.state, original, target)
                return True
        return False

    def elapsed(self):
        return round((time.monotonic() - self.started_monotonic) * 1000)

    def refresh_coverage(self, duration_override=None):
        completed = {side: [] for side in SIDES}
        for receipt in sorted((self.private / "windows").glob("*/done.json")):
            value = read_json(receipt)
            for side in SIDES:
                completed[side].extend(value["coverage"][side])
        end = self.manifest["endedAt"]
        duration = (round((timestamp(end) - timestamp(self.manifest["startedAt"])) * 1000)
                    if end else duration_override if duration_override is not None else self.elapsed())
        self.manifest["coverage"] = calculate_coverage(self.state["fragments"], completed,
                                                      duration, self.state["gaps"])

    def transcribe_command(self, audio, prefix):
        remote = self.state["whisperServerUrl"]
        if remote:
            # English is explicit; a second language-detection pass adds work
            # and its probability fields are not used by the transcript merger.
            return [self.config["curl"], "-fsS", "--max-time", "120", "-F", f"file=@{audio}",
                    "-F", "response_format=verbose_json", "-F", "language=en",
                    "-F", "no_language_probabilities=true", remote]
        return [self.config["whisper"], "-m", self.state["model"], "-l", "en", "-nt", "-oj",
                "-of", str(prefix), "--vad", "--vad-model", self.state["vadModel"], "-f", str(audio)]

    def process_window(self, index, end, emit_end):
        start = index * self.state["advanceMs"]
        destination = self.private / "windows" / f"{index:06d}"
        destination.mkdir(parents=True, exist_ok=True)
        parameters = {"startMs": start, "endMs": end, "emitEndMs": emit_end}
        receipt = destination / "done.json"
        if receipt.exists():
            value = read_json(receipt)
            if (value["parameters"] != parameters or file_hash(destination / "text.txt") != value["sha256"]
                    or ("offsetsSha256" in value and file_hash(destination / "offsets.json") != value["offsetsSha256"])):
                raise Failure("recovery", "window_changed", False, window=index)
            return
        running, errors = {}, []
        provider = "remote" if self.state["whisperServerUrl"] else "local"
        with tempfile.TemporaryDirectory(prefix="attempt-", dir=destination) as temporary, \
             observed_asr_attempts(provider, index) as attempts, owned_children() as children:
            temporary = Path(temporary)
            for side in SIDES:
                audio = temporary / (side + ".wav")
                write_window_audio(self.state["fragments"][side], start, end, audio)
                input_hash = file_hash(audio)
                success = destination / (side + ".ok.json")
                if success.exists():
                    prior = read_json(success)
                    if prior["inputHash"] != input_hash or prior["parameters"] != parameters or prior["outputHash"] != file_hash(destination / (side + ".json")):
                        raise Failure("recovery", "window_input_changed", False, side, index)
                    validate_asr(destination / (side + ".json"), end - start)
                    continue
                prefix = temporary / side
                if not has_audio_activity(audio):
                    started = time.monotonic()
                    atomic_json(prefix.with_suffix(".json"), {"segments": []})
                    target = destination / (side + ".json")
                    atomic_bytes(target, prefix.with_suffix(".json").read_bytes())
                    atomic_json(destination / (side + ".ok.json"), {
                        "inputHash": input_hash,
                        "outputHash": file_hash(target),
                        "parameters": parameters,
                    })
                    attempts[side] = {
                        "started": started,
                        "finished": time.monotonic(),
                        "code": "silence",
                    }
                    continue
                log = (destination / (side + ".log")).open("wb")
                output = prefix.with_suffix(".json").open("wb") if self.state["whisperServerUrl"] else subprocess.DEVNULL
                attempts[side] = {"started": time.monotonic(), "code": "asr_interrupted"}
                try:
                    child = subprocess.Popen(self.transcribe_command(audio, prefix), stdin=subprocess.DEVNULL,
                                             stdout=output, stderr=log)
                    children.append(child)
                except OSError:
                    attempts[side].update(code="asr_launch_failed", finished=time.monotonic())
                    raise
                finally:
                    if output != subprocess.DEVNULL:
                        output.close()
                    log.close()
                running[side] = (child, prefix, input_hash, attempts[side]["started"])
            for side, (child, prefix, input_hash, started) in running.items():
                limit = 125 if self.state["whisperServerUrl"] else 1200
                try:
                    code = child.wait(timeout=max(0.1, limit - (time.monotonic() - started)))
                    if code != 0:
                        raise Failure("transcription", "asr_exit", True, side, index)
                    validate_asr(prefix.with_suffix(".json"), end - start)
                    target = destination / (side + ".json")
                    atomic_bytes(target, prefix.with_suffix(".json").read_bytes())
                    atomic_json(destination / (side + ".ok.json"), {
                        "inputHash": input_hash, "outputHash": file_hash(target), "parameters": parameters})
                    attempts[side]["code"] = "ok"
                except subprocess.TimeoutExpired:
                    attempts[side]["code"] = "asr_timeout"
                    child.kill()
                    child.wait()
                    errors.append(Failure("transcription", "asr_timeout", True, side, index))
                except Failure as error:
                    attempts[side]["code"] = error.code
                    error.side, error.window = side, index
                    errors.append(error)
                finally:
                    attempts[side]["finished"] = time.monotonic()
                    self.bound_log(destination / (side + ".log"))
            if errors:
                atomic_json(destination / "failure.json", errors[0].public())
                raise errors[0]
        side_emit_ends = {
            side: min(emit_end, max((fragment["endMs"] for fragment in self.state["fragments"][side]),
                                    default=start))
            for side in SIDES
        }
        result = self.command("python", self.config["merge"], destination / "call.json", destination / "mic.json",
                              start / 1000, start / 1000, side_emit_ends["call"] / 1000,
                              side_emit_ends["mic"] / 1000,
                              timestamp(self.manifest["startedAt"]), destination / "offsets.json",
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              env={**os.environ, "TZ": self.manifest["timeZone"]})
        atomic_bytes(destination / "text.txt", result.stdout)
        atomic_bytes(destination / "offsets.json", (destination / "offsets.json").read_bytes())
        atomic_json(receipt, {"parameters": parameters, "sha256": file_hash(destination / "text.txt"),
                             "offsetsSha256": file_hash(destination / "offsets.json"),
                             "coverage": {side: intersect(self.state["fragments"][side], start, emit_end) for side in SIDES}})

    @staticmethod
    def bound_log(path):
        if path.stat().st_size > 65536:
            with path.open("rb") as source:
                source.seek(-65536, os.SEEK_END)
                data = source.read()
            atomic_bytes(path, data)

    @staticmethod
    def transcript_descriptor(path):
        data = path.read_bytes()
        return {
            "path": path.name,
            "sha256": hashlib.sha256(data).hexdigest(),
            "bytes": len(data),
            "speechTurns": sum(
                bool(re.match(rb"^\[\d\d:\d\d:\d\d\] ", line))
                for line in data.splitlines()
            ),
        }

    def assemble(self):
        receipts = sorted((self.private / "windows").glob("*/done.json"))
        chunks = []
        offsets = []
        offsets_available = True
        for index, receipt in enumerate(receipts):
            if receipt.parent.name != f"{index:06d}":
                raise Failure("assembly", "missing_window")
            value = read_json(receipt)
            data = (receipt.parent / "text.txt").read_bytes()
            if hashlib.sha256(data).hexdigest() != value["sha256"]:
                raise Failure("assembly", "window_changed", False)
            chunks.append(data)
            if "offsetsSha256" in value:
                path = receipt.parent / "offsets.json"
                if file_hash(path) != value["offsetsSha256"]:
                    raise Failure("assembly", "window_changed", False)
                sidecar = read_json(path)
                if not isinstance(sidecar, list) or len(sidecar) != len(data.splitlines()) or any(
                        not number(offset) or offset < 0 for offset in sidecar):
                    raise Failure("assembly", "window_changed", False)
                offsets.extend(sidecar)
            else:
                offsets_available = False
        raw = b"".join(chunks)
        with tempfile.TemporaryDirectory(prefix="assemble-", dir=self.private) as temporary:
            temporary = Path(temporary)
            transcript = temporary / "transcript.txt"
            transcript.write_bytes(raw)
            raw_offsets = temporary / "offsets.raw.json"
            if offsets_available:
                atomic_json(raw_offsets, offsets)
            try:
                self.command("python", self.config["dedupe"], transcript,
                             *([raw_offsets] if offsets_available else []), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                if offsets_available:
                    atomic_bytes(temporary / "offsets.json", raw_offsets.read_bytes())
                self.command("python", self.config["turns"], transcript, temporary / "turns.txt", self.state["turnGap"],
                             *([temporary / "offsets.json"] if offsets_available else []),
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            except subprocess.CalledProcessError:
                raise Failure("assembly", "turns_failed") from None
            turns = (temporary / "turns.txt").read_bytes()
            atomic_bytes(self.directory / "transcript.raw.txt", raw)
            atomic_bytes(self.directory / "transcript.txt", transcript.read_bytes())
            if offsets_available:
                atomic_bytes(self.directory / "transcript.offsets.json", (temporary / "offsets.json").read_bytes())
            atomic_bytes(self.directory / "transcript.turns.txt", turns)
        self.manifest["source"]["transcript"] = self.transcript_descriptor(
            self.directory / "transcript.turns.txt"
        )

    def protect_published_diarization(self):
        """Move legacy mutable diarization out of the manifest before a retry."""
        published = self.manifest["source"].get("transcript") or {}
        if published.get("path") != "transcript.diarized.turns.txt":
            return
        source = self.directory / published["path"]
        if source.is_symlink() or self.transcript_descriptor(source) != published:
            raise ValueError("published diarization changed")
        protected = self.directory / f"transcript.diarized.{uuid.uuid4().hex}.turns.txt"
        atomic_bytes(protected, source.read_bytes())
        self.manifest["source"]["transcript"] = self.transcript_descriptor(protected)
        self.persist()

    def validate_diarization(self, transcript, segments):
        if not transcript.is_file() or transcript.is_symlink() or not isinstance(segments, list) or not segments or len(segments) > 100000:
            raise ValueError("invalid diarization artifacts")
        # Diarization audio preserves the session timeline, including brief
        # capture gaps as silence, so segment offsets use the final end time.
        call_seconds = max((item["endMs"] for item in self.state["fragments"]["call"]), default=0) / 1000
        speakers = set()
        previous_start = -1
        for segment in segments:
            if not isinstance(segment, dict):
                raise ValueError("invalid diarization segment")
            start, end, speaker = segment.get("start"), segment.get("end"), segment.get("speaker")
            if (not number(start) or not number(end) or start < 0 or start < previous_start
                    or end <= start or end > call_seconds + 1
                    or not isinstance(speaker, str) or not speaker.strip()):
                raise ValueError("invalid diarization timeline")
            previous_start = start
            speakers.add(speaker)
        raw = (self.directory / "transcript.txt").read_text().splitlines()
        aligned = (self.directory / "transcript.diarized.txt").read_text().splitlines()
        if len(aligned) != len(raw):
            raise ValueError("diarization dropped transcript lines")
        labeled_remote = 0
        unlabeled_remote = 0
        for before, after in zip(raw, aligned):
            prefix = re.match(r"^\[\d\d:\d\d:\d\d\] ", before)
            if not prefix:
                if after != before:
                    raise ValueError("diarization changed transcript structure")
                continue
            if before.startswith(prefix.group() + "Me: "):
                if after != before:
                    raise ValueError("diarization changed microphone speech")
                continue
            if after == before:
                unlabeled_remote += 1
                continue
            expected = re.escape(prefix.group()) + r"Speaker \d+: " + re.escape(before[len(prefix.group()):])
            if not re.fullmatch(expected, after):
                raise ValueError("diarization changed remote speech")
            labeled_remote += 1
        if unlabeled_remote:
            raise DiarizationCoverageError(unlabeled_remote, labeled_remote + unlabeled_remote)
        if not labeled_remote:
            raise ValueError("no labeled remote speech")
        # The published artifact groups speech below multiline turn headers.
        # Rebuild it from the fully validated alignment, so a truncated or stale
        # turns file cannot pass merely by containing one speaker label.
        offsets = self.directory / "transcript.offsets.json"
        with tempfile.TemporaryDirectory(prefix="validate-diarization-", dir=self.private) as temporary:
            expected = Path(temporary) / "turns.txt"
            self.command("python", self.config["turns"], self.directory / "transcript.diarized.txt",
                         expected, self.state["turnGap"], *([offsets] if offsets.exists() else []),
                         stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=60)
            if transcript.read_bytes() != expected.read_bytes():
                raise ValueError("diarization turns do not match labeled speech")
        return len(speakers)

    def attempt_diarization(self):
        prior = self.state.get("diarization") or {}
        server_url = self.state.get(
            "diarizationServerUrl",
            self.config["defaultDiarizationServerUrl"],
        )
        transcript = self.manifest["source"].get("transcript") or {}
        skip_reason = (
            "disabled"
            if not server_url
            else "no_speech"
            if transcript.get("speechTurns") == 0
            else None
        )
        if skip_reason:
            self.state["diarization"] = {
                "status": "skipped",
                "attempts": int(prior.get("attempts", 0)),
                "startedAt": None,
                "finishedAt": utc_now(),
                "failure": None,
                "reason": skip_reason,
            }
            if self.manifest["status"] == "ready":
                self.persist_state()
            else:
                self.persist()
            return True

        attempts = int(prior.get("attempts", 0)) + 1
        started = utc_now()
        self.state["finalizationStage"] = "diarizing"
        self.state["diarization"] = {
            "status": "running",
            "attempts": attempts,
            "startedAt": started,
            "finishedAt": None,
            "failure": None,
        }
        if self.manifest["status"] == "ready":
            self.persist_state()
        else:
            self.persist()

        log_path = self.private / "diarization.log"
        try:
            self.protect_published_diarization()
            with log_path.open("ab") as log:
                self.command(
                    "diarize",
                    self.directory,
                    server_url,
                    self.state.get("diarizationModel", self.config["diarizationModel"]),
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    timeout=7200,
                    env={**os.environ, "TZ": self.manifest["timeZone"],
                         "RECORD_CALL_TURN_GAP_SEC": str(self.state["turnGap"])},
                )
            transcript = self.directory / "transcript.diarized.turns.txt"
            diarization = read_json(self.directory / "diarization.json")
            speakers = self.validate_diarization(transcript, diarization)
            immutable = self.directory / f"transcript.diarized.{uuid.uuid4().hex}.turns.txt"
            atomic_bytes(immutable, transcript.read_bytes())
            descriptor = self.transcript_descriptor(immutable)
            self.manifest["source"]["transcript"] = descriptor
            self.state["diarization"] = {
                "status": "ready",
                "attempts": attempts,
                "startedAt": started,
                "finishedAt": utc_now(),
                "failure": None,
                "speakers": speakers,
                "transcript": descriptor,
            }
            self.bound_log(log_path)
            self.persist()
            return True
        except subprocess.TimeoutExpired:
            failure = {"code": "diarization_timeout", "retryable": True}
        except DiarizationCoverageError as error:
            failure = {"code": "diarization_incomplete_coverage", "retryable": True,
                       "unlabeledRemoteLines": error.unlabeled, "totalRemoteLines": error.total}
        except (subprocess.SubprocessError, OSError, ValueError, KeyError, TypeError):
            failure = {"code": "diarization_failed", "retryable": True}

        self.state["diarization"] = {
            "status": "failed",
            "attempts": attempts,
            "startedAt": started,
            "finishedAt": utc_now(),
            "failure": failure,
        }
        if log_path.exists():
            self.bound_log(log_path)
        if self.manifest["status"] == "ready":
            self.persist_state()
        else:
            self.persist()
        return False

    def notify_diarization_failure(self):
        notifier = self.config.get("notifySend")
        failure = (self.state.get("diarization") or {}).get("failure") or {}
        if not notifier or not isinstance(failure, dict) or not failure or self.manifest["status"] != "ready":
            return
        if failure.get("code") == "diarization_incomplete_coverage" and all(
                isinstance(failure.get(key), int) for key in ("unlabeledRemoteLines", "totalRemoteLines")):
            detail = (f"Could not label {failure['unlabeledRemoteLines']} of "
                      f"{failure['totalRemoteLines']} call speech lines. ")
        elif failure.get("code") == "diarization_timeout":
            detail = "Participant labeling timed out. "
        else:
            detail = "Participant labeling failed. "
        try:
            subprocess.run([notifier, "--app-name=Record Call", "--urgency=normal",
                            "Record Call", detail + "Transcript is ready. You can start another recording."],
                           check=False, timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (OSError, ValueError, subprocess.SubprocessError):
            pass

    def setup_audio(self):
        sink = self.state["sink"]
        for role, arguments in (
            ("sink", ["module-null-sink", "sink_name=" + sink, 'sink_properties=device.description="Record-Call"']),
            ("loopback", ["module-loopback", "source=" + sink + ".monitor", "sink=@DEFAULT_SINK@", "latency_msec=50"]),
        ):
            result = self.command("pactl", "load-module", *arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
            self.state["modules"][role] = int(result.stdout.strip())
            self.persist()
        for _ in range(30):
            sources = json.loads(self.command("pactl", "-f", "json", "list", "sources", stdout=subprocess.PIPE, timeout=5).stdout)
            default = self.command("pactl", "get-default-source", stdout=subprocess.PIPE, timeout=5).stdout.decode().strip()
            call = next((item["index"] for item in sources if item["name"] == sink + ".monitor"), None)
            mic = next((item["index"] for item in sources if item["name"] == default), None)
            if call is not None and mic is not None:
                self.state["sources"] = {"call": call, "mic": mic}
                return
            time.sleep(0.1)
        raise Failure("startup", "audio_source_unavailable")

    def cleanup_modules(self):
        started = time.monotonic()
        try:
            # pactl 17 omits module indices from JSON. The short listing carries
            # the ID, name and arguments in one response, so ownership can be
            # checked without correlating potentially different snapshots.
            listing = self.command("pactl", "list", "short", "modules", stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, timeout=5).stdout.decode()
            modules = []
            for line in listing.splitlines():
                fields = line.split("\t", 3)
                if len(fields) >= 3 and fields[0].isascii() and fields[0].isdigit():
                    modules.append({"index": int(fields[0]), "name": fields[1], "argument": fields[2]})
            for role, kind in (("loopback", "module-loopback"), ("sink", "module-null-sink")):
                index = self.state["modules"].get(role)
                for module in modules:
                    # The session UUID also permits reconciling a crash between
                    # load-module returning and its ID reaching durable state.
                    candidate = module.get("index") if index is None else index
                    if module_owned(module, candidate, kind, self.state["sink"]):
                        self.command("pactl", "unload-module", candidate, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.PIPE, timeout=5)
        except (subprocess.SubprocessError, OSError, ValueError):
            # Identity uncertainty never authorizes broader module cleanup.
            self.state["cleanupWarning"] = "owned_module_cleanup_unavailable"
            journal_event({"event": "record_call_module_cleanup", "level": "warning", "outcome": "failure",
                           "code": "owned_module_cleanup_unavailable",
                           "durationMs": round(max(0, time.monotonic() - started) * 1000)})

    def launch_capture(self, side):
        runs = self.state["runs"][side]
        run_index = len(runs)
        listing = self.private / f"{side}-{run_index:04d}.csv"
        indices = [int(path.stem.split("_")[1]) for path in (self.directory / "chunks").glob(side + "_*.wav")
                   if re.fullmatch(side + r"_\d{6}\.wav", path.name)]
        next_index = max(indices, default=-1) + 1
        run = {"list": str(listing), "offsetMs": self.elapsed(), "seen": [], "index": run_index,
               "firstChunkIndex": next_index}
        runs.append(run)
        self.persist()
        with (self.directory / f"pw-{side}.log").open("ab") as log:
            reader = subprocess.Popen([self.config["pwRecord"], f"--target={self.state['sources'][side]}",
                                       "--format=s16", "--rate=16000", "--channels=1", "-"],
                                      stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=log)
        try:
            with (self.directory / f"ffmpeg-{side}.log").open("ab") as log:
                segmenter = subprocess.Popen([
                    self.config["ffmpeg"], "-hide_banner", "-loglevel", "warning", "-y",
                    "-f", "s16le", "-ar", "16000", "-ac", "1", "-i", "-", "-c:a", "pcm_s16le",
                    "-f", "segment", "-segment_time", str(self.state["fragmentMs"] / 1000),
                    # Expose live PCM progress even for long open fragments;
                    # the default 256 KiB buffer can hide over eight seconds.
                    "-segment_format_options", "flush_packets=1",
                    "-reset_timestamps", "1", "-segment_start_number", str(next_index),
                    "-segment_list", str(listing), "-segment_list_type", "csv", "-segment_list_size", "0",
                    str(self.directory / "chunks").replace("%", "%%") + "/" + side + "_%06d.wav"],
                    stdin=reader.stdout, stdout=subprocess.DEVNULL, stderr=log)
        except BaseException:
            reader.terminate()
            reader.wait(timeout=5)
            raise
        finally:
            reader.stdout.close()
        self.captures[side] = (reader, segmenter)
        self.capture_stop_requested.discard(side)
        self.capture_activity[side] = {
            "index": next_index, "bytes": 0, "changedAt": time.monotonic(),
            "fragmentEndMs": None, "clockAnchor": None,
            "lastCheckedAt": time.monotonic(),
        }

    def capture_health(self, side):
        """Detect a live child that has stopped producing data or lost clock time.

        Closed fragment receipts remain the authority for final coverage. File
        growth is used only to decide when to restart an unresponsive live pipe.
        """
        activity = self.capture_activity[side]
        index = activity["index"]
        chunks = self.directory / "chunks"
        while (chunks / f"{side}_{index + 1:06d}.wav").exists():
            index += 1
        path = chunks / f"{side}_{index:06d}.wav"
        size = path.stat().st_size if path.exists() else 0
        now = time.monotonic()
        observation_gap = now - activity.get("lastCheckedAt", now)
        activity["lastCheckedAt"] = now
        if index > activity["index"] or size > activity["bytes"]:
            activity.update(index=index, bytes=size, changedAt=now)
        if now - activity["changedAt"] > CAPTURE_STALL_SECONDS:
            return "capture_stalled"

        run = self.state["runs"][side][-1]
        latest = max((fragment for fragment in self.state["fragments"][side]
                      if fragment["startMs"] >= run["offsetMs"]),
                     key=lambda fragment: fragment["endMs"], default=None)
        end = latest["endMs"] if latest else None
        if end is not None and end != activity["fragmentEndMs"]:
            # A slow control command can delay observing a closed WAV. Use a
            # monotonic observation gap, not file mtime on the wall clock:
            # time corrections must not invent or hide a capture fault.
            if observation_gap > 1.5:
                activity["fragmentEndMs"] = end
                return None
            elapsed = self.elapsed()
            lag = elapsed - end
            if activity["clockAnchor"] is None:
                if lag > CAPTURE_CLOCK_SLACK_MS:
                    return "capture_clock_lag"
                activity["clockAnchor"] = (elapsed, lag)
            else:
                anchor_elapsed, anchor_lag = activity["clockAnchor"]
                allowed = CAPTURE_CLOCK_SLACK_MS + (elapsed - anchor_elapsed) * MAX_CAPTURE_CLOCK_DRIFT_PPM / 1_000_000
                if lag - anchor_lag > allowed:
                    return "capture_clock_lag"
            activity["fragmentEndMs"] = end
        return None

    def restart_capture(self, side, code):
        observed_at = self.elapsed()
        issue = {"side": side, "code": code, "atMs": observed_at}
        self.state.setdefault("captureIssues", []).append(issue)
        # A stalled or exited reader may have stopped producing samples well
        # before this loop noticed it. Mark the entire unobserved interval as
        # uncertain, and commit it before stopping the old child so a crash
        # during recovery cannot erase the evidence.
        gap_start = observed_at
        if code in ("capture_stalled", "capture_process_exited"):
            last_growth = self.capture_activity.get(side, {}).get("changedAt")
            if last_growth is not None:
                gap_start = max(0, observed_at - max(0, round((time.monotonic() - last_growth) * 1000)))
        # A child exit or stalled reader is a capture fault, even when the
        # restart is quick. Keep that cause in public coverage so a later
        # long recording cannot admit it as an ordinary minor interruption.
        reason = code if code in ("capture_stalled", "capture_process_exited") else "capture_restarted"
        gap = {"side": side, "startMs": gap_start,
               "endMs": max(gap_start + 1, observed_at), "reason": reason}
        self.state["gaps"].append(gap)
        journal_event({"event": "record_call_capture_fault", "level": "warning", **issue})
        self.persist_state()
        self.stop_capture(side, expected_exit=True)
        self.collect_fragments()
        if len(self.state["runs"][side]) >= 4:
            raise Failure("capture", "capture_restart_limit", False, side)
        self.launch_capture(side)
        gap["endMs"] = max(gap["endMs"], self.elapsed())
        self.refresh_coverage()
        self.persist()

    def collect_fragments(self):
        changed = False
        for side in SIDES:
            for run in self.state["runs"][side]:
                listing = Path(run["list"])
                if not listing.exists():
                    continue
                text = listing.read_text()
                # Ignore a partially written row; the muxer publishes a row only
                # after closing its WAV. Existing filenames do not prove closure.
                text = text[:text.rfind("\n") + 1]
                seen = set(run["seen"])
                for row in csv.reader(io.StringIO(text)):
                    if not row:
                        continue
                    if len(row) != 3:
                        raise Failure("capture", "invalid_segment_list", False, side)
                    if row[0] in seen:
                        continue
                    path = Path(row[0])
                    if not path.is_absolute():
                        path = self.directory / "chunks" / path
                    if path.parent.resolve() != (self.directory / "chunks").resolve() or path.is_symlink() or not re.fullmatch(side + r"_\d{6}\.wav", path.name):
                        raise Failure("capture", "invalid_segment_path", False, side)
                    start, end = float(row[1]) * 1000, float(row[2]) * 1000
                    duration = wav_duration(path)
                    if not number(start) or not number(end) or start < 0 or abs(end - start - duration) > 1:
                        raise Failure("capture", "invalid_segment_duration", False, side)
                    offset = run["offsetMs"] + start
                    self.state["fragments"][side].append({"path": str(path), "startMs": offset,
                                                        "endMs": offset + duration, "sha256": file_hash(path)})
                    run["seen"].append(row[0])
                    seen.add(row[0])
                    changed = True
        if changed:
            self.refresh_coverage()
            self.persist()

    def has_retained_audio_candidate(self):
        if any(self.state["fragments"][side] for side in SIDES):
            return True
        # A muxer can close its first WAV/CSV row just before owner loss, before
        # the controller saves any fragment. Status only offers recovery here;
        # the owned worker validates those receipts under its writer lock.
        for side in SIDES:
            for run in self.state["runs"][side]:
                path = Path(run["list"])
                try:
                    if path.parent.resolve() != self.private.resolve() or path.is_symlink():
                        continue
                    with path.open("rb") as listing:
                        if b"\n" in listing.read(65536):
                            return True
                except OSError:
                    continue
        return False

    def request_stop_capture(self, side):
        reader = self.captures[side][0]
        if reader.poll() is None:
            try:
                reader.terminate()
                self.capture_stop_requested.add(side)
            except ProcessLookupError:
                pass

    def stop_capture(self, side, expected_exit=False):
        reader, segmenter = self.captures.pop(side)
        requested = side in self.capture_stop_requested
        if not requested and reader.poll() is None:
            try:
                reader.terminate()
                requested = True
            except ProcessLookupError:
                pass
        try:
            code = reader.wait(timeout=5)
            # pw-cat 1.6.9 exits 1 on an intentional recording stop: its signal
            # handler quits the loop, and only drained playback exits 0. Accept
            # that status only for our stop request; an unsolicited exit still
            # means capture failed. WAV receipts and coverage remain mandatory.
            if not expected_exit and (not requested or code not in (0, 1, -signal.SIGTERM)):
                self.state["gaps"].append({"side": side, "startMs": self.elapsed(),
                                           "endMs": self.elapsed() + 1, "reason": "reader_failed"})
        except subprocess.TimeoutExpired:
            reader.kill()
            reader.wait()
            self.state["gaps"].append({"side": side, "startMs": self.elapsed(), "endMs": self.elapsed() + 1,
                                       "reason": "capture_stop_timeout"})
        try:
            code = segmenter.wait(timeout=10)
            if code != 0:
                self.state["gaps"].append({"side": side, "startMs": self.elapsed(), "endMs": self.elapsed() + 1,
                                           "reason": "segmenter_failed"})
        except subprocess.TimeoutExpired:
            segmenter.kill()
            segmenter.wait()
            self.state["gaps"].append({"side": side, "startMs": self.elapsed(), "endMs": self.elapsed() + 1,
                                       "reason": "segmenter_stop_timeout"})
        self.capture_stop_requested.discard(side)
        self.capture_activity.pop(side, None)

    def route(self):
        sinks = json.loads(self.command("pactl", "-f", "json", "list", "sinks", stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, timeout=5).stdout)
        target = next((item["index"] for item in sinks if item["name"] == self.state["sink"]), None)
        if target is None:
            raise Failure("capture", "recording_sink_missing", False)
        inputs = json.loads(self.command("pactl", "-f", "json", "list", "sink-inputs", stdout=subprocess.PIPE,
                                          stderr=subprocess.PIPE, timeout=5).stdout)
        browser_inputs = 0
        for item in inputs:
            properties = item.get("properties", {})
            application = properties.get("application.process.binary", "") + " " + properties.get("application.name", "")
            if re.search(r"chrome|chromium|brave|google|firefox", application, re.I):
                browser_inputs += 1
                if item["sink"] != target:
                    self.command("pactl", "move-sink-input", item["index"], target, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.PIPE, timeout=5)
        return browser_inputs

    def begin_routing_uncertainty(self, code, start=None):
        if self.state.get("routingUncertainStartMs") is None:
            observed_at = self.elapsed() if start is None else start
            self.state["routingUncertainStartMs"] = observed_at
            self.state.setdefault("captureIssues", []).append({
                "side": "call", "code": "routing_uncertain", "atMs": observed_at})
        if self.state.get("routingWarning") != code:
            self.state["routingWarning"] = code
            self.persist_state()
            journal_event({"event": "record_call_routing", "level": "warning", "code": code})

    def observe_browser_stream(self, count):
        if count == 0:
            start = self.state.setdefault("browserStreamAbsentStartMs", self.elapsed())
            if self.elapsed() - start >= 10000:
                self.begin_routing_uncertainty("browser_stream_missing", start)
        else:
            self.state.pop("browserStreamAbsentStartMs", None)
            if self.state.pop("routingWarning", None):
                self.close_routing_uncertainty()

    def default_mic_source(self):
        name = self.command("pactl", "get-default-source", stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=5).stdout.decode().strip()
        sources = json.loads(self.command("pactl", "-f", "json", "list", "sources",
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5).stdout)
        source = next((item["index"] for item in sources if item["name"] == name), None)
        if source is None:
            raise Failure("capture", "microphone_source_missing", False, "mic")
        return source

    def close_mic_uncertainty(self):
        start = self.state.pop("micUncertainStartMs", None)
        if start is None:
            return
        self.state["gaps"].append({"side": "mic", "startMs": start,
                                   "endMs": max(start + 1, self.elapsed()),
                                   "reason": "microphone_source_uncertain"})
        self.refresh_coverage()
        self.persist()

    def close_routing_uncertainty(self):
        start = self.state.pop("routingUncertainStartMs", None)
        if start is None:
            return
        self.state["gaps"].append({"side": "call", "startMs": start,
                                   "endMs": max(start + 1, self.elapsed()),
                                   "reason": "routing_uncertain"})
        self.refresh_coverage()
        self.persist()

    def next_window(self):
        index = 0
        while (self.private / "windows" / f"{index:06d}" / "done.json").exists():
            index += 1
        return index

    def finalization_progress(self):
        end = max((fragment["endMs"] for side in SIDES for fragment in self.state["fragments"][side]),
                  default=0)
        total = math.ceil(end / self.state["advanceMs"]) if end > 0 else 0
        return {"completedWindows": min(self.next_window(), total), "totalWindows": total}

    def committed_emission_frontier(self, audio_end):
        frontier, count = 0, 0
        receipts = sorted((self.private / "windows").glob("*/done.json"))
        for index, path in enumerate(receipts):
            try:
                receipt = read_json(path)
                parameters = receipt["parameters"]
                start, end, emitted = (parameters[key] for key in ("startMs", "endMs", "emitEndMs"))
                valid = (path.parent.name == f"{index:06d}"
                         and all(number(value) for value in (start, end, emitted))
                         and start == index * self.state["advanceMs"] and start == frontier
                         and start < emitted <= end <= start + self.state["windowMs"]
                         and emitted <= audio_end
                         and file_hash(path.parent / "text.txt") == receipt["sha256"])
                if "offsetsSha256" in receipt:
                    valid &= file_hash(path.parent / "offsets.json") == receipt["offsetsSha256"]
                for side in SIDES:
                    success = read_json(path.parent / (side + ".ok.json"))
                    valid &= (success["parameters"] == parameters
                              and success["outputHash"] == file_hash(path.parent / (side + ".json"))
                              and receipt["coverage"][side] == intersect(self.state["fragments"][side], start, emitted))
                if not valid:
                    raise Failure("recovery", "window_receipt_invalid", False, window=index)
            except (OSError, KeyError, TypeError, ValueError):
                raise Failure("recovery", "window_receipt_invalid", False, window=index) from None
            frontier, count = emitted, index + 1
        return count, frontier

    def progress_transcript(self):
        parts = []
        for receipt in sorted((self.private / "windows").glob("*/done.json")):
            parts.append((receipt.parent / "text.txt").read_bytes())
        atomic_bytes(self.directory / "transcript.txt", b"".join(parts))

    def capture(self):
        self.setup_audio()
        self.manifest["startedAt"] = utc_now()
        self.started_monotonic = time.monotonic()
        # Existing diarize/retime commands consume whole epoch seconds. The
        # public manifest retains the precise capture timestamp independently.
        atomic_bytes(self.directory / ".started-at", str(int(timestamp(self.manifest["startedAt"]))).encode())
        for side in SIDES:
            self.launch_capture(side)
        self.manifest["status"] = "recording"
        self.persist()
        pending, failed, routed = None, False, 0
        with ThreadPoolExecutor(max_workers=1) as executor:
            try:
                while not self.stop_event.is_set():
                    request = self.private / "stop.json"
                    if request.exists() and read_json(request).get("invocationId") == self.state["invocationId"]:
                        break
                    self.collect_fragments()
                    for side, processes in list(self.captures.items()):
                        exited = any(child.poll() is not None for child in processes)
                        fault = "capture_process_exited" if exited else self.capture_health(side)
                        if fault:
                            self.restart_capture(side, fault)
                    if time.monotonic() - routed >= 1:
                        try:
                            mic_source = self.default_mic_source()
                        except (Failure, OSError, subprocess.SubprocessError, ValueError):
                            if self.state.get("micSourceWarning") != "microphone_source_unavailable":
                                self.state["micSourceWarning"] = "microphone_source_unavailable"
                                self.state["micUncertainStartMs"] = self.elapsed()
                                self.state.setdefault("captureIssues", []).append({
                                    "side": "mic", "code": "microphone_source_uncertain",
                                    "atMs": self.state["micUncertainStartMs"]})
                                self.persist_state()
                        else:
                            if self.state.pop("micSourceWarning", None):
                                self.close_mic_uncertainty()
                            if mic_source != self.state["sources"]["mic"]:
                                self.state["sources"]["mic"] = mic_source
                                self.persist_state()
                                self.restart_capture("mic", "microphone_source_changed")
                        try:
                            browser_inputs = self.route()
                        except (Failure, OSError, subprocess.SubprocessError, ValueError):
                            self.begin_routing_uncertainty("routing_unavailable")
                        else:
                            self.observe_browser_stream(browser_inputs)
                        routed = time.monotonic()
                    if pending is not None and pending.done():
                        try:
                            pending.result()
                            self.progress_transcript()
                        except Failure as error:
                            self.manifest["failure"] = error.public()
                            failed = True
                        pending = None
                        self.refresh_coverage()
                        self.persist()
                    if pending is None and not failed:
                        index = self.next_window()
                        start = index * self.state["advanceMs"]
                        end = start + self.state["windowMs"]
                        frontiers = [max((item["endMs"] for item in self.state["fragments"][side]), default=0) for side in SIDES]
                        if min(frontiers) >= end:
                            pending = executor.submit(self.process_window, index, end, start + self.state["advanceMs"])
                    self.stop_event.wait(0.2)
            finally:
                # The stop instant is independent of transcription/cleanup time.
                self.close_routing_uncertainty()
                self.close_mic_uncertainty()
                for side in list(self.captures):
                    self.request_stop_capture(side)
                self.manifest["endedAt"] = utc_now()
                self.manifest["status"] = "finalizing"
                self.persist()
                for side in list(self.captures):
                    self.stop_capture(side)
                self.collect_fragments()
                self.cleanup_modules()
                self.persist()
            if pending is not None:
                try:
                    pending.result()
                except Failure as error:
                    self.manifest["failure"] = error.public()

    def verify_retained_audio(self, require_all_chunks=True):
        known = {Path(fragment["path"]).resolve() for side in SIDES for fragment in self.state["fragments"][side]}
        if require_all_chunks:
            for path in (self.directory / "chunks").glob("*.wav"):
                if path.resolve() not in known:
                    # Even a short unlisted tail is missing evidence, not clock
                    # jitter. Retain it and refuse automatic READY publication.
                    raise Failure("capture", "unfinalized_audio", False)
        for side in SIDES:
            for fragment in self.state["fragments"][side]:
                path = Path(fragment["path"])
                if path.is_symlink() or path.parent.resolve() != (self.directory / "chunks").resolve() or file_hash(path) != fragment["sha256"]:
                    raise Failure("recovery", "audio_changed", False, side)
                if abs(wav_duration(path) - (fragment["endMs"] - fragment["startMs"])) > 1:
                    raise Failure("recovery", "audio_changed", False, side)

    def transcribe_retained_audio(self):
        self.manifest["status"] = "finalizing"
        self.manifest["finalizedAt"] = None
        self.state["finalizationStage"] = "transcribing"
        self.persist()
        end = max((fragment["endMs"] for side in SIDES for fragment in self.state["fragments"][side]), default=0)
        index, frontier = self.committed_emission_frontier(end)
        while frontier < end:
            start = index * self.state["advanceMs"]
            if start != frontier:
                # A final receipt may emit past the regular 30-second advance.
                # Later audio cannot silently turn that receipt into a shorter
                # one and cause already committed text to be emitted again.
                raise Failure("recovery", "window_emission_conflict", False, window=index)
            window_end = min(start + self.state["windowMs"], end)
            emit_end = start + self.state["advanceMs"] if start + self.state["windowMs"] < end else end
            self.process_window(index, window_end, emit_end)
            index += 1
            frontier = emit_end
        self.assemble()
        return end

    def salvage_retained(self):
        """Transcribe verified closed fragments when the capture end is unknown.

        Unlisted open tails remain on disk for inspection. A partial transcript
        is useful, but without an end timestamp it can never be published READY.
        """
        if self.manifest["endedAt"] is not None:
            raise Failure("recovery", "capture_end_known", False)
        if not any(self.state["fragments"][side] for side in SIDES):
            raise Failure("recovery", "no_retained_audio", False)
        self.verify_retained_audio(require_all_chunks=False)
        end = self.transcribe_retained_audio()
        self.refresh_coverage(duration_override=math.ceil(end))
        self.manifest["coverage"]["complete"] = False
        self.manifest["coverage"]["captureEndUnknown"] = True
        self.manifest["status"] = "incomplete"
        self.manifest["failure"] = Failure("recovery", "capture_end_unknown", False).public()
        self.manifest["finalizedAt"] = None
        self.state["finalizationStage"] = "partial"
        self.persist()

    def finalize(self):
        initial_status = self.manifest["status"]
        if self.manifest["endedAt"] is None:
            raise Failure("recovery", "capture_end_unknown", False)
        self.verify_retained_audio()
        self.transcribe_retained_audio()
        self.refresh_coverage()
        if initial_status != "ready":
            self.state["finalizationStage"] = "transcribed"
            self.persist()
            # The worker already owns writer.lock. Its rename does not take
            # command.lock: other commands can resolve the atomic current
            # pointer or its same-ID rename recovery while finalization runs.
            if self.state.get("invocationId") and os.environ.get("INVOCATION_ID") == self.state["invocationId"]:
                original = self.directory
                try:
                    organized = organize_recording(original, self.config, active_owner=True)
                    if organized != original and not self.adopt_renamed_directory(original):
                        raise Failure("organization", "rename_recovery_failed", False)
                except (Failure, OSError) as error:
                    if not self.adopt_renamed_directory(original):
                        # An unchanged source may be organized after cleanup.
                        # A lost source must never be recreated by persistence.
                        self.verify_directory_identity()
                    journal_event({"event": "record_call_directory_organization", "level": "warning",
                                   "code": error.code if isinstance(error, Failure) else "rename_failed"})
        if not (self.manifest["coverage"]["complete"] or self.manifest["coverage"]["acceptedMinorGaps"]):
            raise Failure("capture", "incomplete_audio_coverage", False)
        diarization_failed = initial_status != "ready" and not self.attempt_diarization()
        self.state["finalizationStage"] = "complete"
        self.manifest["status"] = "ready"
        self.manifest["failure"] = None
        self.manifest["finalizedAt"] = utc_now()
        self.persist()
        if diarization_failed:
            self.notify_diarization_failure()

    def run(self, mode="capture"):
        invocation = os.environ.get("INVOCATION_ID")
        if not invocation:
            raise Failure("startup", "owned_unit_required", False)
        # The controller checked the previous owner and holds this lock while
        # systemd acknowledges execve. Wait for that explicit handoff; the new
        # owner must not fail merely because its launcher has not returned yet.
        with locked(self.private / "writer.lock", blocking=True):
            self.state["invocationId"] = invocation
            self.state["bootId"] = boot_id()
            if mode == "diarize":
                self.persist_state()
            else:
                self.persist()
            signal.signal(signal.SIGTERM, lambda *_: self.stop_event.set())
            signal.signal(signal.SIGINT, lambda *_: self.stop_event.set())
            if mode == "diarize":
                succeeded = self.attempt_diarization()
                if not succeeded:
                    self.notify_diarization_failure()
                return 0 if succeeded else 1
            try:
                if mode == "capture":
                    self.capture()
                else:
                    # The old unit is stopped and this writer owns the lock.
                    # A final muxer row may have committed after the last state
                    # snapshot but before an interrupted finalizer exited.
                    self.collect_fragments()
                if mode == "salvage":
                    self.salvage_retained()
                else:
                    self.finalize()
            except (Failure, subprocess.SubprocessError, OSError, ValueError) as error:
                for side in list(self.captures):
                    self.stop_capture(side)
                self.cleanup_modules()
                self.refresh_coverage()
                failure = error if isinstance(error, Failure) else Failure("processing", "recorder_command_failed")
                if self.manifest["endedAt"] is None:
                    # A failed startup has no trustworthy capture end. It cannot
                    # be resumed by retry, which only processes retained audio.
                    failure.retryable = False
                self.manifest["status"] = "incomplete"
                self.manifest["failure"] = failure.public()
                self.manifest["finalizedAt"] = utc_now() if self.manifest["endedAt"] is not None else None
                self.persist()
                journal_event({"event": "record_call_result", "level": "warning", "outcome": "incomplete",
                               "code": failure.code, "stage": failure.stage,
                               "durationMs": self.manifest["coverage"]["durationMs"],
                               "sampleClockShortfallMs": {
                                   side: self.manifest["coverage"]["sides"][side].get("sampleClockShortfallMs", 0)
                                   for side in SIDES}})
                return 1
        return 0


def owner_properties(state, config):
    result = subprocess.run([config["systemctl"], "--user", "show", state["unit"],
                             "--property=ActiveState,InvocationID"], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, timeout=5, check=False)
    return dict(line.split("=", 1) for line in result.stdout.decode().splitlines() if "=" in line)


def state_root():
    return Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "record-call"


def current_directory():
    pointer = state_root() / "current.json"
    if not pointer.exists():
        return None
    value = read_json(pointer)
    directory = Path(value["directory"])
    if not directory.exists():
        candidates = []
        bases = {directory.name, re.sub(r"-transcribed(?:-diarized)?(?:-processed)?$", "", directory.name)}
        for base in bases:
            for suffix in ("", "-transcribed", "-transcribed-diarized", "-transcribed-processed",
                           "-transcribed-diarized-processed"):
                candidate = directory.with_name(base + suffix)
                manifest = candidate / "recording.json"
                if (candidate.is_dir() and not candidate.is_symlink() and manifest.is_file()
                        and not manifest.is_symlink()
                        and read_json(manifest).get("recordingId") == value.get("recordingId")
                        and candidate not in candidates):
                    candidates.append(candidate)
        if len(candidates) == 1:
            return candidates[0]
    return directory


def rename_noreplace(directory, target, parent=None, source_stat=None):
    owned_parent = parent is None
    if owned_parent:
        parent = os.open(directory.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        if source_stat is not None:
            current = os.stat(directory.name, dir_fd=parent, follow_symlinks=False)
            if ((current.st_dev, current.st_ino) != (source_stat.st_dev, source_stat.st_ino)
                    or not stat.S_ISDIR(current.st_mode)):
                raise Failure("organization", "recording_changed", False)
        libc = ctypes.CDLL(None, use_errno=True)
        renameat2 = libc.renameat2
        renameat2.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p,
                              ctypes.c_uint)
        renameat2.restype = ctypes.c_int
        if renameat2(parent, os.fsencode(directory.name), parent, os.fsencode(target.name), 1) != 0:
            code = ctypes.get_errno()
            raise OSError(code, os.strerror(code), str(target))
        os.fsync(parent)
    finally:
        if owned_parent:
            os.close(parent)


def read_json_at(directory, name):
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    with os.fdopen(descriptor) as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise Failure("organization", "recording_state_missing", False)
        return json.load(source)


def atomic_json_at(directory, name, value):
    temporary = f".{name}.{uuid.uuid4().hex}"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=directory)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write((json.dumps(value, ensure_ascii=False, allow_nan=False) + "\n").encode())
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
        os.fsync(directory)
    finally:
        try:
            os.unlink(temporary, dir_fd=directory)
        except FileNotFoundError:
            pass


@contextmanager
def locked_existing_at(directory, name):
    descriptor = os.open(name, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    with os.fdopen(descriptor) as handle:
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            raise Failure("organization", "recording_state_missing", False)
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Failure("recovery", "recording_busy") from None
        yield


@contextmanager
def opened_directory(path, parent=None):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
    try:
        yield descriptor
    finally:
        os.close(descriptor)


def recording_base_name(path, state):
    base = state.get("directoryBaseName") or re.sub(
        r"-transcribed(?:-diarized)?(?:-processed)?$", "", path.name)
    if not isinstance(base, str) or not base or base in (".", "..") or Path(base).name != base:
        raise Failure("organization", "invalid_directory_name", False)
    return base


def rebase_state_paths(state, old, new):
    for side in SIDES:
        for fragment in state["fragments"][side]:
            path = Path(fragment["path"]) if isinstance(fragment.get("path"), str) else None
            if path is not None and path.is_relative_to(old):
                fragment["path"] = str(new / path.relative_to(old))
        for run in state["runs"][side]:
            path = Path(run["list"]) if isinstance(run.get("list"), str) else None
            if path is not None and path.is_relative_to(old):
                run["list"] = str(new / path.relative_to(old))
    state["directoryPath"] = str(new)


def organize_recording(directory, config, expected_id=None, expected_revision=None,
                       expected_sha=None, processed=False, active_owner=False,
                       invalidate_processed=False, expected_path=None):
    if processed and invalidate_processed:
        raise Failure("organization", "invalid_milestone_request", False)
    if (processed or invalidate_processed) and (not expected_id or expected_revision is None
                                              or not expected_sha or (invalidate_processed and not expected_path)):
        raise Failure("organization", "expected_recording_required", False)
    with (nullcontext() if active_owner else locked(state_root() / "command.lock")):
        path = Path(os.path.abspath(directory))
        with opened_directory(path.parent) as parent, \
             opened_directory(path.name, parent) as recording, \
             opened_directory(".record-call", recording) as private, \
             (nullcontext() if active_owner else locked_existing_at(private, "writer.lock")):
            recording_stat = os.fstat(recording)
            manifest, state = read_json_at(recording, "recording.json"), read_json_at(private, "state.json")
            if manifest.get("recordingId") != state.get("recordingId"):
                raise Failure("organization", "recording_state_mismatch", False)
            base = recording_base_name(path, state)
            if path.name not in (base, base + "-transcribed", base + "-transcribed-diarized",
                                 base + "-transcribed-processed", base + "-transcribed-diarized-processed"):
                raise Failure("organization", "invalid_directory_name", False)
            prior_directory = state.get("directoryPath")
            if prior_directory and Path(prior_directory) != path:
                rebase_state_paths(state, Path(prior_directory), path)
            if expected_id is not None and (manifest["recordingId"] != expected_id
                    or manifest["revision"] != expected_revision):
                raise Failure("organization", "recording_changed", False)
            revocation_pending = bool(state.get("processedRevocationPending"))
            transcript = manifest["source"]["transcript"]
            revoking = invalidate_processed or revocation_pending
            receipt_matches = (state.get("processedTranscriptSha") == expected_sha
                               and state.get("processedTranscriptPath") == expected_path)
            source_matches = (isinstance(transcript, dict) and transcript.get("sha256") == expected_sha
                              and (expected_path is None or transcript.get("path") == expected_path))
            missing_published_source = (revoking and transcript is None and (
                receipt_matches if invalidate_processed else
                revocation_pending and isinstance(state.get("processedTranscriptSha"), str)
                and isinstance(state.get("processedTranscriptPath"), str)))
            if ((processed or invalidate_processed) and not source_matches
                    and not (invalidate_processed and receipt_matches)):
                raise Failure("organization", "recording_changed", False)
            coverage = manifest.get("coverage")
            sides = coverage.get("sides") if isinstance(coverage, dict) else None
            retained_transcribed = (isinstance(sides, dict) and all(
                isinstance(sides.get(side), dict)
                and isinstance(sides[side].get("capturedMs"), (int, float))
                and not isinstance(sides[side]["capturedMs"], bool)
                and math.isfinite(sides[side]["capturedMs"])
                and sides[side]["capturedMs"] >= 0
                and sides[side]["capturedMs"] == sides[side].get("transcribedMs")
                for side in SIDES))
            capture_failure = manifest.get("failure")
            legacy_transcribed = (manifest["status"] == "incomplete"
                                  and state.get("finalizationStage") == "transcribing"
                                  and manifest.get("finalizedAt") is not None
                                  and isinstance(capture_failure, dict)
                                  and capture_failure.get("stage") == "capture"
                                  and capture_failure.get("code") == "incomplete_audio_coverage"
                                  and retained_transcribed)
            transcribed_stage = (manifest["status"] in ("finalizing", "incomplete")
                                 and (state.get("finalizationStage") == "transcribed" or legacy_transcribed)
                                 and manifest.get("endedAt") is not None
                                 and isinstance(transcript, dict) and transcript.get("path") == "transcript.turns.txt")
            if ((manifest["status"] != "ready" and not transcribed_stage and not revoking)
                    or not isinstance(transcript, dict) and not missing_published_source):
                if processed:
                    raise Failure("organization", "transcript_not_ready", False)
                return path
            source_name = (transcript.get("path", "") if isinstance(transcript, dict)
                           else expected_path or state.get("processedTranscriptPath"))
            if (not isinstance(source_name, str) or Path(source_name).name != source_name
                    or source_name in ("", ".", "..")):
                raise Failure("organization", "invalid_transcript", False)
            source_verified = False
            if isinstance(transcript, dict):
                try:
                    source = os.open(source_name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                     dir_fd=recording)
                    with os.fdopen(source, "rb") as content:
                        source_stat = os.fstat(content.fileno())
                        source_verified = (stat.S_ISREG(source_stat.st_mode)
                                           and source_stat.st_size == transcript.get("bytes")
                                           and hashlib.file_digest(content, "sha256").hexdigest() == transcript.get("sha256"))
                except OSError:
                    if not revoking:
                        raise
            if not source_verified and not revoking:
                raise Failure("organization", "transcript_changed", False)
            invocation = state.get("invocationId")
            if active_owner:
                # Called only by the worker while it holds this writer lock.
                # Its systemd invocation and boot identity are the same owned
                # handoff that run() records before starting finalization.
                if (not invocation or os.environ.get("INVOCATION_ID") != invocation
                        or state.get("bootId") != boot_id()):
                    raise Failure("organization", "recording_busy", False)
            elif not invocation:
                raise Failure("organization", "recording_busy", False)
            elif state.get("cleanupCompletedInvocationId") != invocation:
                # A worker may have persisted READY and then crashed before
                # ExecStopPost wrote its private cleanup receipt. The command
                # and writer locks are held here; only a stopped systemd owner
                # can be recovered without changing the public revision.
                if not state.get("bootId") or not state.get("unit"):
                    raise Failure("organization", "recording_busy", False)
                properties = owner_properties(state, config)
                if properties.get("ActiveState") not in ("inactive", "failed"):
                    raise Failure("organization", "recording_busy", False)
                if state["bootId"] == boot_id():
                    recovered = Session(path, config)
                    recovered.cleanup_modules()
                    if recovered.state.get("cleanupWarning"):
                        state["cleanupWarning"] = recovered.state["cleanupWarning"]
                state["cleanupCompletedInvocationId"] = invocation
                atomic_json_at(private, "state.json", state)
            publishable_incomplete = (manifest["status"] == "incomplete" and transcribed_stage
                                      and manifest.get("finalizedAt") is not None
                                      and isinstance(capture_failure, dict)
                                      and capture_failure.get("stage") == "capture"
                                      and capture_failure.get("code") == "incomplete_audio_coverage"
                                      and transcript.get("speechTurns", 0) > 0)
            if processed and manifest["status"] != "ready" and not publishable_incomplete:
                raise Failure("organization", "transcript_not_ready", False)
            if processed and state.get("processedRevocationPending"):
                raise Failure("organization", "revocation_pending", False)
            if invalidate_processed:
                # Keep the prior receipt until the no-replace rename commits.
                # A collision or crash before that point must remain retryable.
                state["processedRevocationPending"] = True
            elif processed:
                state["processedTranscriptSha"] = expected_sha
                state["processedTranscriptPath"] = source_name
            # The READY manifest pins this immutable, hash-checked artifact.
            # A later failed diarization attempt must not erase an achieved label.
            diarized = source_verified and bool(re.fullmatch(
                r"transcript\.diarized\.(?:[0-9a-f]{32}\.)?turns\.txt", source_name))
            marked_processed = (not state.get("processedRevocationPending") and source_verified
                                and state.get("processedTranscriptSha") == transcript["sha256"]
                                and state.get("processedTranscriptPath") == source_name)
            if not marked_processed and not state.get("processedRevocationPending"):
                if (state.get("processedTranscriptSha") is not None
                        or state.get("processedTranscriptPath") is not None):
                    # A verified replacement also revokes the old publication.
                    # Keep its receipt until the directory loses -processed.
                    state["processedRevocationPending"] = True
            state["directoryBaseName"] = base
            state.setdefault("directoryPath", str(path))
            atomic_json_at(private, "state.json", state)
            suffix = ("-transcribed" + ("-diarized" if diarized else "")
                      + ("-processed" if marked_processed else "")) if source_verified else ""
            target = path.with_name(base + suffix)
            if target != path:
                try:
                    rename_noreplace(path, target, parent, recording_stat)
                except FileExistsError:
                    raise Failure("organization", "milestone_name_exists", False) from None
            rebase_state_paths(state, Path(state["directoryPath"]), target)
            if state.get("processedRevocationPending"):
                state.pop("processedTranscriptSha", None)
                state.pop("processedTranscriptPath", None)
                state.pop("processedRevocationPending", None)
            atomic_json_at(private, "state.json", state)
            pointer = state_root() / "current.json"
            if pointer.exists():
                current = read_json(pointer)
                prior = Path(current["directory"])
                if (current.get("recordingId") == manifest["recordingId"] and prior.parent == path.parent
                        and recording_base_name(prior, state) == base):
                    atomic_json(pointer, {**current, "directory": str(target)})
            return target


def neutral_manifest_metadata(manifest, coverage):
    """Validate the public metadata needed for this read-only display decision."""
    def integer(value, maximum=9007199254740991):
        return (isinstance(value, (int, float)) and not isinstance(value, bool)
                and 0 <= value <= maximum and math.isfinite(value) and value == int(value))

    def instant(value):
        if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z", value):
            return None
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None

    if (not isinstance(manifest, dict) or not integer(manifest.get("schemaVersion"))
            or manifest["schemaVersion"] != 1 or not isinstance(manifest.get("recordingId"), str)
            or not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", manifest["recordingId"])
            or not integer(manifest.get("revision")) or not isinstance(coverage, dict)
            or coverage.get("complete") is not False
            or "acceptedMinorGaps" in coverage and type(coverage["acceptedMinorGaps"]) is not bool
            or not integer(coverage.get("durationMs")) or coverage["durationMs"] <= 0):
        return False
    started, ended, finalized = (instant(manifest.get(name)) for name in ("startedAt", "endedAt", "finalizedAt"))
    if started is None or ended is None or finalized is None or ended < started or finalized < ended:
        return False
    elapsed = ended - started
    if elapsed.days * 86400000 + elapsed.seconds * 1000 + elapsed.microseconds // 1000 != coverage["durationMs"]:
        return False
    zone = manifest.get("timeZone")
    # ZoneInfo also opens private posix/right trees; they are not public IANA IDs.
    if (not isinstance(zone, str) or not zone or len(zone) > 100
            or zone == "Factory" or zone not in available_timezones()):
        return False
    try:
        ZoneInfo(zone)
    except (KeyError, ValueError):
        return False
    source = manifest.get("source")
    transcript = source.get("transcript") if isinstance(source, dict) and source.get("kind") == "record-call" else None
    if not isinstance(transcript, dict):
        return False
    name = transcript.get("path")
    if (not isinstance(name, str) or not name or len(name.encode("utf-16-le", "surrogatepass")) > 510
            or name in (".", "..", "recording.json") or re.search(r"[\\/\x00-\x1f\x7f]", name)
            or not integer(transcript.get("bytes"), 8388608) or transcript["bytes"] == 0
            or not integer(transcript.get("speechTurns"), 1000000) or transcript["speechTurns"] == 0
            or not isinstance(transcript.get("sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", transcript["sha256"])):
        return False
    if "failure" not in manifest:
        return False
    failure = manifest["failure"]
    if manifest.get("status") == "ready":
        return failure is None and coverage.get("acceptedMinorGaps") is True
    return (manifest.get("status") == "incomplete" and isinstance(failure, dict)
            and failure.get("stage") == "capture" and failure.get("code") == "incomplete_audio_coverage"
            and failure.get("retryable") is False
            and ("side" not in failure or failure["side"] in SIDES)
            and ("windowIndex" not in failure or integer(failure["windowIndex"])))


def transcript_ready_without_coverage_warning(session):
    """Derive display policy without changing the producer's capture evidence."""
    manifest = session.manifest
    if not isinstance(manifest, dict):
        return False
    coverage = manifest.get("coverage")
    if (not neutral_manifest_metadata(manifest, coverage)
            or "captureEndUnknown" in coverage and coverage["captureEndUnknown"] is not False):
        return False

    def milliseconds(value):
        return (isinstance(value, (int, float)) and not isinstance(value, bool)
                and 0 <= value <= 9007199254740991 and math.isfinite(value))

    duration = coverage.get("durationMs")
    sides = coverage.get("sides")
    if not milliseconds(duration) or duration <= 0 or not isinstance(sides, dict):
        return False
    uncertainty = 0
    minor = coverage.get("acceptedMinorGaps") is True
    minor_budget = min(MAX_MINOR_GAPS_PER_SIDE_MS, duration * MAX_MINOR_GAP_FRACTION)
    if minor and duration < MIN_MINOR_GAP_DURATION_MS:
        return False
    minor_count = 0
    for name in SIDES:
        side = sides.get(name)
        if (not isinstance(side, dict)
                or "captureEndUnknown" in side and side["captureEndUnknown"] is not False):
            return False
        start, end = side.get("captureStartMs"), side.get("captureEndMs")
        captured, transcribed = side.get("capturedMs"), side.get("transcribedMs")
        if (not all(milliseconds(value) for value in (start, end, captured, transcribed))
                or end < start or captured > end - start + 1 or transcribed != captured
                or manifest["status"] == "incomplete" and end > duration):
            return False
        shortfall = side.get("sampleClockShortfallMs", 0)
        if not milliseconds(shortfall) or shortfall > duration:
            return False
        missing = side.get("missing")
        if not isinstance(missing, list) or len(missing) > 1000:
            return False
        gaps = [(0, min(duration, start)), (min(duration, end), duration)]
        previous_end, located_capture, minor_ms, known_capture_ms, continuous_start = 0, 0, 0, 0, 0
        for gap in missing:
            if not isinstance(gap, dict):
                return False
            gap_start, gap_end = gap.get("startMs"), gap.get("endMs")
            reason = gap.get("reason")
            if (not milliseconds(gap_start) or not milliseconds(gap_end)
                    or gap_start >= gap_end or gap_start < previous_end
                    or not isinstance(reason, str) or not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", reason)
                    or reason == "not_transcribed"):
                return False
            if minor:
                if gap_start > previous_end:
                    continuous_start = gap_start
                if (reason not in MINOR_GAP_REASONS or gap_end > duration
                        or gap_end - continuous_start > MAX_MINOR_GAP_MS):
                    return False
                minor_ms += gap_end - gap_start
                minor_count += 1
                if reason == "capture_gap":
                    known_capture_ms += gap_end - gap_start
            gaps.append((min(duration, gap_start), min(duration, gap_end)))
            if reason == "capture_gap":
                located_capture += max(0, min(end, gap_end) - max(start, gap_start))
            previous_end = gap_end
        if minor and (minor_ms > minor_budget or start > EDGE_TOLERANCE_MS
                      or abs(end - duration) > EDGE_TOLERANCE_MS or "sampleClockShortfallMs" in side
                      or abs(end - start - captured - known_capture_ms) > 1):
            return False
        union, through = 0, 0
        for gap_start, gap_end in sorted(gaps):
            union += max(0, gap_end - max(through, gap_start))
            through = max(through, gap_end)
        uncertainty += min(duration, union + max(0, end - start - captured - located_capture))
    if uncertainty >= 30000 or minor and minor_count == 0 or manifest["status"] == "incomplete" and uncertainty <= 0:
        return False
    transcript = manifest["source"]["transcript"]
    name = transcript["path"]
    try:
        descriptor = os.open(session.directory / name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as content:
            metadata = os.fstat(content.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size != transcript["bytes"]:
                return False
            data = content.read(int(transcript["bytes"]) + 1)
            return (len(data) == transcript["bytes"] and hashlib.sha256(data).hexdigest() == transcript["sha256"]
                    and re.search(r"[^\s\ufeff]", data.decode("utf-8")) is not None)
    except (OSError, ValueError):
        return False


def status(directory, config):
    if directory is None:
        legacy = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "record-call/session.env"
        return {"status": "incomplete" if legacy.exists() else "idle", "failure": {
            "stage": "recovery", "code": "legacy_recording_state", "retryable": False} if legacy.exists() else None}
    session = Session(directory, config)
    result = dict(session.manifest)
    result["transcriptReadyWithoutCoverageWarning"] = transcript_ready_without_coverage_warning(session)
    result["outputDir"] = str(session.directory)
    result["sinkName"] = session.state["sink"]
    result["captureIssues"] = session.state.get("captureIssues", [])
    result["routingWarning"] = session.state.get("routingWarning")
    result["micSourceWarning"] = session.state.get("micSourceWarning")
    result["diarization"] = session.state.get("diarization") or {
        "status": "pending",
        "attempts": 0,
        "failure": None,
    }
    if result["status"] == "ready" and result["diarization"]["status"] == "running":
        result["status"] = "diarizing"
    if result["status"] in ACTIVE:
        properties = owner_properties(session.state, config)
        launching = session.state.get("invocationId") is None and session.state["bootId"] == boot_id() and properties.get("ActiveState") in ("active", "activating")
        if not launching and not owner_matches(session.state, boot_id(), properties):
            if result["status"] == "diarizing":
                # Losing an enhancement worker cannot revoke an already
                # published base transcript.
                result["status"] = "ready"
                result["diarization"] = {
                    **result["diarization"],
                    "status": "failed",
                    "failure": {"code": "diarization_owner_lost", "retryable": True},
                }
            else:
                # The manifest remains historical evidence. Reconciliation
                # never fabricates endedAt or silently changes stale capture
                # work to READY.
                result["status"] = "incomplete"
                result["failure"] = {"stage": "recovery", "code": "recording_owner_lost", "retryable": result["endedAt"] is not None}
    if result["status"] == "finalizing":
        result["finalization"] = session.finalization_progress()
        result["finalization"]["stage"] = session.state.get("finalizationStage", "transcribing")
    result["salvageable"] = (result["status"] == "incomplete" and result["endedAt"] is None
                             and result["source"].get("transcript") is None
                             and session.has_retained_audio_candidate())
    return result


def ensure_models(config, state):
    if state["whisperServerUrl"]:
        return
    for key, url in (("model", "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"),
                     ("vadModel", "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")):
        target = Path(state[key])
        if target.exists():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(prefix="model-", dir=target.parent)
        os.close(descriptor)
        try:
            subprocess.run([config["curl"], "-fL", "--max-time", "1800", "-o", temporary, url], check=True)
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)


def launch_unit(session, config_path, mode):
    invocation = "record-call-" + session.manifest["recordingId"] + "-" + uuid.uuid4().hex[:8]
    session.state["unit"] = invocation + ".service"
    session.state["invocationId"] = None
    if mode == "diarize":
        prior = session.state.get("diarization") or {}
        session.state["diarization"] = {
            "status": "running",
            "attempts": int(prior.get("attempts", 0)),
            "startedAt": utc_now(),
            "finishedAt": None,
            "failure": None,
        }
        session.persist_state()
    else:
        session.manifest["status"] = "finalizing" if mode in ("retry", "salvage") else "starting"
        session.persist()
    cleanup = [session.config["python"], str(Path(__file__).resolve()), "--config", str(config_path),
               "_cleanup", str(session.directory), "--expected-id", session.manifest["recordingId"]]
    # systemd-run parses the transient ExecStopPost arguments (no shell).
    # Disable $ expansion with ':'. Transient D-Bus argv does not perform unit
    # specifier expansion; '%' must remain literal, unlike a unit-file value.
    cleanup_property = "--property=ExecStopPost=:" + " ".join(systemd_argument(argument) for argument in cleanup)
    command = [session.config["systemdRun"], "--user", "--collect", "--quiet", "--unit=" + invocation,
               "--expand-environment=no",
               "--property=Type=exec", "--property=KillMode=control-group", "--property=TimeoutStopSec=15s",
               "--property=UMask=0077", "--property=Restart=no", cleanup_property,
               session.config["python"], str(Path(__file__).resolve()),
               "--config", str(config_path),
               {"capture": "_run", "retry": "_retry", "salvage": "_salvage", "diarize": "_diarize"}[mode],
               str(session.directory)]
    atomic_json(state_root() / "current.json", {"recordingId": session.manifest["recordingId"], "directory": str(session.directory)})
    subprocess.run(command, check=True)


def systemd_argument(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r") + '"'


def cleanup_after_owner(directory, config, expected_id=None):
    original = Path(os.path.abspath(directory))
    if not original.exists():
        if not expected_id:
            raise Failure("recovery", "cleanup_directory_missing", False)
        bases = {original.name, re.sub(r"-transcribed(?:-diarized)?(?:-processed)?$", "", original.name)}
        suffixes = ("-transcribed", "-transcribed-diarized", "-transcribed-processed",
                    "-transcribed-diarized-processed")
        matches = []
        with opened_directory(original.parent) as parent:
            for base in bases:
                for suffix in suffixes:
                    candidate = original.with_name(base + suffix)
                    try:
                        with opened_directory(candidate.name, parent) as recording, \
                             opened_directory(".record-call", recording) as private:
                            manifest = read_json_at(recording, "recording.json")
                            state = read_json_at(private, "state.json")
                            actual_base = recording_base_name(candidate, state)
                            prior_names = (actual_base,) + tuple(actual_base + item for item in suffixes)
                            if (manifest.get("recordingId") == expected_id == state.get("recordingId")
                                    and state.get("invocationId") == os.environ.get("INVOCATION_ID")
                                    and original.name in prior_names
                                    and candidate not in matches):
                                matches.append(candidate)
                    except (Failure, OSError, ValueError, KeyError, TypeError):
                        continue
        if len(matches) != 1:
            raise Failure("recovery", "cleanup_directory_missing", False)
        directory = matches[0]
    session = Session(directory, config)
    if expected_id is not None and session.manifest.get("recordingId") != expected_id:
        raise Failure("recovery", "cleanup_owner_mismatch", False)
    invocation = os.environ.get("INVOCATION_ID")
    properties = owner_properties(session.state, config)
    if not invocation or session.state["bootId"] != boot_id() or properties.get("InvocationID") != invocation:
        raise Failure("recovery", "cleanup_owner_mismatch", False)
    if session.state.get("invocationId") not in (None, invocation):
        raise Failure("recovery", "cleanup_owner_mismatch", False)
    with locked(session.private / "writer.lock", blocking=True):
        session.cleanup_modules()
        session.state["cleanupCompletedInvocationId"] = invocation
        if session.manifest["status"] in ACTIVE:
            session.manifest["status"] = "incomplete"
            session.manifest["failure"] = {"stage": "recovery", "code": "recording_owner_lost",
                                           "retryable": session.manifest["endedAt"] is not None}
            session.manifest["finalizedAt"] = None
            session.persist()
        elif (session.state.get("diarization") or {}).get("status") == "running":
            prior = session.state["diarization"]
            session.state["diarization"] = {
                **prior,
                "status": "failed",
                "finishedAt": utc_now(),
                "failure": {"code": "diarization_owner_lost", "retryable": True},
            }
            session.persist_state()
        else:
            # READY may already be reserved by Fulcrum. Ownership cleanup must
            # not change that public descriptor or its revision after release.
            atomic_json(session.private / "state.json", session.state)
    if session.manifest["status"] == "ready":
        try:
            organize_recording(session.directory, config)
        except (Failure, OSError) as error:
            journal_event({"event": "record_call_directory_organization", "level": "warning",
                           "code": error.code if isinstance(error, Failure) else "rename_failed"})


def start(directory, config, config_path):
    with locked(state_root() / "command.lock"):
        existing = status(current_directory(), config)
        if existing["status"] in ACTIVE or (existing.get("failure") or {}).get("code") == "legacy_recording_state":
            raise Failure("startup", "recording_already_active")
        directory = Path(directory or Path.home() / "recordings/calls" / datetime.now().strftime("%Y%m%d-%H%M%S"))
        if directory.exists() and any(directory.iterdir()):
            raise Failure("startup", "output_directory_not_empty", False)
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        directory = directory.resolve()
        (directory / "chunks").mkdir(mode=0o700)
        private = directory / ".record-call"
        private.mkdir(mode=0o700)
        recording_id = str(uuid.uuid4())
        model_root = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "whisper-cpp"
        fragment = int(os.environ.get("RECORD_CALL_FRAGMENT_SEC", "5")) * 1000
        window = int(os.environ.get("RECORD_CALL_WINDOW_SEC", "45")) * 1000
        advance = int(os.environ.get("RECORD_CALL_ADVANCE_SEC", "30")) * 1000
        if not 1000 <= fragment <= advance <= window <= 300000 or window % fragment or advance % fragment:
            raise Failure("startup", "invalid_window_configuration", False)
        state = {"recordingId": recording_id, "directoryBaseName": directory.name,
                 "directoryPath": str(directory),
                 "unit": "", "invocationId": None, "bootId": boot_id(),
                 "sink": "record-call-" + recording_id, "modules": {}, "runs": {side: [] for side in SIDES},
                 "fragments": {side: [] for side in SIDES}, "gaps": [], "fragmentMs": fragment,
                 "windowMs": window, "advanceMs": advance, "turnGap": int(os.environ.get("RECORD_CALL_TURN_GAP_SEC", "8")),
                 "whisperServerUrl": os.environ.get("WHISPER_SERVER_URL", config["defaultWhisperServerUrl"]),
                 "diarizationServerUrl": os.environ.get("DIARIZATION_SERVER_URL", config["defaultDiarizationServerUrl"]),
                 "diarizationModel": os.environ.get("DIARIZATION_MODEL", config["diarizationModel"]),
                 "finalizationStage": "capturing",
                 "diarization": {"status": "pending", "attempts": 0, "failure": None},
                 "model": str(model_root / "ggml-large-v3-turbo.bin"), "vadModel": str(model_root / "ggml-silero-v5.1.2.bin")}
        ensure_models(config, state)
        atomic_json(private / "state.json", state)
        atomic_json(directory / "recording.json", new_manifest(recording_id, utc_now(), capture_zone()))
        atomic_bytes(directory / "transcript.txt", b"")
        session = Session(directory, config)
        launch_unit(session, config_path, "capture")
        print("Starting recording: " + str(directory))


def stop(config):
    with locked(state_root() / "command.lock"):
        directory = current_directory()
        if directory is None:
            print("No owned recording is active.")
            return
        session = Session(directory, config)
        if not owner_matches(session.state, boot_id(), owner_properties(session.state, config)):
            raise Failure("recovery", "recording_owner_lost", False)
        if session.manifest["status"] == "recording":
            atomic_json(session.private / "stop.json", {"invocationId": session.state["invocationId"]})
        print("Finalizing recording: " + str(directory))


def retry(directory, config, config_path):
    with locked(state_root() / "command.lock"):
        session = Session(directory, config)
        if status(current_directory(), config)["status"] in ACTIVE:
            raise Failure("recovery", "recording_busy")
        if session.manifest["status"] == "ready":
            print("Recording is already ready.")
            return
        if session.manifest["endedAt"] is None:
            raise Failure("recovery", "capture_end_unknown", False)
        properties = owner_properties(session.state, config)
        if properties.get("ActiveState") in ("active", "activating", "deactivating"):
            raise Failure("recovery", "recording_busy")
        with locked(session.private / "writer.lock"):
            launch_unit(session, config_path, "retry")
        print("Retrying retained transcription: " + str(session.directory))


def salvage(directory, config, config_path):
    with locked(state_root() / "command.lock"):
        session = Session(directory, config)
        if status(current_directory(), config)["status"] in ACTIVE:
            raise Failure("recovery", "recording_busy")
        if session.manifest["endedAt"] is not None:
            raise Failure("recovery", "capture_end_known", False)
        if not session.has_retained_audio_candidate():
            raise Failure("recovery", "no_retained_audio", False)
        properties = owner_properties(session.state, config)
        if properties.get("ActiveState") in ("active", "activating", "deactivating"):
            raise Failure("recovery", "recording_busy")
        with locked(session.private / "writer.lock"):
            launch_unit(session, config_path, "salvage")
        print("Verifying and salvaging retained audio: " + str(session.directory))


def retry_diarization(directory, config, config_path, force=False):
    with locked(state_root() / "command.lock"):
        session = Session(directory, config)
        if status(current_directory(), config)["status"] in ACTIVE:
            raise Failure("diarization", "recording_busy")
        if session.manifest["status"] != "ready":
            raise Failure("diarization", "base_transcript_not_ready", False)
        if not force and (session.state.get("diarization") or {}).get("status") == "ready":
            print("Recording is already diarized.")
            return
        properties = owner_properties(session.state, config)
        if properties.get("ActiveState") in ("active", "activating", "deactivating"):
            raise Failure("diarization", "recording_busy")
        session.state["diarizationServerUrl"] = os.environ.get(
            "DIARIZATION_SERVER_URL",
            config["defaultDiarizationServerUrl"],
        )
        session.state["diarizationModel"] = os.environ.get(
            "DIARIZATION_MODEL",
            config["diarizationModel"],
        )
        with locked(session.private / "writer.lock"):
            try:
                launch_unit(session, config_path, "diarize")
            except (OSError, subprocess.SubprocessError):
                prior = session.state.get("diarization") or {}
                session.state["diarization"] = {
                    **prior,
                    "status": "failed",
                    "finishedAt": utc_now(),
                    "failure": {"code": "diarization_launch_failed", "retryable": True},
                }
                session.persist_state()
                raise Failure("diarization", "diarization_launch_failed") from None
        print("Retrying participant diarization: " + str(session.directory))


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("command", choices=(
        "start", "stop", "status", "retry", "salvage", "retry-diarization", "diarize", "organize", "mark-processed", "clear-processed",
        "route", "tail", "_run", "_retry", "_salvage", "_diarize", "_cleanup"))
    parser.add_argument("directory", nargs="?")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--expected-id")
    parser.add_argument("--expected-revision", type=int)
    parser.add_argument("--expected-sha")
    parser.add_argument("--expected-path")
    arguments = parser.parse_args()
    config = read_json(arguments.config)
    try:
        if arguments.command == "start":
            start(arguments.directory, config, arguments.config)
        elif arguments.command == "stop":
            stop(config)
        elif arguments.command == "retry":
            if not arguments.directory:
                raise Failure("recovery", "recording_directory_required", False)
            retry(arguments.directory, config, arguments.config)
        elif arguments.command == "salvage":
            if not arguments.directory:
                raise Failure("recovery", "recording_directory_required", False)
            salvage(arguments.directory, config, arguments.config)
        elif arguments.command in ("retry-diarization", "diarize"):
            if not arguments.directory:
                raise Failure("diarization", "recording_directory_required", False)
            retry_diarization(
                arguments.directory,
                config,
                arguments.config,
                force=arguments.command == "diarize",
            )
        elif arguments.command in ("_run", "_retry", "_salvage", "_diarize"):
            mode = {"_run": "capture", "_retry": "retry", "_salvage": "salvage", "_diarize": "diarize"}[arguments.command]
            return Session(arguments.directory, config).run(mode)
        elif arguments.command == "_cleanup":
            cleanup_after_owner(arguments.directory, config, arguments.expected_id)
        elif arguments.command in ("organize", "mark-processed", "clear-processed"):
            if not arguments.directory:
                raise Failure("organization", "recording_directory_required", False)
            target = organize_recording(arguments.directory, config, arguments.expected_id,
                                        arguments.expected_revision, arguments.expected_sha,
                                        processed=arguments.command == "mark-processed",
                                        invalidate_processed=arguments.command == "clear-processed",
                                        expected_path=arguments.expected_path)
            print(json.dumps({"outputDir": str(target)}))
        elif arguments.command == "status":
            value = status(Path(arguments.directory) if arguments.directory else current_directory(), config)
            print(json.dumps(value) if arguments.json else "Recording " + value["status"] + (" — " + value["failure"]["code"] if value.get("failure") else ""))
        else:
            directory = current_directory()
            if directory is None:
                raise Failure("recovery", "no_owned_recording", False)
            session = Session(directory, config)
            if arguments.command == "route":
                if not owner_matches(session.state, boot_id(), owner_properties(session.state, config)):
                    raise Failure("recovery", "recording_owner_lost", False)
                session.route()
            else:
                os.execv(config["tail"], [config["tail"], "-F", str(directory / "transcript.txt")])
        return 0
    except (Failure, OSError, ValueError, subprocess.SubprocessError) as error:
        failure = error if isinstance(error, Failure) else Failure("processing", "recorder_command_failed")
        print(json.dumps({"status": "incomplete", "failure": failure.public()}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
