{ pkgs, isWorkstation, ... }:

let
  # Enable Vulkan on the workstation (AMD RX 7900 XT via Mesa RADV) for
  # ~10x realtime transcription. Other hosts stay on the CPU build.
  whisperPkg =
    if isWorkstation then pkgs.whisper-cpp.override { vulkanSupport = true; } else pkgs.whisper-cpp;

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
  # Args: call_json mic_json_or_- win_off emit_lo emit_hi started_at_epoch
  # If started_at_epoch > 0, timestamps are wall-clock (local time);
  # otherwise they're elapsed seconds from session start.
  mergePy = pkgs.writeText "record-call-merge.py" ''
    import json, sys, time
    call_src = sys.argv[1]
    mic_src = sys.argv[2]
    win_off = float(sys.argv[3])
    emit_lo = float(sys.argv[4])
    emit_hi = float(sys.argv[5])
    started_at = float(sys.argv[6]) if len(sys.argv) > 6 else 0

    def load(path, prefix):
        if path == "-" or not path:
            return []
        try:
            with open(path) as f:
                data = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            return []
        out = []
        for s in data.get("transcription", []):
            t = s.get("offsets", {}).get("from", 0) / 1000.0
            text = s.get("text", "").strip()
            if not text:
                continue
            abs_t = t + win_off
            if abs_t < emit_lo:
                continue
            if emit_hi >= 0 and abs_t >= emit_hi:
                continue
            out.append((abs_t, prefix, text))
        return out

    entries = load(call_src, "") + load(mic_src, "Me: ")
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

  # Collapse near-duplicate consecutive lines within ±6s. Window overlaps
  # emit the same text in adjacent windows when a whisper segment spans
  # a boundary; this pass drops the duplicates.
  dedupePy = pkgs.writeText "record-call-dedupe.py" ''
    import difflib, re, sys

    WIN_S = 6
    THRESH = 0.65
    LINE_RE = re.compile(r"^\[(\d\d):(\d\d):(\d\d)\] (.+)$")

    def parse(line):
        m = LINE_RE.match(line.rstrip("\n"))
        if not m:
            return None
        h, mi, s, text = m.groups()
        return int(h) * 3600 + int(mi) * 60 + int(s), text

    def similar(a, b):
        return difflib.SequenceMatcher(None, a.lower(), b.lower()).ratio()

    path = sys.argv[1]
    with open(path) as f:
        lines = f.readlines()
    parsed = [parse(ln) for ln in lines]
    drop = set()

    for i, p in enumerate(parsed):
        if i in drop or not p:
            continue
        t1, text1 = p
        for j in range(i + 1, len(parsed)):
            if j in drop:
                continue
            q = parsed[j]
            if not q:
                continue
            t2, text2 = q
            if t2 - t1 > WIN_S:
                break
            if similar(text1, text2) >= THRESH:
                drop.add(j)

    kept = [ln for i, ln in enumerate(lines) if i not in drop]
    with open(path, "w") as f:
        f.writelines(kept)
    print(f"dedupe: dropped {len(drop)} duplicate line(s) of {len(lines)} total")
  '';
