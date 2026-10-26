"""Attribute retained transcript text using verified ASR word timings.

Never invent words or resolve simultaneous speakers by majority duration.
The output includes replayable attribution evidence and matching offsets.
"""
import hashlib, json, math, os, re, sys
from pathlib import Path
from datetime import datetime, timedelta, time as clock_time
from zoneinfo import ZoneInfo
tpath, dpath, epoch_s, outpath = sys.argv[1:5]
epoch = int(epoch_s)
zone = ZoneInfo(os.environ["TZ"])
first_day = datetime.fromtimestamp(epoch, zone).date()
previous = epoch
with open(dpath) as f:
    segs = json.load(f)
offsets = None
if len(sys.argv) > 5 and os.path.isfile(sys.argv[5]):
    with open(sys.argv[5]) as f:
        offsets = json.load(f)
    if not isinstance(offsets, list):
        raise ValueError("invalid transcript offsets")

def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)

# Keep the original ASR interval: a segment can start in silence long
# before its words. The retained, hash-checked ASR receipts also let old
# recordings benefit without retranscription or changing their text.
intervals = {}
word_intervals = {}
refined_words = {}
if len(sys.argv) > 6 and Path(sys.argv[6]).is_file():
    refined = json.loads(Path(sys.argv[6]).read_text())
    if refined["sourceSha256"] != hashlib.sha256(Path(tpath).read_bytes()).hexdigest():
        raise ValueError("alignment source changed")
    for entry in refined["entries"]:
        refined_words[(entry["offsetMs"], entry["text"])] = entry["words"]
windows = Path(tpath).parent / ".record-call/windows"
for receipt_path in sorted(windows.glob("*/call.ok.json")):
    receipt = json.loads(receipt_path.read_text())
    payload = receipt_path.with_name("call.json").read_bytes()
    if hashlib.sha256(payload).hexdigest() != receipt["outputHash"]:
        raise ValueError("call ASR receipt changed")
    parameters = receipt["parameters"]
    origin, limit = parameters["startMs"], parameters["endMs"]
    if not finite(origin) or not finite(limit) or origin < 0 or limit <= origin:
        raise ValueError("invalid call ASR interval")
    data = json.loads(payload)
    if "segments" in data:
        spans = [(s["start"] * 1000, s["end"] * 1000, s["text"]) for s in data["segments"]]
    else:
        spans = [(s["offsets"]["from"], s["offsets"]["to"], s["text"]) for s in data["transcription"]]
    receipt_keys, invalid_word_timing = [], False
    for index, (start, end, text) in enumerate(spans):
        if not finite(start) or not finite(end) or start < 0 or end < start or origin + end > limit + 1000:
            raise ValueError("invalid call ASR segment")
        key = (round(origin + start), " ".join(text.split()))
        bounded_end = min(origin + end, limit) / 1000
        # Duplicate windows must never stretch the segment into a later
        # participant's turn. Use the shortest verified matching interval.
        intervals[key] = min(intervals.get(key, bounded_end), bounded_end)
        receipt_keys.append(key)
        # Historical VAD responses provide no reliable mapping from their
        # compressed token clock. Only an explicitly original-clock receipt
        # may bypass the bounded no-VAD refinement pass.
        words = (data.get("segments", [{}] * len(spans))[index].get("words") or []
                 if parameters.get("wordTimestampsTimeline") == "original" else [])
        # Duplicate receipts must agree before they can supply finer timing.
        candidate = []
        for word in words:
            a, b, token = word.get("start"), word.get("end"), word.get("word")
            if (not finite(a) or not finite(b) or a < start / 1000 - 0.01
                    or b < a or b > end / 1000 + 0.01 or not isinstance(token, str)):
                invalid_word_timing = True
                candidate = []
                break
            candidate.append((origin / 1000 + a, min(origin / 1000 + b, limit / 1000), token))
        if key not in word_intervals:
            word_intervals[key] = candidate
        elif word_intervals[key] != candidate:
            word_intervals[key] = []
    if invalid_word_timing:
        # One compressed token timeline invalidates the whole VAD receipt,
        # including tokens that accidentally fall inside a later sentence.
        for key in receipt_keys:
            word_intervals[key] = []

def speaker_at(t, end=None):
    if end is not None and end > t:
        overlaps = {s["speaker"] for s in segs if min(end, s["end"]) > max(t, s["start"])}
        if len(overlaps) == 1:
            return next(iter(overlaps))
        if len(overlaps) > 1:
            # A sentence spanning a speaker change needs word alignment;
            # picking the first or longest speaker silently misattributes it.
            return None
    # Legacy transcripts without retained ASR still support point timing.
    # Reject overlapping speakers and equidistant conflicting boundaries.
    active = {s["speaker"] for s in segs if s["start"] <= t < s["end"]}
    if len(active) == 1:
        return next(iter(active))
    if active:
        return None
    hit = None
    distance = float("inf")
    tied = False
    for s in segs:
        boundary_distance = min(abs(t - s["start"]), abs(t - s["end"]))
        if abs(boundary_distance - distance) < 1e-9:
            tied = tied or hit["speaker"] != s["speaker"]
        elif boundary_distance < distance:
            hit = s
            distance = boundary_distance
            tied = False
    if hit and distance <= 1.0 and not tied:
        return hit["speaker"]
    return None

