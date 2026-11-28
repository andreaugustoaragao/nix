{
  config,
  pkgs,
  lib,
  hostName,
  ...
}:

# Wayland voice dictation via voxtype.
#
# Both workstation and prl-dev-vm receive virtual Wayland input via Niri or
# Hyprland (workstation receives virtual input from prl-dev-vm over
# cursor-bridge), so evdev hotkeys are disabled (`hotkey.enabled = false`) and
# the compositor toggles recording with `F9` (`voxtype record toggle`).
#
# Output uses `wtype` with `fallback_to_clipboard = false` and an explicit
# `driver_order = ["wtype"]` so dictation never clobbers the clipboard synced
# by cursor-bridge.
let
  enabled = hostName == "workstation" || hostName == "prl-dev-vm";
  isWorkstation = hostName == "workstation";
  voxtypePkg = if isWorkstation then pkgs.voxtype-vulkan else pkgs.voxtype;
  scannerSoundConfig = config.my.voxtype.scannerSound;

  modelDir = "${config.home.homeDirectory}/.cache/whisper-cpp";
  modelName = "ggml-large-v3-turbo.bin";
  modelPath = "${modelDir}/${modelName}";
  modelUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${modelName}";

  ensureModel = pkgs.writeShellScript "voxtype-ensure-model" ''
    set -euo pipefail
    ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg modelDir}
    if [ ! -s ${lib.escapeShellArg modelPath} ]; then
      echo "Downloading Whisper model (~1.6GB) -> ${modelPath}"
      ${pkgs.curl}/bin/curl \
        --location --fail --continue-at - \
        --output ${lib.escapeShellArg "${modelPath}.tmp"} \
        ${lib.escapeShellArg modelUrl}
      ${pkgs.coreutils}/bin/mv ${lib.escapeShellArg "${modelPath}.tmp"} ${lib.escapeShellArg modelPath}
    fi
  '';

  voxtypeAutoStop = pkgs.writeShellApplication {
    name = "voxtype-auto-stop";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      exec python3 ${./voxtype-auto-stop.py} --voxtype-bin ${lib.getExe voxtypePkg} "$@"
    '';
  };

  recordingIndicator = pkgs.stdenv.mkDerivation {
    pname = "voxtype-recording-indicator";
    version = "1.0";
    src = ./voxtype-recording-indicator.c;
    dontUnpack = true;
    nativeBuildInputs = [
      pkgs.pkg-config
      pkgs.wrapGAppsHook3
    ];
    buildInputs = [
      pkgs.gtk3
      pkgs.gtk-layer-shell
    ];
    buildPhase = ''
      runHook preBuild
      $CC -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
        $(pkg-config --cflags gtk+-3.0 gtk-layer-shell-0) "$src" \
        $(pkg-config --libs gtk+-3.0 gtk-layer-shell-0) -lm -o voxtype-recording-indicator
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 voxtype-recording-indicator "$out/bin/voxtype-recording-indicator"
      runHook postInstall
    '';
    meta.mainProgram = "voxtype-recording-indicator";
  };

  scannerSound = pkgs.runCommand "voxtype-scanner-sound" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    mkdir -p "$out"
    python3 - "$out/start.wav" <<'PY'
    import math
    import struct
    import sys
    import wave

    sample_rate = 44100
    duration = 0.76
    sample_count = round(duration * sample_rate)
    samples = []
    for index in range(sample_count):
        time = index / sample_rate
        angle = math.tau * time
        # Shape two passes around a steady, slightly wobbly motor-like buzz.
        outward = math.exp(-((time - 0.19) / 0.10) ** 2)
        returning = math.exp(-((time - 0.53) / 0.13) ** 2)
        fade = min(1, time / 0.025, (sample_count - 1 - index) / (0.045 * sample_rate))
        flutter = 0.87 + 0.13 * math.sin(27 * angle)
        wobble = math.sin(3 * angle)
        motor = 0.15 * math.sin(96 * angle) + 0.07 * math.sin(192 * angle)
        scanner = (
            0.42 * math.sin(400 * angle + 0.5 * wobble)
            + 0.25 * math.sin(472 * angle - 0.7 * wobble)
            + 0.08 * math.sin(426 * angle)
            + 0.05 * math.sin(800 * angle + wobble)
        )
        envelope = fade * (0.94 * outward + 0.80 * returning)
        samples.append(round(32767 * envelope * (motor + flutter * scanner)))

    with wave.open(sys.argv[1], "wb") as sound:
        sound.setparams((1, 2, sample_rate, 0, "NONE", "not compressed"))
        sound.writeframes(struct.pack(f"<{sample_count}h", *samples))
    PY
  '';

  tomlFormat = pkgs.formats.toml { };
  configFile = tomlFormat.generate "voxtype-config.toml" {
    state_file = "auto";

    osd = {
      enabled = false;
    };

    hotkey = {
      enabled = false;
    };

    audio = {
      device = "default";
      sample_rate = 16000;
      max_duration_secs = 120;
    }
    // lib.optionalAttrs scannerSoundConfig.enable {
      feedback = {
        enabled = true;
        theme = "${scannerSound}";
        volume = scannerSoundConfig.volume * 1.0;
      };
    };

    whisper =
      if isWorkstation then
        {
          mode = "local";
          model = modelPath;
          language = "en";
          on_demand_loading = false;
        }
      else
        {
          mode = "remote";
          remote_endpoint = "http://mac-work.local:8081";
          remote_model = "whisper-1";
          remote_timeout_secs = 30;
          language = "en";
        };

    text = {
      smart_auto_submit = true;
      filter_filler_words = true;
    };

    output = {
      mode = "type";
      driver_order = [ "wtype" ];
      fallback_to_clipboard = false;
      append_text = " ";
      type_delay_ms = 0;
      pre_type_delay_ms = 50;
      notification = {
        on_recording_start = false;
        on_recording_stop = false;
        on_transcription = false;
      };
    };
  };
