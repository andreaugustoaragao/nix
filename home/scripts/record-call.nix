{ pkgs, isWorkstation, ... }:

let
  # Enable Vulkan on the workstation (AMD RX 7900 XT via Mesa RADV) for
  # ~10x realtime transcription. Other hosts stay on the CPU build —
  # but in practice non-workstation hosts use the remote-whisper path
  # below and never invoke whisper-cli locally.
  whisperPkg =
    if isWorkstation then pkgs.whisper-cpp.override { vulkanSupport = true; } else pkgs.whisper-cpp;

  # On non-workstation hosts (prl-dev-vm, vmw-dev-vm, hp-laptop) the
  # local CPU build of whisper-cli is hopelessly slow for real-time
  # call transcription. Point the script at the mac-work LaunchAgent
  # (darwin/services/whisper-server.nix) by default; users can
  # override at runtime by exporting WHISPER_SERVER_URL="" to force
  # the local-binary path, or by pointing it at a different host.
  #
  # Workstation keeps the empty default so the existing Vulkan path
  # stays the only one in play.
  defaultWhisperServerUrl =
    if isWorkstation then "" else "http://mac-work.local:8081/v1/audio/transcriptions";

  binPath = pkgs.lib.makeBinPath [
    pkgs.pipewire # pw-record; its PipeWire-native capture path avoids the
    # "Generic error in an external library" that `ffmpeg -f pulse` hits
    # against null-sink monitors when a loopback is consuming them too.
    pkgs.pulseaudio
    pkgs.ffmpeg
    whisperPkg
    pkgs.inotify-tools
    pkgs.jq
    pkgs.python3
    pkgs.uv # `uv run --script` for diarization (pyannote.audio + PyTorch)
    pkgs.curl
    pkgs.coreutils
    pkgs.gnused
    pkgs.gawk
    pkgs.procps
  ];

  # Emit [HH:MM:SS] (prefix) text lines from up to two whisper JSON
  # transcriptions (call and optional mic), sorted by time. Call lines
  # are unlabeled; mic lines are prefixed with "Me: ".
  # Args: call_json mic_json_or_- win_off emit_lo call_emit_hi
  #       mic_emit_hi started_at_epoch
  # If started_at_epoch > 0, timestamps are wall-clock (local time);
  # otherwise they're elapsed seconds from session start.
  mergePy = pkgs.writeText "record-call-merge.py" ''
    import json, sys, time
    call_src = sys.argv[1]
    mic_src = sys.argv[2]
    win_off = float(sys.argv[3])
    emit_lo = float(sys.argv[4])
    call_emit_hi = float(sys.argv[5])
    mic_emit_hi = float(sys.argv[6])
    started_at = float(sys.argv[7]) if len(sys.argv) > 7 else 0

    def load(path, prefix, emit_hi):
        if path == "-" or not path:
            return []
        try:
            with open(path) as f:
                data = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            return []

        # Two segment shapes:
        #   - whisper.cpp CLI (`-oj`): top-level "transcription" with
        #     {offsets:{from,to},text}, `from` is milliseconds.
        #   - whisper.cpp / OpenAI server (response_format=verbose_json):
        #     top-level "segments" with {start,end,text}, `start` is
        #     floating-point seconds.
        # record-call now consumes whichever shape its transcribe
        # backend produced — local whisper-cli vs remote whisper-server.
        if "transcription" in data:
            segments = [
                (s.get("offsets", {}).get("from", 0) / 1000.0, s.get("text", ""))
                for s in data["transcription"]
            ]
        elif "segments" in data:
            segments = [
                (float(s.get("start", 0)), s.get("text", ""))
                for s in data["segments"]
            ]
        else:
            return []

        out = []
        for t, text in segments:
            text = (text or "").strip()
            if not text:
                continue
            abs_t = t + win_off
            if abs_t < emit_lo:
                continue
            if emit_hi >= 0 and abs_t >= emit_hi:
                continue
            out.append((abs_t, prefix, text))
        return out

    entries = load(call_src, "", call_emit_hi) + load(mic_src, "Me: ", mic_emit_hi)
    entries.sort(key=lambda e: e[0])
    for t, prefix, text in entries:
        if started_at > 0:
            stamp = time.strftime("%H:%M:%S", time.localtime(started_at + t))
        else:
            h, rem = divmod(int(t), 3600)
            m, sec = divmod(rem, 60)
            stamp = f"{h:02d}:{m:02d}:{sec:02d}"
        print(f"[{stamp}] {prefix}{text}")
  '';

  # Speaker diarization via pyannote.audio — emits JSON segments of
  # [start, end, speaker] for an input audio file. Uses uv's PEP-723
  # inline metadata so PyTorch + pyannote are fetched on first run and
  # cached in uv's global cache. Needs HF_TOKEN because the gated
  # pyannote/speaker-diarization-3.1 model.
  diarizePy = pkgs.writeText "record-call-diarize.py" ''
    # /// script
    # requires-python = ">=3.11"
    # dependencies = ["pyannote.audio>=3.1,<4"]
    # ///
    import json, os, sys
    from pyannote.audio import Pipeline
    import torch

    audio = sys.argv[1]
    token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_HUB_TOKEN")
    if not token:
        sys.stderr.write("HF_TOKEN not set — see 'record-call diarize' help\n")
        sys.exit(1)

    pipe = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        use_auth_token=token,
    )
    if torch.cuda.is_available():
        pipe.to(torch.device("cuda"))

    diarization = pipe(audio)
    segs = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        segs.append({"start": float(turn.start), "end": float(turn.end), "speaker": speaker})
    json.dump(segs, sys.stdout)
  '';

  # Align transcript.txt (with wall-clock [HH:MM:SS] stamps) against a
  # diarization JSON by prepending the active speaker to each line.
  # Args: transcript_path diar_json started_at_epoch out_path
  alignPy = pkgs.writeText "record-call-align.py" ''
    import json, re, sys, time
    tpath, dpath, epoch_s, outpath = sys.argv[1:5]
    epoch = int(epoch_s)
    with open(dpath) as f:
        segs = json.load(f)

    def speaker_at(t):
        # Pick the diarization segment whose [start, end] contains t,
        # or the closest one within 1s either side (whisper and
        # pyannote timestamps disagree at sub-second level).
        hit = None
        for s in segs:
            if s["start"] <= t <= s["end"]:
                return s["speaker"]
            if hit is None or abs(t - (s["start"] + s["end"]) / 2) < abs(t - (hit["start"] + hit["end"]) / 2):
                hit = s
        if hit and min(abs(t - hit["start"]), abs(t - hit["end"])) <= 1.0:
            return hit["speaker"]
        return None

    # Canonical speaker id mapping: SPEAKER_00 -> Speaker 1, etc.
    # Preserves first-seen order for nicer reading.
    canonical = {}
    def label(raw):
        if raw is None:
            return None
        if raw not in canonical:
            canonical[raw] = f"Speaker {len(canonical) + 1}"
        return canonical[raw]

    pat = re.compile(r"^\[(\d\d):(\d\d):(\d\d)\] (.*)$")
    with open(tpath) as f, open(outpath, "w") as out:
        for ln in f:
            m = pat.match(ln.rstrip("\n"))
            if not m:
                out.write(ln)
                continue
            h, mi, s, rest = m.groups()
            wall = time.mktime(time.strptime(
                time.strftime("%Y-%m-%d ", time.localtime(epoch)) + f"{h}:{mi}:{s}",
                "%Y-%m-%d %H:%M:%S",
            ))
            rel = wall - epoch
            spk = label(speaker_at(rel))
            prefix = f"[{h}:{mi}:{s}] "
            if spk:
                out.write(f"{prefix}{spk}: {rest}\n")
            else:
                out.write(f"{prefix}{rest}\n")
  '';

  # Rewrite a transcript's [HH:MM:SS] timestamps as wall-clock local
  # time given a session start epoch. Args: transcript_path start_epoch
  retimePy = pkgs.writeText "record-call-retime.py" ''
    import re, sys, time
    path = sys.argv[1]
    epoch = int(sys.argv[2])
    pat = re.compile(r"^\[(\d\d):(\d\d):(\d\d)\] (.*)$")
    with open(path) as f:
        lines = f.readlines()
    with open(path, "w") as f:
        for ln in lines:
            m = pat.match(ln.rstrip("\n"))
            if not m:
                f.write(ln)
                continue
            h, mi, s, rest = m.groups()
            elapsed = int(h) * 3600 + int(mi) * 60 + int(s)
            stamp = time.strftime("%H:%M:%S", time.localtime(epoch + elapsed))
            f.write(f"[{stamp}] {rest}\n")
  '';

  # Group consecutive same-speaker lines into prose-style "turns" with
  # pause-based splits. Speaker change OR gap >= GAP seconds starts a
  # new turn. Speaker is derived from the line prefix:
  #   "Me: …"        → "Me"        (mic channel)
  #   "Speaker N: …" → "Speaker N" (post-diarization)
  #   bare           → "Them"      (call channel, undiarized)
  # Whisper-segment line breaks within a turn are rejoined into one
  # paragraph and re-wrapped at WRAP_COL — small punctuation/whitespace
  # artifacts from segment boundaries ("  word", " . next", duplicated
  # periods) are normalized in the process. Per-segment timestamps
  # within a turn are dropped; only the turn-header timestamp remains.
  # If you need timestamps at segment granularity, grep transcript.txt.
  # Args: <input.txt> <output.txt> [gap_seconds]
  turnsPy = pkgs.writeText "record-call-turns.py" ''
    import re, sys, textwrap

    LINE_RE = re.compile(r"^\[(\d\d):(\d\d):(\d\d)\] (.+)$")
    SPEAKER_RE = re.compile(r"^(Me|Speaker \d+): (.*)$")
    WRAP_COL = 80

    def parse(line):
        m = LINE_RE.match(line.rstrip("\n"))
        if not m:
            return None
        h, mi, s, body = m.groups()
        t = int(h) * 3600 + int(mi) * 60 + int(s)
        stamp = f"{h}:{mi}:{s}"
        sm = SPEAKER_RE.match(body)
        if sm:
            return t, stamp, sm.group(1), sm.group(2)
        return t, stamp, "Them", body

    def join_segments(segs):
        # Concatenate segments with single spaces, then clean up the
        # whisper-segment-boundary artifacts that look ugly in prose:
        #   - collapsed whitespace
        #   - space before punctuation (" ." → ".")
        #   - runs of repeated punctuation (". ." → ".", ", ," → ",")
        #   - orphan leading punctuation at the start of a segment
        #     joining onto a sentence-terminator from the previous
        #     (". 56.7" pattern from whisper restarting mid-stream)
        text = " ".join(s.strip() for s in segs if s and s.strip())
        text = re.sub(r"\s+", " ", text)
        text = re.sub(r"\s+([.,;:!?])", r"\1", text)
        # collapse ". ." ", ," etc. (any terminator immediately followed
        # by space + same/different terminator)
        for _ in range(3):
            text = re.sub(r"([.,;:!?])\s+([.,;:!?])", r"\2", text)
        return text.strip()

    src = sys.argv[1]
    dst = sys.argv[2]
    gap = int(sys.argv[3]) if len(sys.argv) > 3 else 8

    turns = []  # [(header_stamp, speaker, [segment_text, ...])]
    last_t = None
    seg_count = 0
    for line in open(src):
        p = parse(line)
        if not p:
            continue
        t, stamp, spk, text = p
        seg_count += 1
        if turns and turns[-1][1] == spk and last_t is not None and (t - last_t) < gap:
            turns[-1][2].append(text)
        else:
            turns.append((stamp, spk, [text]))
        last_t = t

    with open(dst, "w") as f:
        for header_stamp, spk, segs in turns:
            f.write(f"[{header_stamp}] {spk}:\n")
            para = join_segments(segs)
            if para:
                f.write(textwrap.fill(
                    para,
                    width=WRAP_COL,
                    initial_indent="  ",
                    subsequent_indent="  ",
                    break_long_words=False,
                    break_on_hyphens=False,
                ) + "\n")
            f.write("\n")
    print(f"turns: {len(turns)} turns from {seg_count} lines")
  '';

  # Collapse near-duplicate consecutive lines within ±6s. Window overlaps
  # emit the same text in adjacent windows when a whisper segment spans
  # a boundary; this pass drops the duplicates.
  #
  # Two collapse signals:
  #   1. Overall SequenceMatcher ratio >= RATIO_THRESH (true near-duplicates).
  #   2. Largest matching block starts near the head of BOTH strings and
  #      covers >= PREFIX_COVER of the shorter — i.e. one line is
  #      approximately a prefix of the other. This catches the common
  #      window-overlap case where the earlier window cut off mid-word
  #      and the later window has the full sentence.
  # When a pair collapses, we drop the SHORTER line (the truncated one
  # with less whisper context); on equal length we drop the later.
  # Previously this dropped the chronologically-later line, which threw
  # away the BETTER transcription (e.g. "Mahender, Marcelo, um, Matt,
  # Alta," was kept while "Mahender, Marcelo, Matt Altapeter, you know,
  # the" was dropped — losing "Altapeter" entirely from the final).
  # RATIO_THRESH was also bumped from 0.65 → 0.78 to stop false-positive
  # collapses of distinct sentences sharing filler words ("any day in
  # that week is problematic" vs "Days in that week are problematic").
  dedupePy = pkgs.writeText "record-call-dedupe.py" ''
    import difflib, re, sys

    WIN_S = 6
    RATIO_THRESH = 0.78
    PREFIX_COVER = 0.6
    LINE_RE = re.compile(r"^\[(\d\d):(\d\d):(\d\d)\] (.+)$")
    # Speaker prefixes (from mergePy and the diarization aligner) should
    # not influence similarity — "Me: I am flexible." vs "I am flexible."
    # is the call channel echoing the mic and should still collapse.
    SPEAKER_RE = re.compile(r"^(?:Me|Speaker \d+): ")

    def parse(line):
        m = LINE_RE.match(line.rstrip("\n"))
        if not m:
            return None
        h, mi, s, text = m.groups()
        body = SPEAKER_RE.sub("", text).strip()
        return int(h) * 3600 + int(mi) * 60 + int(s), body

    def is_duplicate(a, b):
        if not a or not b:
            return False
        al, bl = a.lower(), b.lower()
        if difflib.SequenceMatcher(None, al, bl).ratio() >= RATIO_THRESH:
            return True
        short, long_ = (al, bl) if len(al) <= len(bl) else (bl, al)
        sm = difflib.SequenceMatcher(None, short, long_)
        blocks = [blk for blk in sm.get_matching_blocks() if blk.size > 0]
        if not blocks:
            return False
        biggest = max(blocks, key=lambda x: x.size)
        # Both strings start with (approximately) the same content, and
        # that prefix covers most of the shorter line.
        return (
            biggest.a <= 3
            and biggest.b <= 3
            and biggest.size >= PREFIX_COVER * len(short)
        )

    path = sys.argv[1]
    with open(path) as f:
        lines = f.readlines()
    parsed = [parse(ln) for ln in lines]
    drop = set()

    for i in range(len(parsed)):
        if i in drop or not parsed[i]:
            continue
        t1, text1 = parsed[i]
        for j in range(i + 1, len(parsed)):
            if j in drop or not parsed[j]:
                continue
            t2, text2 = parsed[j]
            if t2 - t1 > WIN_S:
                break
            if is_duplicate(text1, text2):
                # Drop the shorter line — the longer version typically
                # comes from the next window which had more whisper
                # context and produces a more complete transcription.
                # On tie, drop the later (preserve original order).
                if len(text2) > len(text1):
                    drop.add(i)
                    break  # i is gone, stop comparing against it
                else:
                    drop.add(j)

    kept = [ln for i, ln in enumerate(lines) if i not in drop]
    with open(path, "w") as f:
        f.writelines(kept)
    print(f"dedupe: dropped {len(drop)} duplicate line(s) of {len(lines)} total")
  '';
  sessionConfig = pkgs.writeText "record-call-session-config.json" (
    builtins.toJSON {
      python = "${pkgs.python3}/bin/python3";
      pwRecord = "${pkgs.pipewire}/bin/pw-record";
      pactl = "${pkgs.pulseaudio}/bin/pactl";
      ffmpeg = "${pkgs.ffmpeg}/bin/ffmpeg";
      whisper = "${whisperPkg}/bin/whisper-cli";
      curl = "${pkgs.curl}/bin/curl";
      systemdRun = "${pkgs.systemd}/bin/systemd-run";
      systemctl = "${pkgs.systemd}/bin/systemctl";
      tail = "${pkgs.coreutils}/bin/tail";
      merge = mergePy;
      dedupe = dedupePy;
      turns = turnsPy;
      inherit defaultWhisperServerUrl;
    }
  );
