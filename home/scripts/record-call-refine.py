"""Recheck uncertain passages against context audio, without replacing text.

Whisper.cpp's older VAD responses mix compressed token times with original
segment times. Request bounded excerpts with VAD disabled, then accept only
unique, matching word sequences. Unmatched words remain explicitly unknown.
"""

import argparse
from difflib import SequenceMatcher
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import tempfile
import time
import wave


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def normalized(text):
    return "".join(c for c in text.casefold() if c.isalnum())


def timed_words(data, origin, duration):
    """Join model subwords before matching the original whitespace words."""
    tokens = []
    if "segments" in data:
        for segment in data["segments"]:
            tokens.extend((w["word"], w["start"], w["end"])
                          for w in segment.get("words", []))
    else:
        for segment in data.get("transcription", []):
            tokens.extend((w["text"], w["offsets"]["from"] / 1000, w["offsets"]["to"] / 1000)
                          for w in segment.get("tokens", []) if not w["text"].startswith("[_"))
    text, spans = "", []
    for token, start, end in tokens:
        if not finite(start) or not finite(end) or start < 0 or end < start or end > duration + 0.1:
            raise ValueError("invalid refinement timing")
        if spans and origin + start < spans[-1][2]:
            raise ValueError("nonmonotonic refinement timing")
        spans.append((len(text), len(text) + len(token), origin + start, origin + end))
        text += token
    result = []
    for match in re.finditer(r"\S+", text):
        hits = [w for w in spans if min(match.end(), w[1]) > max(match.start(), w[0])]
        key = normalized(match.group())
        if key and hits and hits[-1][3] > hits[0][2]:
            result.append({"key": key, "start": hits[0][2], "end": hits[-1][3]})
    return result


def match_words(reference, observed):
    """Use unique exact phrase anchors, never a guessed replacement word."""
    left = [normalized(w["text"]) for w in reference]
    right = [w["key"] for w in observed]
    result = {}
    for block in SequenceMatcher(None, left, right, autojunk=False).get_matching_blocks():
        if not block.size:
            continue
        phrase = left[block.a:block.a + block.size]
        # A short, repeated acknowledgment is insufficient evidence of which
        # occurrence was heard. Surrounding words must disambiguate it.
        if block.size < 3 and (len(left) != block.size or not all(phrase)):
            continue
        if any(sum(seq[i:i + len(phrase)] == phrase for i in range(len(seq) - len(phrase) + 1)) != 1
               for seq in (left, right)):
            continue
        for i in range(block.size):
            source, word = reference[block.a + i], observed[block.b + i]
            if word["end"] < source["start"] - 1 or word["start"] > source["end"] + 1:
                continue
            result[block.a + i] = {"text": source["text"], "start": word["start"], "end": word["end"]}
    return result


def plan(report, duration):
    intervals = sorted({(max(0, r["sourceOffsetMs"] / 1000 - 2),
                         min(duration, r["sourceEndMs"] / 1000 + 2))
                        for r in report["rows"] if r["speaker"] is None and r["sourceEndMs"] is not None})
    windows = []
    for start, end in intervals:
        # Do not run a second full-call ASR. Long/pathological segments retain
        # unknown labels rather than generating unbounded background work.
        if end <= start or end - start > 45:
            continue
        if windows and start <= windows[-1][1] and end - windows[-1][0] <= 45:
            windows[-1] = (windows[-1][0], max(end, windows[-1][1]))
        else:
            windows.append((start, end))
    return windows


def run(args):
    source = Path(args.transcript)
    report = json.loads(Path(args.report).read_text())
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if report["sourceSha256"] != digest:
        raise ValueError("refinement source changed")
    rows = {}
    lines = source.read_text().splitlines()
    for row in report["rows"]:
        if row["sourceEndMs"] is not None:
            rows[row["sourceLine"]] = row
    result = {"version": 1, "sourceSha256": digest, "entries": [], "requests": []}
    entries = {}
    budget = 300.0
    deadline = time.monotonic() + 300
    with wave.open(args.audio) as audio, tempfile.TemporaryDirectory(prefix="record-call-align-") as temporary:
        if audio.getparams()[:3] != (1, 2, 16000):
            raise ValueError("invalid refinement audio")
        duration = audio.getnframes() / 16000
        for start, end in plan(report, duration)[:24]:
            if end - start > budget or time.monotonic() >= deadline:
                break
            budget -= end - start
            request = {"start": start, "end": end, "status": "failed"}
            result["requests"].append(request)
            clip = Path(temporary) / "clip.wav"
            with wave.open(str(clip), "wb") as target:
                target.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.setpos(round(start * 16000))
                target.writeframes(audio.readframes(round((end - start) * 16000)))
            request["audioSha256"] = hashlib.sha256(clip.read_bytes()).hexdigest()
            try:
                timeout = max(1, min(60, deadline - time.monotonic()))
                if args.server:
                    command = [args.curl, "-fsS", "--max-time", str(int(timeout)), "-F", f"file=@{clip}",
                               "-F", "response_format=verbose_json", "-F", "language=en",
                               "-F", "vad=false", "-F", "no_timestamps=false", "-F", "temperature=0", args.server]
                    payload = subprocess.run(command, check=True, capture_output=True, timeout=timeout).stdout
                elif args.model:
                    prefix = Path(temporary) / "response"
                    subprocess.run([args.whisper, "-m", args.model, "-f", str(clip), "-l", "en",
                                    "-ojf", "-of", str(prefix)], check=True, capture_output=True, timeout=timeout)
                    payload = prefix.with_suffix(".json").read_bytes()
                else:
                    break
                observed = timed_words(json.loads(payload), start, end - start)
                reference = []
                for index, row in sorted(rows.items()):
                    a, b = row["sourceOffsetMs"] / 1000, row["sourceEndMs"] / 1000
                    if a < start or b > end:
                        continue
                    text = lines[index].split("] ", 1)[1]
                    for word_index, word in enumerate(text.split()):
                        reference.append({"text": word, "start": a, "end": b,
                                          "sourceLine": index, "wordIndex": word_index})
                    entries.setdefault(index, {"offsetMs": row["sourceOffsetMs"], "text": text,
                                               "words": [None] * len(text.split())})
                matches = match_words(reference, observed)
                for index, word in matches.items():
                    ref = reference[index]
                    entries[ref["sourceLine"]]["words"][ref["wordIndex"]] = word
                request.update(status="ready", matchedWords=len(matches), response=payload.decode(),
                               responseSha256=hashlib.sha256(payload).hexdigest())
            except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
                # Refinement is best effort. Diarization and the original
                # transcript remain usable if the ASR endpoint is unavailable.
                continue
    result["entries"] = list(entries.values())
    Path(args.output).write_text(json.dumps(result, sort_keys=True) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ("transcript", "report", "audio", "output"):
        parser.add_argument(name)
    parser.add_argument("--server", default="")
    parser.add_argument("--model", default="")
    parser.add_argument("--curl", default="curl")
    parser.add_argument("--whisper", default="whisper-cli")
    run(parser.parse_args())
