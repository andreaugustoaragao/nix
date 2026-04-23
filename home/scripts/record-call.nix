{ pkgs, isWorkstation, ... }:

let
  # Enable Vulkan on the workstation (AMD RX 7900 XT via Mesa RADV) for
  # ~10x realtime transcription. Other hosts stay on the CPU build.
  whisperPkg =
    if isWorkstation then pkgs.whisper-cpp.override { vulkanSupport = true; } else pkgs.whisper-cpp;

  binPath = pkgs.lib.makeBinPath [
    pkgs.pulseaudio
    pkgs.ffmpeg
    whisperPkg
    pkgs.inotify-tools
    pkgs.jq
    pkgs.python3
    pkgs.curl
    pkgs.coreutils
    pkgs.gnused
    pkgs.gawk
    pkgs.procps
  ];

  mergePy = pkgs.writeText "record-call-merge.py" ''
    import json, sys
    left, right, off = sys.argv[1], sys.argv[2], int(sys.argv[3])

    def load(path, label):
        try:
            with open(path) as f:
                data = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            return []
        segs = data.get("transcription", [])
        out = []
        for s in segs:
            t = s.get("offsets", {}).get("from", 0) / 1000.0
            text = s.get("text", "").strip()
            if text:
                out.append((t + off, label, text))
        return out

    entries = load(left, "Me") + load(right, "Them")
    entries.sort(key=lambda e: e[0])
    for t, who, text in entries:
        h, rem = divmod(int(t), 3600)
        m, s = divmod(rem, 60)
        print(f"[{h:02d}:{m:02d}:{s:02d}] {who}: {text}")
  '';
