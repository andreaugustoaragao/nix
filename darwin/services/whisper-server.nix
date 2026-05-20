{
  config,
  pkgs,
  lib,
  owner,
  homePrefix,
  ...
}:

let
  # Reuse the workstation's whisper-cpp model cache layout
  # (XDG_CACHE_HOME defaults to ~/.cache on both Linux and macOS) so
  # the model file and `record-call`'s expected path are identical
  # across hosts. nixpkgs ships `whisper-server` in the default
  # whisper-cpp derivation on Darwin — confirmed via ls of the
  # build's bin/ directory.
  homeDir = "${homePrefix}/${owner.name}";
  modelDir = "${homeDir}/.cache/whisper-cpp";

  # Same large-v3-turbo model record-call uses on workstation, so a
  # call recorded on prl-dev-vm + transcribed on mac-work produces the
  # same output a workstation recording would.
  modelName = "ggml-large-v3-turbo.bin";
  modelPath = "${modelDir}/${modelName}";
  modelUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${modelName}";

  # Silero VAD model — server-side --vad needs an explicit weights
  # file. Skipping VAD on the server would force every client to
  # re-implement silence trimming, and record-call already relies on
  # VAD to keep Whisper from hallucinating "Thanks for watching" on
  # silent mic gaps.
  vadModelName = "ggml-silero-v5.1.2.bin";
  vadModelPath = "${modelDir}/${vadModelName}";
  vadModelUrl = "https://huggingface.co/ggml-org/whisper-vad/resolve/main/${vadModelName}";

  # Same Parallels host stub as local-llm.nix — see that file's
  # comment for why this is 10.211.55.2 (the Mac's NIC) and not
  # 10.211.55.1 (the VM's gateway endpoint).
  bindHost = "10.211.55.2";
  port = 8081;

  ensureModels = pkgs.writeShellScript "whisper-server-ensure-models" ''
    set -euo pipefail
    mkdir -p ${lib.escapeShellArg modelDir}
    if [ ! -s ${lib.escapeShellArg modelPath} ]; then
      echo "Downloading Whisper model (~1.6GB) -> ${modelPath}"
      ${pkgs.curl}/bin/curl \
        --location --fail --continue-at - \
        --output ${lib.escapeShellArg modelPath} \
        ${lib.escapeShellArg modelUrl}
    fi
    if [ ! -s ${lib.escapeShellArg vadModelPath} ]; then
      echo "Downloading Silero VAD model (~2MB) -> ${vadModelPath}"
      ${pkgs.curl}/bin/curl \
        --location --fail --continue-at - \
        --output ${lib.escapeShellArg vadModelPath} \
        ${lib.escapeShellArg vadModelUrl}
    fi
  '';

  startScript = pkgs.writeShellScript "whisper-server-start" ''
    set -euo pipefail
    # --convert: have whisper-server transcode incoming audio (m4a,
    # ogg, webm, …) to 16kHz mono WAV via ffmpeg before inference.
    # record-call already feeds it 16k mono PCM, but Fulcrum's voice
    # messages arrive in browser-native formats and the conversion
    # belongs on the Mac side where ffmpeg is fast and GPU-adjacent.
    export PATH=${pkgs.ffmpeg}/bin:$PATH
    ${ensureModels}
    exec ${pkgs.whisper-cpp}/bin/whisper-server \
      --host ${bindHost} \
      --port ${toString port} \
      --inference-path /v1/audio/transcriptions \
      --model ${lib.escapeShellArg modelPath} \
      --vad \
      --vad-model ${lib.escapeShellArg vadModelPath} \
      --convert \
      --tmp-dir /tmp
  '';
in
{
  environment.systemPackages = [
    pkgs.whisper-cpp
    pkgs.ffmpeg
    (pkgs.writeShellScriptBin "whisper-server-download" ''
      exec ${ensureModels}
    '')
    (pkgs.writeShellScriptBin "whisper-server-logs" ''
      exec ${pkgs.coreutils}/bin/tail -F /tmp/whisper-server.out /tmp/whisper-server.err
    '')
    (pkgs.writeShellScriptBin "whisper-server-restart" ''
      set -euo pipefail
      uid=$(${pkgs.coreutils}/bin/id -u)
      exec /bin/launchctl kickstart -k "gui/$uid/net.faragao.whisper-server"
    '')
  ];

  launchd.user.agents.whisper-server = {
    serviceConfig = {
      Label = "net.faragao.whisper-server";
      ProgramArguments = [ "${startScript}" ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "/tmp/whisper-server.out";
      StandardErrorPath = "/tmp/whisper-server.err";
      ThrottleInterval = 30;
      # Adaptive: throttle when idle, full priority while a request is
      # being served. Whisper requests are bursty (per voice message
      # or per record-call window) — Interactive is wasteful here.
      ProcessType = "Adaptive";
      # See local-llm.nix for the full rationale — launchd's bare env
      # breaks curl behind Zscaler. Re-use the Avaya/Zscaler/system
      # bundle from darwin/certs.nix so we follow the same source of
      # truth the rest of the Darwin toolchain uses.
      EnvironmentVariables = {
        inherit (config.environment.variables) SSL_CERT_FILE NIX_SSL_CERT_FILE;
      };
    };
  };
}