def word_spans(text, words):
    # Whisper's "words" can be subword tokens and separate punctuation.
    # Match the entire non-whitespace character stream before using timings;
    # retain the original spelling, punctuation and whitespace in output.
    compact = "".join(text.split())
    if not words or "".join("".join(w[2].split()) for w in words) != compact:
        return []
    tokens, cursor = [], 0
    for start, end, token in words:
        size = len("".join(token.split()))
        if size:
            tokens.append((cursor, cursor + size, start, end))
            cursor += size
    result, cursor = [], 0
    for match in re.finditer(r"\S+", text):
        size = len(match.group())
        hits = [w for w in tokens if min(cursor + size, w[1]) > max(cursor, w[0])]
        if not hits:
            return []
        result.append((match.start(), match.end(), min(w[2] for w in hits), max(w[3] for w in hits)))
        cursor += size
    if any(b[2] < a[2] or b[3] < a[3] for a, b in zip(result, result[1:])):
        return []
    return result


def word_speaker(start, end):
    hits = [s for s in segs if min(end, s["end"]) > max(start, s["start"])]
    speakers = {s["speaker"] for s in hits}
    if len(speakers) != 1 or end <= start:
        return None
    # A token stretched across silence must not inherit a speaker from a
    # tiny overlap at one edge. Count the union, not duplicate segments.
    covered, previous_end = 0.0, start
    for a, b in sorted((max(start, s["start"]), min(end, s["end"])) for s in hits):
        covered += max(0, b - max(a, previous_end))
        previous_end = max(previous_end, b)
    return next(iter(speakers)) if covered >= (end - start) * 0.5 else None


def refine(text, words, verified=None):
    spans = word_spans(text, words)
    if verified is not None:
        matches = list(re.finditer(r"\S+", text))
        if len(verified) != len(matches):
            raise ValueError("invalid refined word count")
        spans = []
        for match, word in zip(matches, verified):
            if word is None:
                spans.append((match.start(), match.end(), None, None))
            elif (word["text"] == match.group() and finite(word["start"]) and finite(word["end"])
                  and 0 <= word["start"] < word["end"]):
                spans.append((match.start(), match.end(), word["start"], word["end"]))
            else:
                raise ValueError("invalid refined word")
    if not spans:
        return []
    labels = [word_speaker(a, b) if a is not None else None for _, _, a, b in spans]
    resolved = list(labels)
    reasons = ["word" if x else "overlap_or_gap" for x in labels]
    for i, (_, _, start, end) in enumerate(spans):
        if start is None or labels[i] is not None or i == 0 or i == len(spans) - 1:
            continue
        # Recheck a tiny timing discrepancy against BOTH adjacent words.
        # Never propagate guesses or bridge a different/short speaker turn.
        neighbor = labels[i - 1]
        if neighbor is None or neighbor != labels[i + 1]:
            continue
        trim = min(0.04, (end - start) * 0.1)
        conflicts = [s for s in segs if s["speaker"] != neighbor
                     and min(end, s["end"]) > max(start, s["start"])]
        if conflicts:
            if (trim > 0 and word_speaker(start + trim, end - trim) == neighbor
                    and all(s["end"] <= start + trim or s["start"] >= end - trim for s in conflicts)):
                resolved[i], reasons[i] = neighbor, "boundary_context"
        else:
            # A short hole bounded by the same acoustic speaker is different
            # from an isolated word near some arbitrary nearest speaker.
            left = [s["end"] for s in segs if s["speaker"] == neighbor and s["end"] <= start]
            right = [s["start"] for s in segs if s["speaker"] == neighbor and s["start"] >= end]
            if left and right and min(right) - max(left) <= 0.2:
                resolved[i], reasons[i] = neighbor, "gap_context"
    parts = []
    for i, ((a, b, start, end), speaker, reason) in enumerate(zip(spans, resolved, reasons)):
        a = 0 if i == 0 else spans[i - 1][1]
        b = len(text) if i == len(spans) - 1 else b
        if parts and parts[-1]["rawSpeaker"] == speaker:
            parts[-1]["end"] = b
            if reason not in parts[-1]["reasons"]:
                parts[-1]["reasons"].append(reason)
        else:
            parts.append({"start": a, "end": b, "offsetMs": round(start * 1000) if start is not None else None,
                          "rawSpeaker": speaker, "reasons": [reason]})
    return parts


# Canonical speaker id mapping: SPEAKER_00 -> Speaker 1, etc.
# Preserves first-seen order for nicer reading.
canonical = {}
def label(raw):
    if raw is None:
        return None
    if raw not in canonical:
        canonical[raw] = f"Speaker {len(canonical) + 1}"
    return canonical[raw]