in
{
  options.my.voxtype.scannerStyle = lib.mkOption {
    type = lib.types.enum [
      "cylon"
      "kitt"
    ];
    default = "kitt";
    description = "Visual style for the Voxtype recording indicator.";
  };

  options.my.voxtype.scannerSound = {
    enable = lib.mkEnableOption "the scanner sound when dictation starts";

    volume = lib.mkOption {
      type = lib.types.numbers.between 0 1;
      default = 0.3;
      description = "Scanner sound playback volume, from 0 (silent) to 1 (full volume).";
    };
  };

  config = lib.mkIf enabled {
    home.packages = [
      voxtypePkg
      pkgs.wtype
    ];

    xdg.configFile."voxtype/config.toml".source = configFile;

    systemd.user.services.voxtype = {
      Unit = {
        Description = "Voxtype voice-to-text dictation daemon";
        After = [
          "graphical-session.target"
          "pipewire-pulse.service"
        ];
        PartOf = [ "graphical-session.target" ];
        ConditionEnvironment = "WAYLAND_DISPLAY";
        X-Restart-Triggers = [ configFile ];
      };
      Service = {
        ExecStart = "${lib.getExe voxtypePkg} daemon";
        Restart = "on-failure";
        RestartSec = 2;
      }
      // lib.optionalAttrs isWorkstation {
        ExecStartPre = "${ensureModel}";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    systemd.user.services.voxtype-auto-stop = {
      Unit = {
        Description = "Voxtype automatic end-of-utterance stop watcher";
        After = [ "voxtype.service" ];
        BindsTo = [ "voxtype.service" ];
        PartOf = [ "voxtype.service" ];
        ConditionEnvironment = "WAYLAND_DISPLAY";
      };
      Service = {
        ExecStart = lib.getExe voxtypeAutoStop;
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = [
        "graphical-session.target"
        "voxtype.service"
      ];
    };

    systemd.user.services.voxtype-recording-indicator = {
      Unit = {
        Description = "Voxtype recording indicator";
        After = [ "voxtype.service" ];
        BindsTo = [ "voxtype.service" ];
        PartOf = [ "voxtype.service" ];
        ConditionEnvironment = "WAYLAND_DISPLAY";
      };
      Service = {
        Environment = "GDK_BACKEND=wayland";
        ExecStart = "${lib.getExe recordingIndicator} %t/voxtype/state ${config.my.voxtype.scannerStyle}";
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = [
        "graphical-session.target"
        "voxtype.service"
      ];
    };
  };
}