in
{
  home.packages = [
    (pkgs.writeShellScriptBin "record-call" ''
            set -euo pipefail
            export PATH="${binPath}:$PATH"

            # Capture and finalization share one owned user-unit lifecycle.
            # Public status is structured; legacy session.env is never sourced.
            case "''${1:-help}" in
              start|stop|status|retry|route|tail)
                exec python3 ${./record-call-session.py} --config ${sessionConfig} "$@"
                ;;
            esac

            # When set, transcription is delegated to a remote whisper.cpp
            # HTTP server (OpenAI Whisper API shape, response_format=verbose_json).
            # Defaults to mac-work's LaunchAgent on non-workstation hosts;
            # empty on workstation so the local Vulkan whisper-cli is used.
            # Override at runtime to force local (`WHISPER_SERVER_URL=`) or
            # point at a different server.
            WHISPER_SERVER_URL="''${WHISPER_SERVER_URL:-${defaultWhisperServerUrl}}"

            # ffmpeg writes fine-grained fragments; the watcher assembles
            # overlapping windows from them so Whisper sees ~7s of audio
            # either side of every emit boundary. 5s of overlap wasn't
            # enough in practice — whisper's segment timestamps sometimes
            # land just past the emit cutoff and words on the boundary
            # ("let" in "let me know") got lost between windows.
            FRAGMENT_SEC="''${RECORD_CALL_FRAGMENT_SEC:-5}"
            WINDOW_SEC="''${RECORD_CALL_WINDOW_SEC:-45}"
            ADVANCE_SEC="''${RECORD_CALL_ADVANCE_SEC:-30}"
            if [ "$ADVANCE_SEC" -gt "$WINDOW_SEC" ] \
               || [ $(( WINDOW_SEC % FRAGMENT_SEC )) -ne 0 ] \
               || [ $(( ADVANCE_SEC % FRAGMENT_SEC )) -ne 0 ]; then
              echo "Invalid chunking: WINDOW_SEC and ADVANCE_SEC must be multiples of FRAGMENT_SEC, and ADVANCE_SEC <= WINDOW_SEC (got ''${FRAGMENT_SEC}/''${WINDOW_SEC}/''${ADVANCE_SEC})" >&2
              exit 1
            fi
            MODEL_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/whisper-cpp"
            MODEL_NAME="ggml-large-v3-turbo.bin"
            MODEL_PATH="$MODEL_DIR/$MODEL_NAME"
            MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_NAME"
            VAD_MODEL_NAME="ggml-silero-v5.1.2.bin"
            VAD_MODEL_PATH="$MODEL_DIR/$VAD_MODEL_NAME"
            VAD_MODEL_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/main/$VAD_MODEL_NAME"

            ensure_model() {
              # In remote mode the mac-work LaunchAgent owns the model
              # files — don't pollute this host's cache with a copy that
              # will never be loaded.
              if [ -n "$WHISPER_SERVER_URL" ]; then
                return 0
              fi
              if [ ! -f "$MODEL_PATH" ]; then
                echo "Downloading Whisper model ($MODEL_NAME, ~1.6GB)..."
                mkdir -p "$MODEL_DIR"
                curl -fL --progress-bar -o "$MODEL_PATH.tmp" "$MODEL_URL"
                mv "$MODEL_PATH.tmp" "$MODEL_PATH"
              fi
              if [ ! -f "$VAD_MODEL_PATH" ]; then
                echo "Downloading Silero VAD model ($VAD_MODEL_NAME, ~2MB)..."
                mkdir -p "$MODEL_DIR"
                curl -fL --progress-bar -o "$VAD_MODEL_PATH.tmp" "$VAD_MODEL_URL"
                mv "$VAD_MODEL_PATH.tmp" "$VAD_MODEL_PATH"
              fi
            }

            # Transcribe one 16kHz mono WAV to a json file at $2.json.
            # Local: whisper-cli with --vad against the workstation's
            # Vulkan-accelerated build, emits whisper.cpp "transcription"
            # shape. Remote: POST to whisper-server, emits OpenAI
            # "segments" shape. mergePy understands both.
            #
            # Args: <input.wav> <output_prefix> <model_path> <vad_model_path>
            transcribe_audio() {
              local in="$1" out_prefix="$2" model="$3" vad_model="$4"
              if [ -n "$WHISPER_SERVER_URL" ]; then
                # whisper-server's --vad applies to every request; client
                # doesn't pass it again. response_format=verbose_json so
                # we get segment-level start/end timestamps that mergePy
                # needs for window-relative emit filtering.
                curl -fsS --max-time 120 \
                  -F "file=@$in" \
                  -F "response_format=verbose_json" \
                  -F "language=en" \
                  "$WHISPER_SERVER_URL" \
                  > "$out_prefix.json"
              else
                whisper-cli -m "$model" -l en -nt -oj -of "$out_prefix" \
                  --vad --vad-model "$vad_model" \
                  -f "$in" </dev/null >/dev/null 2>&1
              fi
            }

            cmd_turns() {
              # Group a transcript into speaker turns. Works on both
              # the line-per-segment transcript.txt and the
              # diarization-aligned transcript.diarized.txt.
              # Usage: record-call turns <dir-or-txt> [gap-seconds]
              SRC="''${1:-}"
              GAP="''${2:-''${RECORD_CALL_TURN_GAP_SEC:-8}}"
              if [ -z "$SRC" ]; then
                echo "Usage: record-call turns <dir-or-txt> [gap-seconds]" >&2
                exit 1
              fi
              if [ -d "$SRC" ]; then
                if [ -f "$SRC/transcript.diarized.txt" ]; then
                  IN="$SRC/transcript.diarized.txt"
                  OUT="$SRC/transcript.diarized.turns.txt"
                else
                  IN="$SRC/transcript.txt"
                  OUT="$SRC/transcript.turns.txt"
                fi
              else
                IN="$SRC"
                OUT="''${SRC%.txt}.turns.txt"
              fi
              [ -f "$IN" ] || { echo "Not a file: $IN" >&2; exit 1; }
              python3 ${turnsPy} "$IN" "$OUT" "$GAP"
              echo "Wrote: $OUT"
            }

            cmd_dedupe() {
              SRC="''${1:-}"
              if [ -z "$SRC" ]; then
                echo "Usage: record-call dedupe <output-dir-or-transcript>" >&2
                exit 1
              fi
              if [ -d "$SRC" ]; then
                SRC="$SRC/transcript.txt"
              fi
              [ -f "$SRC" ] || { echo "Not a file: $SRC" >&2; exit 1; }
              cp -f "$SRC" "$SRC.raw"
              python3 ${dedupePy} "$SRC"
              echo "Raw backup: $SRC.raw"
            }

            cmd_transcribe() {
              # Offline: transcribe an existing WAV to [HH:MM:SS] text lines.
              SRC="''${1:-}"
              [ -n "$SRC" ] && [ -f "$SRC" ] || { echo "Usage: record-call transcribe <audio>" >&2; exit 1; }
              ensure_model
              WORK="$(mktemp -d)"
              trap 'rm -rf "$WORK"' EXIT
              ffmpeg -hide_banner -loglevel error -y -i "$SRC" \
                -ac 1 -ar 16000 -c:a pcm_s16le "$WORK/mono.wav"
              transcribe_audio "$WORK/mono.wav" "$WORK/out" "$MODEL_PATH" "$VAD_MODEL_PATH"
              python3 ${mergePy} "$WORK/out.json" - 0 0 -1 -1 0
            }

            cmd_diarize() {
              # Post-process: speaker-label the transcript using pyannote.
              # Args: <dir>   (the recordings/calls/<ts>/ directory)
              SRC="''${1:-}"
              [ -d "$SRC" ] || { echo "Usage: record-call diarize <output-dir>" >&2; exit 1; }
              [ -f "$SRC/transcript.txt" ] || { echo "No transcript.txt in $SRC" >&2; exit 1; }
              if [ -z "''${HF_TOKEN:-}" ] && [ -z "''${HUGGINGFACE_HUB_TOKEN:-}" ]; then
                cat >&2 <<EOF
      HF_TOKEN is required for pyannote's gated model.
        1) Create an HF account at https://huggingface.co/join
        2) Accept the license: https://huggingface.co/pyannote/speaker-diarization-3.1
        3) Create a read token: https://huggingface.co/settings/tokens
        4) export HF_TOKEN=hf_xxxxx and re-run
      EOF
                exit 1
              fi
              # Resolve session start epoch (for aligning wall-clock
              # transcript timestamps with diarization's audio-relative ones).
              EPOCH=""
              if [ -f "$SRC/.started-at" ]; then
                EPOCH=$(cat "$SRC/.started-at")
              else
                BASE=$(basename "$SRC")
                case "$BASE" in
                  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9])
                    D="''${BASE%%-*}"; T="''${BASE##*-}"
                    EPOCH=$(date -d "''${D:0:4}-''${D:4:2}-''${D:6:2} ''${T:0:2}:''${T:2:2}:''${T:4:2}" +%s 2>/dev/null)
                    ;;
                esac
              fi
              [ -n "$EPOCH" ] || { echo "can't determine session start epoch" >&2; exit 1; }

              # Concatenate call_*.wav fragments into one continuous session.wav
              echo "Concatenating call fragments..."
              WORK=$(mktemp -d)
              trap 'rm -rf "$WORK"' EXIT
              find "$SRC/chunks" -name 'call_*.wav' -type f 2>/dev/null \
                | sort | sed "s|^|file '|; s|\$|'|" > "$WORK/list.txt"
              [ -s "$WORK/list.txt" ] || { echo "no call fragments found" >&2; exit 1; }
              ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$WORK/list.txt" \
                -c copy "$SRC/session.wav" </dev/null

              # Run pyannote via uv (manages its own venv + torch)
              echo "Running speaker diarization (first run downloads ~2GB)..."
              uv run --script ${diarizePy} "$SRC/session.wav" > "$SRC/diarization.json" \
                || { echo "diarize.py failed — see stderr above" >&2; exit 1; }

              echo "Aligning with transcript..."
              python3 ${alignPy} "$SRC/transcript.txt" "$SRC/diarization.json" \
                "$EPOCH" "$SRC/transcript.diarized.txt"

              SPKS=$(jq -r '[.[].speaker] | unique | length' "$SRC/diarization.json")
              LINES=$(wc -l < "$SRC/transcript.diarized.txt")
              cat <<EOF
      Diarized.
        Speakers:   $SPKS
        Lines:      $LINES
        Transcript: $SRC/transcript.diarized.txt
        Raw diar:   $SRC/diarization.json
      EOF
            }

            cmd_retime() {
              # Rewrite a transcript's timestamps as wall-clock times.
              # Usage: record-call retime <dir-or-txt> [--start EPOCH]
              SRC="''${1:-}"
              [ -n "$SRC" ] || { echo "Usage: record-call retime <dir-or-txt>" >&2; exit 1; }
              if [ -d "$SRC" ]; then TXT="$SRC/transcript.txt"; else TXT="$SRC"; fi
              [ -f "$TXT" ] || { echo "Not a file: $TXT" >&2; exit 1; }
              EPOCH=""
              if [ "''${2:-}" = "--start" ] && [ -n "''${3:-}" ]; then
                EPOCH="$3"
              elif [ -d "$SRC" ] && [ -f "$SRC/.started-at" ]; then
                EPOCH=$(cat "$SRC/.started-at")
              else
                # Parse from output dir name: YYYYMMDD-HHMMSS
                BASE=$(basename "$(dirname "$TXT")")
                case "$BASE" in
                  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9])
                    DATE_STR="''${BASE%%-*}"
                    TIME_STR="''${BASE##*-}"
                    EPOCH=$(date -d "''${DATE_STR:0:4}-''${DATE_STR:4:2}-''${DATE_STR:6:2} ''${TIME_STR:0:2}:''${TIME_STR:2:2}:''${TIME_STR:4:2}" +%s 2>/dev/null)
                    ;;
                esac
              fi
              [ -n "$EPOCH" ] || { echo "cannot determine start epoch; pass '--start <epoch>'" >&2; exit 1; }
              cp -f "$TXT" "$TXT.bak"
              python3 ${retimePy} "$TXT" "$EPOCH"
              echo "Retimed from epoch $EPOCH. Backup: $TXT.bak"
            }

            usage() {
              cat <<EOF
      record-call — capture browser conference calls locally and transcribe with Whisper.

      Usage:
        record-call start [output-dir]   Begin recording (default: ~/recordings/calls/<ts>)
        record-call route                Move browser streams to Record-Call-Sink
        record-call status [--json]      Show recording/finalization/readiness
        record-call tail                 Follow the live transcript
        record-call stop                 Stop capture; finalize in its owned user unit
        record-call retry <dir>          Resume failed retained transcription
        record-call transcribe <wav>     Offline: transcribe an existing audio file
        record-call dedupe <dir|txt>     Collapse near-duplicate lines within ~6s
        record-call turns <dir|txt> [gap]   Group lines into speaker turns (default gap=8s)
        record-call retime <dir|txt>     Rewrite timestamps as wall-clock (HH:MM:SS local)
        record-call diarize <dir>        Speaker-label the transcript (needs HF_TOKEN)

      How it works:
        * Creates a uniquely owned PipeWire null-sink with a loopback to your
          default output so you still hear the call.
        * The recording owner routes matching browser streams every second,
          including tabs opened/refreshed mid-session.
        * pw-record captures both the sink's monitor (the call) and the
          default source (your mic), piping each into ffmpeg's segment muxer
          as ''${FRAGMENT_SEC}s call_*.wav and mic_*.wav fragments under chunks/.
        * A background watcher assembles overlapping ''${WINDOW_SEC}s windows every
          ''${ADVANCE_SEC}s and transcribes each via whisper-cli. Overlap gives
          Whisper context around word boundaries; the merge step emits only
          each window's authoritative ''${ADVANCE_SEC}s slice.
        * Both sides use Silero VAD so silent stretches aren't hallucinated
          into "you" / "Thanks for watching." lines. The user's mic is
          prefixed "Me:"; the call side is unlabeled.
        * At stop, capture ends immediately and final partial audio is retained.
          Only verified complete transcripts publish a ready recording.json.
          Failed work remains incomplete and can be retried without duplicate text.

      If a stream isn't auto-routed, move it to Record-Call-Sink via
      pavucontrol (Playback tab) or by running 'record-call route'.
      EOF
            }

            CMD="''${1:-help}"
            shift || true
            case "$CMD" in
              transcribe)  cmd_transcribe "$@" ;;
              dedupe)      cmd_dedupe "$@" ;;
              turns)       cmd_turns "$@" ;;
              retime)      cmd_retime "$@" ;;
              diarize)     cmd_diarize "$@" ;;
              help|-h|--help) usage ;;
              *) usage; exit 1 ;;
            esac
    '')

    (pkgs.writeShellScriptBin "record-call-test" ''
      set -euo pipefail
      export PATH="${
        pkgs.lib.makeBinPath [
          pkgs.espeak-ng
          pkgs.pulseaudio
          pkgs.ffmpeg
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.jq
        ]
      }:$PATH"

      PASS=0; FAIL=0

      step() { printf '\n==> %s\n' "$*"; }
      ok()   { printf '    PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
      ng()   { printf '    FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); }

      # ----- Test 1: offline transcribe -----
      step "Offline transcribe (model + Vulkan + merge)"
      W=$(mktemp -d)
      espeak-ng -v en+f3 -s 150 -w "$W/clip.wav" \
        "Hello, this is the offline transcribe self-test verifying the whisper pipeline." 2>/dev/null
      OUT=$(record-call transcribe "$W/clip.wav" 2>&1 || true)
      echo "$OUT" | sed 's/^/    /'
      if echo "$OUT" | grep -qE '^\[[0-9:]+\] .+'; then
        ok "transcript line produced"
      else
        ng "no transcript line produced"
      fi
      rm -rf "$W"

      # ----- Test 2: live capture -----
      step "Live capture (PipeWire sink + pw-record + segmenter + watcher)"
      if record-call status --json | jq -e '.status == "recording" or .status == "starting" or .status == "finalizing"' >/dev/null; then
        ng "another record-call session already active — run 'record-call stop' first"
      else
        TDIR=$(mktemp -d)
        # Small fragments so the test doesn't wait a full real window.
        export RECORD_CALL_FRAGMENT_SEC=2
        export RECORD_CALL_WINDOW_SEC=4
        export RECORD_CALL_ADVANCE_SEC=2
        record-call start "$TDIR" >/dev/null
        for _ in $(seq 1 50); do
          record-call status --json | jq -e '.status == "recording"' >/dev/null && break
          sleep 0.2
        done
        TEST_SINK=$(record-call status --json | jq -r '.sinkName')
        W=$(mktemp -d)
        espeak-ng -v en+f3 -s 150 -w "$W/clip.wav" \
          "This is an automated live capture test of the record call pipeline." 2>/dev/null
        # Play twice so we straddle at least one finalized chunk.
        # paplay hangs on final drain against null-sinks in PipeWire — wrap
        # in `timeout` so it exits once the clip has been written.
        timeout 6 paplay --device="$TEST_SINK" "$W/clip.wav" 2>/dev/null || true
        sleep 1
        timeout 6 paplay --device="$TEST_SINK" "$W/clip.wav" 2>/dev/null || true
        sleep 10
        record-call stop >/dev/null
        for _ in $(seq 1 120); do
          record-call status --json | jq -e '.status == "ready" or .status == "incomplete"' >/dev/null && break
          sleep 1
        done
        echo "    transcript:"
        sed 's/^/      /' "$TDIR/transcript.txt" 2>/dev/null || true
        if [ -s "$TDIR/transcript.txt" ] && grep -qiE 'test|record|pipeline' "$TDIR/transcript.txt"; then
          ok "live transcript contains expected content"
        else
          ng "live transcript empty or missing expected content (see $TDIR)"
        fi
        rm -rf "$W"
      fi

      printf '\n== Results: %d passed, %d failed ==\n' "$PASS" "$FAIL"
      [ "$FAIL" = 0 ]
    '')
  ];
}