def wall_epoch(h, mi, s):
    # A transcript displays only local HH:MM:SS. Resolve each stamp in
    # chronological order across midnight and both sides of a DST fold.
    # Round-to-second text may precede the precise start by < 1 second.
    for day_offset in range(3):
        day = first_day + timedelta(days=day_offset)
        naive = datetime.combine(day, clock_time(int(h), int(mi), int(s)))
        candidates = []
        for fold in (0, 1):
            instant = naive.replace(tzinfo=zone, fold=fold).timestamp()
            if datetime.fromtimestamp(instant, zone).replace(tzinfo=None) != naive:
                continue  # nonexistent local time during a spring jump
            if instant >= epoch - 1 and instant >= previous - 5:
                candidates.append(instant)
        if candidates:
            return min(candidates)
    raise ValueError("transcript time cannot be aligned")

pat = re.compile(r"^\[(\d\d):(\d\d):(\d\d)\] (.*)$")
report = {"version": 1, "sourceSha256": hashlib.sha256(Path(tpath).read_bytes()).hexdigest(),
          "rows": [], "coverage": {"totalRemoteLines": 0, "unresolvedRemoteLines": 0,
                                     "labeledRemoteWords": 0, "unresolvedRemoteWords": 0}}
output_offsets = []
rendered = []
with open(tpath) as f, open(outpath, "w") as out:
    line_count = 0
    for source_line, ln in enumerate(f):
        m = pat.match(ln.rstrip("\n"))
        if not m:
            rendered.append((output_offsets[-1] if output_offsets else -1, ln, False))
            continue
        h, mi, s, rest = m.groups()
        if offsets is not None:
            if line_count >= len(offsets) or not finite(offsets[line_count]) or offsets[line_count] < 0:
                raise ValueError("invalid transcript offset")
            rel = offsets[line_count] / 1000
        else:
            wall = wall_epoch(h, mi, s)
            previous = max(previous, wall)
            rel = wall - epoch
        line_count += 1
        # The microphone channel is already an authoritative source label.
        # Diarization runs only against mixed call audio, so never replace
        # `Me` with whichever remote participant happened to overlap.
        if rest.startswith("Me: "):
            rendered.append((round(rel * 1000), f"[{h}:{mi}:{s}] {rest}\n", True))
            output_offsets.append(round(rel * 1000))
            continue
        key = (round(rel * 1000), rest)
        spk = speaker_at(rel, intervals.get(key))
        parts = refine(rest, word_intervals.get(key, []), refined_words.get(key)) if spk is None else []
        if not parts:
            parts = [{"start": 0, "end": len(rest), "offsetMs": round(rel * 1000),
                      "rawSpeaker": spk, "reasons": ["segment" if spk else "unresolved_segment"]}]
        # An unsplit line keeps its original timestamp. Split lines use the
        # word offset and a wall time relative to the original line's stamp.
        if len(parts) == 1:
            parts[0]["offsetMs"] = round(rel * 1000)
        report["coverage"]["totalRemoteLines"] += 1
        if any(part["rawSpeaker"] is None for part in parts):
            report["coverage"]["unresolvedRemoteLines"] += 1
        previous_offset = round(rel * 1000)
        for part in parts:
            if part["offsetMs"] is None:
                part["offsetMs"] = previous_offset
            # Sentence boundaries can be early. A missing word time must not
            # cause the output to move backwards after an aligned word.
            part["offsetMs"] = max(previous_offset, part["offsetMs"])
            previous_offset = part["offsetMs"]
            part["sourceOffsetMs"] = round(rel * 1000)
            part["sourceEndMs"] = round(intervals[key] * 1000) if key in intervals else None
            speaker = label(part.pop("rawSpeaker"))
            part["speaker"] = speaker
            part["sourceLine"] = source_line
            text = rest[part["start"]:part["end"]].strip()
            count_key = "labeledRemoteWords" if speaker else "unresolvedRemoteWords"
            report["coverage"][count_key] += len(text.split())
            stamp = f"{h}:{mi}:{s}"
            if len(parts) > 1:
                stamp = datetime.fromtimestamp(epoch + part["offsetMs"] / 1000, zone).strftime("%H:%M:%S")
            rendered.append((part["offsetMs"], f"[{stamp}] {speaker or 'Unknown speaker'}: {text}\n", True))
            output_offsets.append(part["offsetMs"])
            report["rows"].append(part)
    if offsets is not None and line_count != len(offsets):
        raise ValueError("transcript offset count mismatch")

    rendered.sort(key=lambda row: row[0])
    for _, text, _ in rendered:
        out.write(text)
    output_offsets = [offset for offset, _, timed in rendered if timed]

Path(outpath).with_suffix(".offsets.json").write_text(json.dumps(output_offsets) + "\n")
Path(outpath).with_suffix(".alignment.json").write_text(json.dumps(report, sort_keys=True) + "\n")
