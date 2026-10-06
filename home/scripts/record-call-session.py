"""Owned record-call lifecycle. Only finalized, verified audio can become READY.

The public recording.json is an intake contract. Private state and immutable
window receipts live under .record-call. No shell state file is ever evaluated.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
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
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import wave
from zoneinfo import ZoneInfo

SIDES = ("call", "mic")
ACTIVE = ("starting", "recording", "finalizing")
EDGE_TOLERANCE_MS = 1000


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
                if start * multiplier > duration_ms or end * multiplier > duration_ms + 1000:
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


def calculate_coverage(captured, transcribed, duration_ms, gaps):
    result = {"complete": True, "durationMs": duration_ms, "sides": {}}
    for side in SIDES:
        spans = intervals(captured[side])
        done = intervals(transcribed[side])
        start = spans[0]["startMs"] if spans else None
        end = spans[-1]["endMs"] if spans else None
        missing = uncovered(spans, done)
        missing.extend({key: gap[key] for key in ("startMs", "endMs", "reason")}
                       for gap in gaps if gap["side"] == side)
        if not spans:
            missing.append({"startMs": 0, "endMs": max(1, duration_ms), "reason": "no_audio"})
        else:
            for previous, following in zip(spans, spans[1:]):
                missing.append({"startMs": previous["endMs"], "endMs": following["startMs"], "reason": "capture_gap"})
            if start > EDGE_TOLERANCE_MS:
                missing.append({"startMs": 0, "endMs": start, "reason": "capture_started_late"})
            if end < duration_ms - EDGE_TOLERANCE_MS:
                missing.append({"startMs": end, "endMs": duration_ms, "reason": "capture_ended_early"})
            if end > duration_ms + EDGE_TOLERANCE_MS:
                missing.append({"startMs": duration_ms, "endMs": end, "reason": "capture_clock_mismatch"})
        side_result = {"captureStartMs": start, "captureEndMs": end,
                       "capturedMs": interval_size(spans), "transcribedMs": interval_size(done),
                       "missing": missing}
        result["sides"][side] = side_result
        result["complete"] &= bool(spans) and not missing and side_result["capturedMs"] == side_result["transcribedMs"]
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


class Session:
    def __init__(self, directory, config):
        self.directory = Path(directory).resolve()
        self.private = self.directory / ".record-call"
        self.config = config
        self.manifest = read_json(self.directory / "recording.json")
        self.state = read_json(self.private / "state.json")
        self.captures = {}
        self.stop_event = threading.Event()
        self.started_monotonic = time.monotonic()

    def command(self, name, *arguments, **kwargs):
        return subprocess.run([self.config[name], *map(str, arguments)], check=True, **kwargs)

    def persist(self):
        self.manifest["revision"] += 1
        atomic_json(self.private / "state.json", self.state)
        atomic_json(self.directory / "recording.json", self.manifest)

    def elapsed(self):
        return round((time.monotonic() - self.started_monotonic) * 1000)

    def refresh_coverage(self):
        completed = {side: [] for side in SIDES}
        for receipt in sorted((self.private / "windows").glob("*/done.json")):
            value = read_json(receipt)
            for side in SIDES:
                completed[side].extend(value["coverage"][side])
        end = self.manifest["endedAt"]
        duration = round((timestamp(end) - timestamp(self.manifest["startedAt"])) * 1000) if end else self.elapsed()
        self.manifest["coverage"] = calculate_coverage(self.state["fragments"], completed,
                                                      duration, self.state["gaps"])

    def transcribe_command(self, audio, prefix):
        remote = self.state["whisperServerUrl"]
        if remote:
            return [self.config["curl"], "-fsS", "--max-time", "120", "-F", f"file=@{audio}",
                    "-F", "response_format=verbose_json", "-F", "language=en", remote]
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
            if value["parameters"] != parameters or file_hash(destination / "text.txt") != value["sha256"]:
                raise Failure("recovery", "window_changed", False, window=index)
            return
        running, errors = {}, []
        with tempfile.TemporaryDirectory(prefix="attempt-", dir=destination) as temporary, owned_children() as children:
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
                log = (destination / (side + ".log")).open("wb")
                output = prefix.with_suffix(".json").open("wb") if self.state["whisperServerUrl"] else subprocess.DEVNULL
                try:
                    child = subprocess.Popen(self.transcribe_command(audio, prefix), stdin=subprocess.DEVNULL,
                                             stdout=output, stderr=log)
                    children.append(child)
                finally:
                    if output != subprocess.DEVNULL:
                        output.close()
                    log.close()
                running[side] = (child, prefix, input_hash, time.monotonic())
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
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
                    errors.append(Failure("transcription", "asr_timeout", True, side, index))
                except Failure as error:
                    error.side, error.window = side, index
                    errors.append(error)
                finally:
                    self.bound_log(destination / (side + ".log"))
            if errors:
                atomic_json(destination / "failure.json", errors[0].public())
                raise errors[0]
        result = self.command("python", self.config["merge"], destination / "call.json", destination / "mic.json",
                              start / 1000, start / 1000, emit_end / 1000,
                              timestamp(self.manifest["startedAt"]), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              env={**os.environ, "TZ": self.manifest["timeZone"]})
        atomic_bytes(destination / "text.txt", result.stdout)
        atomic_json(receipt, {"parameters": parameters, "sha256": file_hash(destination / "text.txt"),
                             "coverage": {side: intersect(self.state["fragments"][side], start, emit_end) for side in SIDES}})

    @staticmethod
    def bound_log(path):
        if path.stat().st_size > 65536:
            with path.open("rb") as source:
                source.seek(-65536, os.SEEK_END)
                data = source.read()
            atomic_bytes(path, data)

    def assemble(self):
        receipts = sorted((self.private / "windows").glob("*/done.json"))
        chunks = []
        for index, receipt in enumerate(receipts):
            if receipt.parent.name != f"{index:06d}":
                raise Failure("assembly", "missing_window")
            value = read_json(receipt)
            data = (receipt.parent / "text.txt").read_bytes()
            if hashlib.sha256(data).hexdigest() != value["sha256"]:
                raise Failure("assembly", "window_changed", False)
            chunks.append(data)
        raw = b"".join(chunks)
        with tempfile.TemporaryDirectory(prefix="assemble-", dir=self.private) as temporary:
            temporary = Path(temporary)
            transcript = temporary / "transcript.txt"
            transcript.write_bytes(raw)
            try:
                self.command("python", self.config["dedupe"], transcript, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                self.command("python", self.config["turns"], transcript, temporary / "turns.txt", self.state["turnGap"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            except subprocess.CalledProcessError:
                raise Failure("assembly", "turns_failed") from None
            turns = (temporary / "turns.txt").read_bytes()
            atomic_bytes(self.directory / "transcript.raw.txt", raw)
            atomic_bytes(self.directory / "transcript.txt", transcript.read_bytes())
            atomic_bytes(self.directory / "transcript.turns.txt", turns)
        self.manifest["source"]["transcript"] = {"path": "transcript.turns.txt", "sha256": hashlib.sha256(turns).hexdigest(),
                                                  "bytes": len(turns), "speechTurns": sum(bool(re.match(rb"^\[\d\d:\d\d:\d\d\] ", line)) for line in turns.splitlines())}

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
        try:
            modules = json.loads(self.command("pactl", "-f", "json", "list", "modules", stdout=subprocess.PIPE,
                                               stderr=subprocess.PIPE, timeout=5).stdout)
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

    def launch_capture(self, side):
        runs = self.state["runs"][side]
        run_index = len(runs)
        listing = self.private / f"{side}-{run_index:04d}.csv"
        indices = [int(path.stem.split("_")[1]) for path in (self.directory / "chunks").glob(side + "_*.wav")
                   if re.fullmatch(side + r"_\d{6}\.wav", path.name)]
        next_index = max(indices, default=-1) + 1
        run = {"list": str(listing), "offsetMs": self.elapsed(), "seen": [], "index": run_index}
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
                    "-reset_timestamps", "1", "-segment_start_number", str(next_index),
                    "-segment_list", str(listing), "-segment_list_type", "csv", "-segment_list_size", "0",
                    str(self.directory / "chunks" / (side + "_%06d.wav"))],
                    stdin=reader.stdout, stdout=subprocess.DEVNULL, stderr=log)
        except BaseException:
            reader.terminate()
            reader.wait(timeout=5)
            raise
        finally:
            reader.stdout.close()
        self.captures[side] = (reader, segmenter)

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

    def stop_capture(self, side):
        reader, segmenter = self.captures.pop(side)
        if reader.poll() is None:
            reader.terminate()
        try:
            reader.wait(timeout=5)
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

    def route(self):
        sinks = json.loads(self.command("pactl", "-f", "json", "list", "sinks", stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, timeout=5).stdout)
        target = next((item["index"] for item in sinks if item["name"] == self.state["sink"]), None)
        if target is None:
            raise Failure("capture", "recording_sink_missing", False)
        inputs = json.loads(self.command("pactl", "-f", "json", "list", "sink-inputs", stdout=subprocess.PIPE,
                                          stderr=subprocess.PIPE, timeout=5).stdout)
        for item in inputs:
            properties = item.get("properties", {})
            application = properties.get("application.process.binary", "") + " " + properties.get("application.name", "")
            if item["sink"] != target and re.search(r"chrome|chromium|brave|google|firefox", application, re.I):
                self.command("pactl", "move-sink-input", item["index"], target, stdout=subprocess.DEVNULL,
                             stderr=subprocess.PIPE, timeout=5)

    def next_window(self):
        index = 0
        while (self.private / "windows" / f"{index:06d}" / "done.json").exists():
            index += 1
        return index

    def progress_transcript(self):
        parts = []
        for receipt in sorted((self.private / "windows").glob("*/done.json")):
            parts.append((receipt.parent / "text.txt").read_bytes())
        atomic_bytes(self.directory / "transcript.txt", b"".join(parts))

    def capture(self):
        self.setup_audio()
        self.manifest["startedAt"] = utc_now()
        self.started_monotonic = time.monotonic()
        atomic_bytes(self.directory / ".started-at", str(timestamp(self.manifest["startedAt"])).encode())
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
                        if any(child.poll() is not None for child in processes):
                            before = self.elapsed()
                            self.stop_capture(side)
                            self.collect_fragments()
                            if len(self.state["runs"][side]) >= 4:
                                raise Failure("capture", "capture_restart_limit", False, side)
                            self.launch_capture(side)
                            self.state["gaps"].append({"side": side, "startMs": before,
                                                       "endMs": max(before + 1, self.elapsed()), "reason": "capture_restarted"})
                            self.persist()
                    if time.monotonic() - routed >= 1:
                        self.route()
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

    def finalize(self):
        if self.manifest["endedAt"] is None:
            raise Failure("recovery", "capture_end_unknown", False)
        known = {Path(fragment["path"]).resolve() for side in SIDES for fragment in self.state["fragments"][side]}
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
        self.manifest["status"] = "finalizing"
        self.manifest["finalizedAt"] = None
        self.persist()
        end = max((fragment["endMs"] for side in SIDES for fragment in self.state["fragments"][side]), default=0)
        index = self.next_window()
        while index * self.state["advanceMs"] < end:
            start = index * self.state["advanceMs"]
            window_end = min(start + self.state["windowMs"], end)
            emit_end = start + self.state["advanceMs"] if start + self.state["windowMs"] < end else end
            self.process_window(index, window_end, emit_end)
            index += 1
            if emit_end == end:
                break
        self.assemble()
        self.refresh_coverage()
        if not self.manifest["coverage"]["complete"]:
            raise Failure("capture", "incomplete_audio_coverage", False)
        self.manifest["status"] = "ready"
        self.manifest["failure"] = None
        self.manifest["finalizedAt"] = utc_now()
        self.persist()

    def run(self, retry=False):
        with locked(self.private / "writer.lock"):
            self.state["invocationId"] = os.environ.get("INVOCATION_ID")
            self.state["bootId"] = boot_id()
            if not self.state["invocationId"]:
                raise Failure("startup", "owned_unit_required", False)
            self.persist()
            signal.signal(signal.SIGTERM, lambda *_: self.stop_event.set())
            signal.signal(signal.SIGINT, lambda *_: self.stop_event.set())
            try:
                if not retry:
                    self.capture()
                else:
                    # The old unit is stopped and this writer owns the lock.
                    # A final muxer row may have committed after the last state
                    # snapshot but before an interrupted finalizer exited.
                    self.collect_fragments()
                self.finalize()
            except (Failure, subprocess.SubprocessError, OSError, ValueError) as error:
                for side in list(self.captures):
                    self.stop_capture(side)
                self.cleanup_modules()
                self.refresh_coverage()
                failure = error if isinstance(error, Failure) else Failure("processing", "recorder_command_failed")
                self.manifest["status"] = "incomplete"
                self.manifest["failure"] = failure.public()
                self.manifest["finalizedAt"] = utc_now()
                self.persist()
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
    return Path(read_json(pointer)["directory"]) if pointer.exists() else None


def status(directory, config):
    if directory is None:
        legacy = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "record-call/session.env"
        return {"status": "incomplete" if legacy.exists() else "idle", "failure": {
            "stage": "recovery", "code": "legacy_recording_state", "retryable": False} if legacy.exists() else None}
    session = Session(directory, config)
    result = dict(session.manifest)
    result["outputDir"] = str(session.directory)
    result["sinkName"] = session.state["sink"]
    if result["status"] in ACTIVE:
        properties = owner_properties(session.state, config)
        launching = session.state.get("invocationId") is None and session.state["bootId"] == boot_id() and properties.get("ActiveState") in ("active", "activating")
        if not launching and not owner_matches(session.state, boot_id(), properties):
            # The manifest remains historical evidence. Reconciliation never
            # fabricates endedAt or silently changes a stale session to READY.
            result["status"] = "incomplete"
            result["failure"] = {"stage": "recovery", "code": "recording_owner_lost", "retryable": result["endedAt"] is not None}
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


def launch_unit(session, config_path, retry):
    invocation = "record-call-" + session.manifest["recordingId"] + "-" + uuid.uuid4().hex[:8]
    session.state["unit"] = invocation + ".service"
    session.state["invocationId"] = None
    session.manifest["status"] = "finalizing" if retry else "starting"
    session.persist()
    cleanup = [session.config["python"], str(Path(__file__).resolve()), "--config", str(config_path),
               "_cleanup", str(session.directory)]
    # systemd-run parses the transient ExecStopPost arguments (no shell).
    # Disable $ expansion with ':'. Transient D-Bus argv does not perform unit
    # specifier expansion; '%' must remain literal, unlike a unit-file value.
    cleanup_property = "--property=ExecStopPost=:" + " ".join(systemd_argument(argument) for argument in cleanup)
    command = [session.config["systemdRun"], "--user", "--collect", "--quiet", "--unit=" + invocation,
               "--expand-environment=no",
               "--property=Type=exec", "--property=KillMode=control-group", "--property=TimeoutStopSec=15s",
               "--property=UMask=0077", "--property=Restart=no", cleanup_property,
               session.config["python"], str(Path(__file__).resolve()),
               "--config", str(config_path), "_retry" if retry else "_run", str(session.directory)]
    atomic_json(state_root() / "current.json", {"recordingId": session.manifest["recordingId"], "directory": str(session.directory)})
    subprocess.run(command, check=True)


def systemd_argument(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r") + '"'


def cleanup_after_owner(directory, config):
    session = Session(directory, config)
    invocation = os.environ.get("INVOCATION_ID")
    properties = owner_properties(session.state, config)
    if not invocation or session.state["bootId"] != boot_id() or properties.get("InvocationID") != invocation:
        raise Failure("recovery", "cleanup_owner_mismatch", False)
    if session.state.get("invocationId") not in (None, invocation):
        raise Failure("recovery", "cleanup_owner_mismatch", False)
    with locked(session.private / "writer.lock"):
        session.cleanup_modules()
        session.state["cleanupCompletedInvocationId"] = invocation
        if session.manifest["status"] in ACTIVE:
            session.manifest["status"] = "incomplete"
            session.manifest["failure"] = {"stage": "recovery", "code": "recording_owner_lost",
                                           "retryable": session.manifest["endedAt"] is not None}
            session.manifest["finalizedAt"] = None
        session.persist()


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
        state = {"recordingId": recording_id, "unit": "", "invocationId": None, "bootId": boot_id(),
                 "sink": "record-call-" + recording_id, "modules": {}, "runs": {side: [] for side in SIDES},
                 "fragments": {side: [] for side in SIDES}, "gaps": [], "fragmentMs": fragment,
                 "windowMs": window, "advanceMs": advance, "turnGap": int(os.environ.get("RECORD_CALL_TURN_GAP_SEC", "8")),
                 "whisperServerUrl": os.environ.get("WHISPER_SERVER_URL", config["defaultWhisperServerUrl"]),
                 "model": str(model_root / "ggml-large-v3-turbo.bin"), "vadModel": str(model_root / "ggml-silero-v5.1.2.bin")}
        ensure_models(config, state)
        atomic_json(private / "state.json", state)
        atomic_json(directory / "recording.json", new_manifest(recording_id, utc_now(), capture_zone()))
        atomic_bytes(directory / "transcript.txt", b"")
        session = Session(directory, config)
        launch_unit(session, config_path, False)
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
            launch_unit(session, config_path, True)
        print("Retrying retained transcription: " + str(session.directory))


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("command", choices=("start", "stop", "status", "retry", "route", "tail", "_run", "_retry", "_cleanup"))
    parser.add_argument("directory", nargs="?")
    parser.add_argument("--json", action="store_true")
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
        elif arguments.command in ("_run", "_retry"):
            return Session(arguments.directory, config).run(arguments.command == "_retry")
        elif arguments.command == "_cleanup":
            cleanup_after_owner(arguments.directory, config)
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