in
{
  home.packages = [
    (pkgs.writeShellScriptBin "record-call" ''
            set -euo pipefail
            export PATH="${binPath}:$PATH"

            SINK_NAME="record-call-sink"
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
            STATE_DIR="''${XDG_RUNTIME_DIR:-/tmp}/record-call"
            STATE_FILE="$STATE_DIR/session.env"
            mkdir -p "$STATE_DIR"

            ensure_model() {
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

            sink_index() {
              pactl -f json list sinks | jq -r --arg n "$SINK_NAME" '.[] | select(.name == $n) | .index' | head -1
            }

            # Build one overlapping window from call_*.wav + mic_*.wav
            # fragments, transcribe each, and append emit-filtered lines to
            # transcript.txt. Mic transcription uses Silero VAD to skip the
            # silent stretches that Whisper would otherwise hallucinate on.
            # Args: OUT FRAG WIN ADV MODEL VAD_MODEL WINDOW_IDX EMIT_HI_SEC STARTED_AT
            process_window() {
              local OUT="$1" FRAG="$2" WIN="$3" ADV="$4" MODEL="$5" VAD_MODEL="$6" N="$7" EHI="$8" STARTED="$9"
              local CHUNKS_DIR="$OUT/chunks"
              local TRANSCRIPT="$OUT/transcript.txt"
              local FPW=$(( WIN / FRAG ))
              local AF=$(( ADV / FRAG ))
              local start_frag=$(( N * AF ))
              local end_frag

              if [ "$EHI" = "-1" ]; then
                end_frag=$(find "$CHUNKS_DIR" -maxdepth 1 \
                    \( -name 'call_*.wav' -o -name 'mic_*.wav' \) -type f 2>/dev/null \
                  | sed -n 's|.*/\(call\|mic\)_0*\([0-9][0-9]*\)\.wav$|\2|p' \
                  | sort -n | tail -1)
                [ -n "$end_frag" ] || return 0
                [ "$end_frag" -ge "$start_frag" ] || return 0
              else
                end_frag=$(( start_frag + FPW - 1 ))
              fi

              local work
              work=$(mktemp -d)
              local call_list="$work/call.txt" mic_list="$work/mic.txt"
              : > "$call_list"
              : > "$mic_list"
              local f="$start_frag"
              while [ "$f" -le "$end_frag" ]; do
                local cpath mpath
                cpath=$(printf "%s/call_%06d.wav" "$CHUNKS_DIR" "$f")
                mpath=$(printf "%s/mic_%06d.wav" "$CHUNKS_DIR" "$f")
                [ -f "$cpath" ] && printf "file '%s'\n" "$cpath" >> "$call_list"
                [ -f "$mpath" ] && printf "file '%s'\n" "$mpath" >> "$mic_list"
                f=$(( f + 1 ))
              done

              if [ ! -s "$call_list" ] && [ ! -s "$mic_list" ]; then
                rm -rf "$work"
                return 0
              fi

              if [ -s "$call_list" ]; then
                ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$call_list" \
                  -c copy "$work/call.wav" </dev/null 2>/dev/null || true
              fi
              if [ -s "$mic_list" ]; then
                ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$mic_list" \
                  -c copy "$work/mic.wav" </dev/null 2>/dev/null || true
              fi

              # Transcribe both sides in parallel, both with Silero VAD.
              # The mic is mostly silence while the user listens, and the
              # call side can be silent too (hold music, the other end on
              # mute, or — historically — unrouted audio). Without VAD,
              # Whisper hallucinates "you" / "Thanks for watching" lines
              # on silence.
              local call_json="-" mic_json="-"
              if [ -s "$work/call.wav" ]; then
                whisper-cli -m "$MODEL" -l en -nt -oj -of "$work/call" \
                  --vad --vad-model "$VAD_MODEL" \
                  -f "$work/call.wav" </dev/null >"$work/call.log" 2>&1 &
                call_json="$work/call.json"
              fi
              if [ -s "$work/mic.wav" ]; then
                whisper-cli -m "$MODEL" -l en -nt -oj -of "$work/mic" \
                  --vad --vad-model "$VAD_MODEL" \
                  -f "$work/mic.wav" </dev/null >"$work/mic.log" 2>&1 &
                mic_json="$work/mic.json"
              fi
              wait

              local win_off=$(( start_frag * FRAG ))
              python3 ${mergePy} "$call_json" "$mic_json" \
                "$win_off" "$win_off" "$EHI" "$STARTED" >> "$TRANSCRIPT"

              rm -rf "$work"
            }

            cmd_start() {
              if [ -f "$STATE_FILE" ]; then
                # Validate — empty or stale (no live ffmpeg) state is a leftover
                # from a prior crash; clean it up instead of refusing to start.
                # shellcheck disable=SC1090
                . "$STATE_FILE" 2>/dev/null || true
                if { [ -n "''${FFMPEG_CALL_PID:-}" ] && kill -0 "$FFMPEG_CALL_PID" 2>/dev/null; } \
                   || { [ -n "''${FFMPEG_MIC_PID:-}" ] && kill -0 "$FFMPEG_MIC_PID" 2>/dev/null; }; then
                  echo "A recording is already active. Run 'record-call stop' first." >&2
                  exit 1
                fi
                echo "Removing stale session state..." >&2
                if [ -n "''${AUTOROUTE_PID:-}" ]; then
                  pkill -TERM -P "$AUTOROUTE_PID" 2>/dev/null || true
                  kill -TERM "$AUTOROUTE_PID" 2>/dev/null || true
                fi
                pactl list short modules 2>/dev/null | awk '/null-sink|loopback/{print $1}' \
                  | while read -r id; do pactl unload-module "$id" 2>/dev/null || true; done
                rm -f "$STATE_FILE"
                unset SINK_ID LOOPBACK_ID FFMPEG_CALL_PID FFMPEG_MIC_PID WATCHER_PID AUTOROUTE_PID OUTPUT_DIR FRAGMENT_SEC WINDOW_SEC ADVANCE_SEC STARTED_AT
              fi

              ensure_model

              OUTPUT_DIR="''${1:-$HOME/Recordings/calls/$(date +%Y%m%d-%H%M%S)}"
              mkdir -p "$OUTPUT_DIR/chunks"
              touch "$OUTPUT_DIR/transcript.txt"

              # Null-sink captures browser audio; loopback plays it back to
              # the user's default output so they still hear the call.
              SINK_ID=$(pactl load-module module-null-sink \
                sink_name="$SINK_NAME" \
                sink_properties='device.description="Record-Call-Sink"')
              LOOPBACK_ID=$(pactl load-module module-loopback \
                source="$SINK_NAME.monitor" \
                sink="@DEFAULT_SINK@" \
                latency_msec=50)

              # Resolve numeric ids for both sources. pw-record's
              # name-based --target is unreliable — it silently auto-links
              # to the default source if the name doesn't match a node
              # exactly. The numeric index always binds correctly.
              MON_ID=""
              MIC_ID=""
              for _ in $(seq 1 30); do
                MON_ID=$(pactl list short sources 2>/dev/null | awk -v n="$SINK_NAME.monitor" '$2==n{print $1; exit}')
                DEFAULT_SRC=$(pactl get-default-source 2>/dev/null)
                MIC_ID=$(pactl list short sources 2>/dev/null | awk -v n="$DEFAULT_SRC" '$2==n{print $1; exit}')
                [ -n "$MON_ID" ] && [ -n "$MIC_ID" ] && break
                sleep 0.1
              done
              if [ -z "$MON_ID" ] || [ -z "$MIC_ID" ]; then
                echo "failed to resolve source IDs (mon=$MON_ID mic=$MIC_ID)" >&2
                exit 1
              fi
              sleep 0.3

              # Capture call audio and mic as separate fragment streams.
              # pw-record piped to ffmpeg segment muxer avoids the pulse-
              # compat "Generic error" bug `ffmpeg -f pulse` hits against
              # null-sink monitors with a loopback attached.
              ( set -o pipefail
                exec pw-record --target="$MON_ID" --format=s16 --rate=16000 --channels=1 - \
                  2>> "$OUTPUT_DIR/pw-call.log" \
                | exec ffmpeg -hide_banner -loglevel warning -y \
                    -f s16le -ar 16000 -ac 1 -i - \
                    -c:a pcm_s16le \
                    -f segment -segment_time "$FRAGMENT_SEC" -reset_timestamps 1 \
                    "$OUTPUT_DIR/chunks/call_%06d.wav" \
                    > "$OUTPUT_DIR/ffmpeg-call.log" 2>&1
              ) &
              FFMPEG_CALL_PID=$!

              ( set -o pipefail
                exec pw-record --target="$MIC_ID" --format=s16 --rate=16000 --channels=1 - \
                  2>> "$OUTPUT_DIR/pw-mic.log" \
                | exec ffmpeg -hide_banner -loglevel warning -y \
                    -f s16le -ar 16000 -ac 1 -i - \
                    -c:a pcm_s16le \
                    -f segment -segment_time "$FRAGMENT_SEC" -reset_timestamps 1 \
                    "$OUTPUT_DIR/chunks/mic_%06d.wav" \
                    > "$OUTPUT_DIR/ffmpeg-mic.log" 2>&1
              ) &
              FFMPEG_MIC_PID=$!

              STARTED_AT=$(date +%s)
              ( exec "$0" _watch "$OUTPUT_DIR" "$FRAGMENT_SEC" "$WINDOW_SEC" "$ADVANCE_SEC" "$MODEL_PATH" "$VAD_MODEL_PATH" "$STARTED_AT" \
                  > "$OUTPUT_DIR/watcher.log" 2>&1 ) &
              WATCHER_PID=$!

              # Auto-route browser streams to Record-Call-Sink for the
              # lifetime of the session, so call audio gets captured even
              # if the tab is opened/refreshed after 'record-call start'.
              ( exec "$0" _autoroute > "$OUTPUT_DIR/autoroute.log" 2>&1 ) &
              AUTOROUTE_PID=$!

              cat > "$STATE_FILE" <<EOF
      SINK_ID=$SINK_ID
      LOOPBACK_ID=$LOOPBACK_ID
      FFMPEG_CALL_PID=$FFMPEG_CALL_PID
      FFMPEG_MIC_PID=$FFMPEG_MIC_PID
      WATCHER_PID=$WATCHER_PID
      AUTOROUTE_PID=$AUTOROUTE_PID
      OUTPUT_DIR=$OUTPUT_DIR
      FRAGMENT_SEC=$FRAGMENT_SEC
      WINDOW_SEC=$WINDOW_SEC
      ADVANCE_SEC=$ADVANCE_SEC
      STARTED_AT=$STARTED_AT
      EOF

              cat <<EOF
      Recording started.
        Output:     $OUTPUT_DIR
        Transcript: $OUTPUT_DIR/transcript.txt

      Browser audio is auto-routed to **Record-Call-Sink** for the
      lifetime of the session. If a stream doesn't get captured, run
      'record-call route' (or reroute via pavucontrol). A loopback plays
      it to your default output so you still hear the call.

      Monitor the live transcript:
          record-call tail

      Stop when done:
          record-call stop
      EOF
            }

            cmd_stop() {
              [ -f "$STATE_FILE" ] || { echo "No active recording." >&2; exit 1; }
              # shellcheck disable=SC1090
              . "$STATE_FILE"

              echo "Stopping auto-router..."
              if [ -n "''${AUTOROUTE_PID:-}" ]; then
                pkill -TERM -P "$AUTOROUTE_PID" 2>/dev/null || true
                kill -TERM "$AUTOROUTE_PID" 2>/dev/null || true
              fi

              echo "Stopping ffmpeg captures (flushing last fragment)..."
              kill -TERM "$FFMPEG_CALL_PID" "$FFMPEG_MIC_PID" 2>/dev/null || true
              for _ in $(seq 1 20); do
                kill -0 "$FFMPEG_CALL_PID" 2>/dev/null \
                  || kill -0 "$FFMPEG_MIC_PID" 2>/dev/null \
                  || break
                sleep 0.25
              done

              echo "Waiting for watcher to drain..."
              # Grace period for inotify close_write to fire on the final segment
              # and the watcher to spawn whisper-cli on it.
              sleep 3
              # Wait until no whisper-cli instance is running (all chunks processed).
              # Cap at 20 minutes to avoid hanging forever if something wedges.
              for _ in $(seq 1 1200); do
                pgrep -f 'whisper-cli' >/dev/null 2>&1 || break
                sleep 1
              done
              # Terminate the watcher and its children (inotifywait, pipe subshell).
              pkill -TERM -P "$WATCHER_PID" 2>/dev/null || true
              kill -TERM "$WATCHER_PID" 2>/dev/null || true

              # Flush the final (partial) window so no audio after the last
              # processed window is lost.
              if [ -f "$OUTPUT_DIR/.next-window" ]; then
                NEXT_WIN=$(cat "$OUTPUT_DIR/.next-window")
                echo "Flushing final window (idx $NEXT_WIN)..."
                process_window "$OUTPUT_DIR" "$FRAGMENT_SEC" "$WINDOW_SEC" "$ADVANCE_SEC" "$MODEL_PATH" "$VAD_MODEL_PATH" "$NEXT_WIN" "-1" "$STARTED_AT"
                rm -f "$OUTPUT_DIR/.next-window"
              fi

              echo "Unloading PipeWire modules..."
              pactl unload-module "$LOOPBACK_ID" 2>/dev/null || true
              pactl unload-module "$SINK_ID" 2>/dev/null || true

              # Preserve the raw transcript, then dedupe Me:/Them: bleed-through.
              if [ -s "$OUTPUT_DIR/transcript.txt" ]; then
                cp -f "$OUTPUT_DIR/transcript.txt" "$OUTPUT_DIR/transcript.raw.txt"
                python3 ${dedupePy} "$OUTPUT_DIR/transcript.txt" || true
              fi

              ELAPSED=$(( $(date +%s) - STARTED_AT ))
              rm -f "$STATE_FILE"

              cat <<EOF
      Stopped.
        Duration:   ''${ELAPSED}s
        Transcript: $OUTPUT_DIR/transcript.txt (raw: transcript.raw.txt)
        Chunks:     $OUTPUT_DIR/chunks/
      EOF
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

            cmd_status() {
              if [ ! -f "$STATE_FILE" ]; then
                echo "No active recording."
                exit 0
              fi
              # shellcheck disable=SC1090
              . "$STATE_FILE"
              FRAGMENTS=$(find "$OUTPUT_DIR/chunks" -name 'call_*.wav' -type f 2>/dev/null | wc -l)
              WINDOWS_DONE=0
              [ -f "$OUTPUT_DIR/.next-window" ] && WINDOWS_DONE=$(cat "$OUTPUT_DIR/.next-window")
              ELAPSED=$(( $(date +%s) - STARTED_AT ))
              TRANSCRIBED=$(wc -l < "$OUTPUT_DIR/transcript.txt" 2>/dev/null || echo 0)
              cat <<EOF
      Recording active.
        Started:      $(date -d "@$STARTED_AT" '+%Y-%m-%d %H:%M:%S')
        Elapsed:      ''${ELAPSED}s
        Fragments:    $FRAGMENTS (x ''${FRAGMENT_SEC}s)
        Windows done: $WINDOWS_DONE (window=''${WINDOW_SEC}s, advance=''${ADVANCE_SEC}s)
        Transcript:   $TRANSCRIBED lines
        Output:       $OUTPUT_DIR
      EOF
            }

            cmd_tail() {
              [ -f "$STATE_FILE" ] || { echo "No active recording." >&2; exit 1; }
              # shellcheck disable=SC1090
              . "$STATE_FILE"
              tail -F "$OUTPUT_DIR/transcript.txt"
            }

            # Move matching browser streams to Record-Call-Sink. Echoes the
            # number moved. Used by both the one-shot `record-call route`
            # command and the background auto-router.
            do_route() {
              local target="$1"
              local moved=0 id
              while read -r id; do
                [ -n "$id" ] || continue
                pactl move-sink-input "$id" "$target" 2>/dev/null && moved=$((moved + 1)) || true
              done < <(
                pactl -f json list sink-inputs 2>/dev/null | jq -r --argjson t "$target" '
                  .[]
                  | select(.sink != $t)
                  | select(
                      ((.properties."application.process.binary" // "") | ascii_downcase | test("chrome|chromium|brave|firefox"))
                      or
                      ((.properties."application.name" // "") | ascii_downcase | test("chrome|chromium|brave|google|firefox"))
                    )
                  | .index
                '
              )
              echo "$moved"
            }

            cmd_route() {
              TARGET=$(sink_index)
              if [ -z "$TARGET" ]; then
                echo "Record-Call-Sink is not loaded. Run 'record-call start' first." >&2
                exit 1
              fi
              MOVED=$(do_route "$TARGET")
              echo "Routed $MOVED stream(s) to Record-Call-Sink."
            }

            # Background auto-router: re-runs do_route every time pactl
            # reports a sink-input event. Handles the common failure mode
            # where the user starts recording before the call tab is open
            # (or refreshes the tab mid-call) — any new browser stream gets
            # captured automatically, no need to remember 'record-call route'.
            cmd__autoroute() {
              local TARGET
              for _ in $(seq 1 30); do
                TARGET=$(sink_index)
                [ -n "$TARGET" ] && break
                sleep 0.1
              done
              [ -n "$TARGET" ] || { echo "record-call sink never appeared" >&2; exit 1; }
              do_route "$TARGET" >/dev/null
              pactl subscribe 2>/dev/null | while read -r line; do
                case "$line" in
                  *"on sink-input"*)
                    # Brief settle delay — a freshly-created stream often
                    # reports its application properties a beat after the
                    # event fires, and we need those to match the filter.
                    sleep 0.1
                    do_route "$TARGET" >/dev/null
                    ;;
                esac
              done
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
              whisper-cli -m "$MODEL_PATH" -l en -nt -oj -of "$WORK/out" \
                -f "$WORK/mono.wav" >/dev/null 2>&1
              python3 ${mergePy} "$WORK/out.json" - 0 0 -1 0
            }

            cmd_diarize() {
              # Post-process: speaker-label the transcript using pyannote.
              # Args: <dir>   (the Recordings/calls/<ts>/ directory)
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

            cmd__watch() {
              OUT="$1"; FRAG="$2"; WIN="$3"; ADV="$4"; MODEL="$5"; VAD_MODEL="$6"; STARTED="$7"
              CHUNKS_DIR="$OUT/chunks"
              STATE="$OUT/.next-window"
              FPW=$(( WIN / FRAG ))
              AF=$(( ADV / FRAG ))

              next_window=0
              printf '%s\n' "$next_window" > "$STATE"

              # Window N is ready when both call_K and mic_K exist for K at
              # the window's final position. Track the min of the two sides'
              # top-finalized indices — that's the frontier safe for windowing.
              inotifywait -m -q -e close_write --format '%f' "$CHUNKS_DIR" | \
              while read -r fname; do
                case "$fname" in
                  call_*.wav|mic_*.wav) ;;
                  *) continue ;;
                esac
                call_top=$(find "$CHUNKS_DIR" -maxdepth 1 -name 'call_*.wav' -type f 2>/dev/null \
                  | sed -n 's|.*/call_0*\([0-9][0-9]*\)\.wav$|\1|p' | sort -n | tail -1)
                mic_top=$(find "$CHUNKS_DIR" -maxdepth 1 -name 'mic_*.wav' -type f 2>/dev/null \
                  | sed -n 's|.*/mic_0*\([0-9][0-9]*\)\.wav$|\1|p' | sort -n | tail -1)
                [ -n "$call_top" ] && [ -n "$mic_top" ] || continue
                top=$(( call_top < mic_top ? call_top : mic_top ))

                while [ $(( next_window * AF + FPW - 1 )) -le "$top" ]; do
                  emit_hi=$(( (next_window + 1) * ADV ))
                  process_window "$OUT" "$FRAG" "$WIN" "$ADV" "$MODEL" "$VAD_MODEL" "$next_window" "$emit_hi" "$STARTED"
                  next_window=$(( next_window + 1 ))
                  printf '%s\n' "$next_window" > "$STATE"
                done
              done
            }

            usage() {
              cat <<EOF
      record-call — capture browser conference calls locally and transcribe with Whisper.

      Usage:
        record-call start [output-dir]   Begin recording (default: ~/Recordings/calls/<ts>)
        record-call route                Move browser streams to Record-Call-Sink
        record-call status               Show the active session
        record-call tail                 Follow the live transcript
        record-call stop                 Stop recording, finalize transcript
        record-call transcribe <wav>     Offline: transcribe an existing audio file
        record-call dedupe <dir|txt>     Collapse near-duplicate lines within ~6s
        record-call retime <dir|txt>     Rewrite timestamps as wall-clock (HH:MM:SS local)
        record-call diarize <dir>        Speaker-label the transcript (needs HF_TOKEN)

      How it works:
        * Creates a PipeWire null-sink "Record-Call-Sink" with a loopback to your
          default output so you still hear the call.
        * A background auto-router watches PipeWire events and moves any
          matching browser sink-input (chrome/chromium/brave/firefox) onto
          Record-Call-Sink, even if the tab is opened/refreshed mid-session.
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
        * At stop, a final partial window is flushed so no audio is lost.

      If a stream isn't auto-routed, move it to Record-Call-Sink via
      pavucontrol (Playback tab) or by running 'record-call route'.
      EOF
            }

            CMD="''${1:-help}"
            shift || true
            case "$CMD" in
              start)       cmd_start "$@" ;;
              stop)        cmd_stop ;;
              status)      cmd_status ;;
              tail)        cmd_tail ;;
              route)       cmd_route ;;
              transcribe)  cmd_transcribe "$@" ;;
              dedupe)      cmd_dedupe "$@" ;;
              retime)      cmd_retime "$@" ;;
              diarize)     cmd_diarize "$@" ;;
              _watch)      cmd__watch "$@" ;;
              _autoroute)  cmd__autoroute ;;
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
      if [ -f "''${XDG_RUNTIME_DIR:-/tmp}/record-call/session.env" ]; then
        ng "another record-call session already active — run 'record-call stop' first"
      else
        TDIR=$(mktemp -d)
        # Small fragments so the test doesn't wait a full real window.
        export RECORD_CALL_FRAGMENT_SEC=2
        export RECORD_CALL_WINDOW_SEC=4
        export RECORD_CALL_ADVANCE_SEC=2
        record-call start "$TDIR" >/dev/null
        W=$(mktemp -d)
        espeak-ng -v en+f3 -s 150 -w "$W/clip.wav" \
          "This is an automated live capture test of the record call pipeline." 2>/dev/null
        # Play twice so we straddle at least one finalized chunk.
        # paplay hangs on final drain against null-sinks in PipeWire — wrap
        # in `timeout` so it exits once the clip has been written.
        timeout 6 paplay --device=record-call-sink "$W/clip.wav" 2>/dev/null || true
        sleep 1
        timeout 6 paplay --device=record-call-sink "$W/clip.wav" 2>/dev/null || true
        sleep 10
        record-call stop >/dev/null
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