in
{
  home.packages = [
    (pkgs.writeShellScriptBin "record-call" ''
            set -euo pipefail
            export PATH="${binPath}:$PATH"

            SINK_NAME="record-call-sink"
            CHUNK_SEC="''${RECORD_CALL_CHUNK_SEC:-60}"
            MODEL_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/whisper-cpp"
            MODEL_NAME="ggml-large-v3-turbo.bin"
            MODEL_PATH="$MODEL_DIR/$MODEL_NAME"
            MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_NAME"
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
            }

            sink_index() {
              pactl -f json list sinks | jq -r --arg n "$SINK_NAME" '.[] | select(.name == $n) | .index' | head -1
            }

            cmd_start() {
              if [ -f "$STATE_FILE" ]; then
                echo "A recording is already active. Run 'record-call stop' first." >&2
                exit 1
              fi

              ensure_model

              OUTPUT_DIR="''${1:-$HOME/Recordings/calls/$(date +%Y%m%d-%H%M%S)}"
              mkdir -p "$OUTPUT_DIR/chunks"
              touch "$OUTPUT_DIR/transcript.txt"

              SINK_ID=$(pactl load-module module-null-sink \
                sink_name="$SINK_NAME" \
                sink_properties='device.description="Record-Call-Sink"')
              LOOPBACK_ID=$(pactl load-module module-loopback \
                source="$SINK_NAME.monitor" \
                sink="@DEFAULT_SINK@" \
                latency_msec=50)

              ( exec ffmpeg -hide_banner -loglevel warning -nostdin \
                  -f pulse -ac 1 -i "@DEFAULT_SOURCE@" \
                  -f pulse -ac 1 -i "$SINK_NAME.monitor" \
                  -filter_complex "[0:a][1:a]amerge=inputs=2[a]" \
                  -map "[a]" -ac 2 -ar 16000 -c:a pcm_s16le \
                  -f segment -segment_time "$CHUNK_SEC" -reset_timestamps 1 \
                  "$OUTPUT_DIR/chunks/chunk_%06d.wav" \
                  > "$OUTPUT_DIR/ffmpeg.log" 2>&1 ) &
              FFMPEG_PID=$!

              ( exec "$0" _watch "$OUTPUT_DIR" "$CHUNK_SEC" "$MODEL_PATH" \
                  > "$OUTPUT_DIR/watcher.log" 2>&1 ) &
              WATCHER_PID=$!

              cat > "$STATE_FILE" <<EOF
      SINK_ID=$SINK_ID
      LOOPBACK_ID=$LOOPBACK_ID
      FFMPEG_PID=$FFMPEG_PID
      WATCHER_PID=$WATCHER_PID
      OUTPUT_DIR=$OUTPUT_DIR
      CHUNK_SEC=$CHUNK_SEC
      STARTED_AT=$(date +%s)
      EOF

              cat <<EOF
      Recording started.
        Output:     $OUTPUT_DIR
        Transcript: $OUTPUT_DIR/transcript.txt

      Route the call audio to the recording sink via pavucontrol (Playback tab
      -> select Record-Call-Sink for the Chrome/Brave stream), or run:
          record-call route

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

              echo "Stopping ffmpeg (flushing last chunk)..."
              kill -TERM "$FFMPEG_PID" 2>/dev/null || true
              # Wait for ffmpeg to flush the final segment
              for _ in $(seq 1 20); do
                kill -0 "$FFMPEG_PID" 2>/dev/null || break
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

              echo "Unloading PipeWire modules..."
              pactl unload-module "$LOOPBACK_ID" 2>/dev/null || true
              pactl unload-module "$SINK_ID" 2>/dev/null || true

              ELAPSED=$(( $(date +%s) - STARTED_AT ))
              rm -f "$STATE_FILE"

              cat <<EOF
      Stopped.
        Duration:   ''${ELAPSED}s
        Transcript: $OUTPUT_DIR/transcript.txt
        Chunks:     $OUTPUT_DIR/chunks/
      EOF
            }

            cmd_status() {
              if [ ! -f "$STATE_FILE" ]; then
                echo "No active recording."
                exit 0
              fi
              # shellcheck disable=SC1090
              . "$STATE_FILE"
              CHUNKS=$(find "$OUTPUT_DIR/chunks" -name 'chunk_*.wav' -type f 2>/dev/null | wc -l)
              ELAPSED=$(( $(date +%s) - STARTED_AT ))
              TRANSCRIBED=$(wc -l < "$OUTPUT_DIR/transcript.txt" 2>/dev/null || echo 0)
              cat <<EOF
      Recording active.
        Started:     $(date -d "@$STARTED_AT" '+%Y-%m-%d %H:%M:%S')
        Elapsed:     ''${ELAPSED}s
        Chunks:      $CHUNKS (x ''${CHUNK_SEC}s)
        Transcript:  $TRANSCRIBED lines
        Output:      $OUTPUT_DIR
      EOF
            }

            cmd_tail() {
              [ -f "$STATE_FILE" ] || { echo "No active recording." >&2; exit 1; }
              # shellcheck disable=SC1090
              . "$STATE_FILE"
              tail -F "$OUTPUT_DIR/transcript.txt"
            }

            cmd_route() {
              TARGET=$(sink_index)
              if [ -z "$TARGET" ]; then
                echo "Record-Call-Sink is not loaded. Run 'record-call start' first." >&2
                exit 1
              fi
              MOVED=0
              while read -r id; do
                [ -n "$id" ] || continue
                pactl move-sink-input "$id" "$TARGET" 2>/dev/null && MOVED=$((MOVED + 1)) || true
              done < <(
                pactl -f json list sink-inputs 2>/dev/null | jq -r --argjson t "$TARGET" '
                  .[]
                  | select(.sink != $t)
                  | select(
                      ((.properties."application.process.binary" // "") | ascii_downcase | test("chrome|chromium|brave"))
                      or
                      ((.properties."application.name" // "") | ascii_downcase | test("chrome|chromium|brave|google"))
                    )
                  | .index
                '
              )
              echo "Routed $MOVED stream(s) to Record-Call-Sink."
            }

            cmd_transcribe() {
              # Offline: transcribe an existing stereo WAV into a labeled transcript.
              SRC="''${1:-}"
              [ -n "$SRC" ] && [ -f "$SRC" ] || { echo "Usage: record-call transcribe <stereo.wav>" >&2; exit 1; }
              ensure_model
              WORK="$(mktemp -d)"
              trap 'rm -rf "$WORK"' EXIT
              ffmpeg -hide_banner -loglevel error -y -i "$SRC" \
                -af "pan=mono|c0=c0" -ar 16000 -c:a pcm_s16le "$WORK/left.wav" \
                -af "pan=mono|c0=c1" -ar 16000 -c:a pcm_s16le "$WORK/right.wav"
              whisper-cli -m "$MODEL_PATH" -l en -nt -oj -of "$WORK/left"  -f "$WORK/left.wav"  >/dev/null 2>&1 &
              whisper-cli -m "$MODEL_PATH" -l en -nt -oj -of "$WORK/right" -f "$WORK/right.wav" >/dev/null 2>&1 &
              wait
              python3 ${mergePy} "$WORK/left.json" "$WORK/right.json" 0
            }

            cmd__watch() {
              OUT="$1"; CS="$2"; MODEL="$3"
              CHUNKS_DIR="$OUT/chunks"
              TRANSCRIPT="$OUT/transcript.txt"

              inotifywait -m -q -e close_write --format '%f' "$CHUNKS_DIR" | \
              while read -r fname; do
                case "$fname" in
                  chunk_*.wav) ;;
                  *) continue ;;
                esac
                path="$CHUNKS_DIR/$fname"
                idx=$(echo "$fname" | sed -n 's/^chunk_0*\([0-9][0-9]*\)\.wav$/\1/p')
                [ -n "$idx" ] || { idx=0; }
                offset=$(( idx * CS ))

                work=$(mktemp -d)
                ffmpeg -hide_banner -loglevel error -y -i "$path" \
                  -af "pan=mono|c0=c0" -ar 16000 -c:a pcm_s16le "$work/left.wav" \
                  -af "pan=mono|c0=c1" -ar 16000 -c:a pcm_s16le "$work/right.wav" \
                  </dev/null

                whisper-cli -m "$MODEL" -l en -nt -oj -of "$work/left"  -f "$work/left.wav"  </dev/null >"$work/left.log"  2>&1 &
                whisper-cli -m "$MODEL" -l en -nt -oj -of "$work/right" -f "$work/right.wav" </dev/null >"$work/right.log" 2>&1 &
                wait

                python3 ${mergePy} "$work/left.json" "$work/right.json" "$offset" >> "$TRANSCRIPT"

                rm -rf "$work"
              done
            }

            usage() {
              cat <<EOF
      record-call — capture browser conference calls locally and transcribe with Whisper.

      Usage:
        record-call start [output-dir]   Begin recording (default: ~/Recordings/calls/<ts>)
        record-call route                Move Chrome/Brave streams to Record-Call-Sink
        record-call status               Show the active session
        record-call tail                 Follow the live transcript
        record-call stop                 Stop recording, finalize transcript
        record-call transcribe <wav>     Offline: transcribe an existing stereo WAV

      How it works:
        * Creates a PipeWire null-sink "Record-Call-Sink" with a loopback to your
          default output so you still hear the call.
        * ffmpeg captures your mic (L) and the sink monitor (R) as one stereo stream,
          segmented into ''${CHUNK_SEC}s WAV chunks under <output-dir>/chunks/.
        * A background watcher splits each finished chunk, runs whisper-cli per
          channel, and appends [HH:MM:SS] Me/Them lines to transcript.txt.

      Route Chrome/Brave output to Record-Call-Sink either via pavucontrol
      (Playback tab) or by running 'record-call route' once the call is active.
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
              _watch)      cmd__watch "$@" ;;
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
      espeak-ng -v en+m1 -s 150 -w "$W/me.wav"   \
        "Hello, this is the left channel speaker verifying the microphone path." 2>/dev/null
      espeak-ng -v en+f3 -s 150 -w "$W/them.wav" \
        "And this is the right channel speaker simulating the remote participant." 2>/dev/null
      ffmpeg -hide_banner -loglevel error -y \
        -i "$W/me.wav" -i "$W/them.wav" \
        -filter_complex "[0:a][1:a]amerge=inputs=2[a]" \
        -map "[a]" -ac 2 -ar 16000 "$W/stereo.wav"
      OUT=$(record-call transcribe "$W/stereo.wav" 2>&1 || true)
      echo "$OUT" | sed 's/^/    /'
      if echo "$OUT" | grep -q '^\[.*\] Me:' && echo "$OUT" | grep -q '^\[.*\] Them:'; then
        ok "both Me: and Them: labels present"
      else
        ng "missing Me: or Them: labels"
      fi
      rm -rf "$W"

      # ----- Test 2: live capture -----
      step "Live capture (PipeWire sink + ffmpeg segmenter + watcher)"
      if [ -f "''${XDG_RUNTIME_DIR:-/tmp}/record-call/session.env" ]; then
        ng "another record-call session already active — run 'record-call stop' first"
      else
        TDIR=$(mktemp -d)
        export RECORD_CALL_CHUNK_SEC=10
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
        # Wait for chunk (10s) + processing
        sleep 20
        record-call stop >/dev/null
        echo "    transcript:"
        sed 's/^/      /' "$TDIR/transcript.txt" 2>/dev/null || true
        if [ -s "$TDIR/transcript.txt" ] && grep -qi 'them:' "$TDIR/transcript.txt"; then
          ok "live transcript contains Them: line(s)"
        else
          ng "live transcript empty or missing Them: label (see $TDIR)"
        fi
        rm -rf "$W"
      fi

      printf '\n== Results: %d passed, %d failed ==\n' "$PASS" "$FAIL"
      [ "$FAIL" = 0 ]
    '')
  ];
}
