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
        on_recording_start = true;
        on_recording_stop = false;
        on_transcription = true;
      };
    };
  };
in
lib.mkIf enabled {
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
}
