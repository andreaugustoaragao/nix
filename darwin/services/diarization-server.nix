{
  pkgs,
  lib,
  ...
}:

let
  version = "2.9.0";
  whisperServerApp = pkgs.stdenvNoCC.mkDerivation {
    pname = "whisper-server-fluid";
    inherit version;

    src = pkgs.fetchurl {
      url = "https://github.com/pfrankov/whisper-server/releases/download/${version}/WhisperServer.zip";
      hash = "sha256-2ZVXbYFFqc0+QH0udTdaD/CMkH5KNfFLrwMyCbDv2Og=";
    };

    nativeBuildInputs = [ pkgs.unzip ];
    sourceRoot = ".";

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/Applications"
      cp -R WhisperServer.app "$out/Applications/"

      runHook postInstall
    '';

    # Preserve the release's ad-hoc signature and native app bundle exactly.
    dontFixup = true;

    meta = {
      description = "Local OpenAI-compatible transcription and FluidAudio diarization server";
      homepage = "https://github.com/pfrankov/whisper-server";
      license = lib.licenses.mit;
      platforms = lib.platforms.darwin;
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  };

  appExecutable = "${whisperServerApp}/Applications/WhisperServer.app/Contents/MacOS/WhisperServer";
  bridgeHost = "10.211.55.2";
  bridgePort = 8082;
  appPort = 12017;

  proxyScript = pkgs.writeShellScript "diarization-server-proxy" ''
    set -euo pipefail
    exec ${pkgs.socat}/bin/socat \
      TCP-LISTEN:${toString bridgePort},bind=${bridgeHost},reuseaddr,fork \
      TCP:127.0.0.1:${toString appPort}
  '';
in
{
  environment.systemPackages = [
    whisperServerApp
    pkgs.socat
    (pkgs.writeShellScriptBin "diarization-server-health" ''
      exec ${pkgs.curl}/bin/curl --fail --silent --show-error \
        http://127.0.0.1:${toString appPort}/v1/models
    '')
    (pkgs.writeShellScriptBin "diarization-server-logs" ''
      exec ${pkgs.coreutils}/bin/tail -F \
        /tmp/diarization-server.out \
        /tmp/diarization-server.err \
        /tmp/diarization-proxy.out \
        /tmp/diarization-proxy.err
    '')
    (pkgs.writeShellScriptBin "diarization-server-restart" ''
      set -euo pipefail
      uid=$(${pkgs.coreutils}/bin/id -u)
      /bin/launchctl kickstart -k "gui/$uid/net.faragao.diarization-server"
      exec /bin/launchctl kickstart -k "gui/$uid/net.faragao.diarization-proxy"
    '')
  ];

  # WhisperServer remains loopback-only. A separate proxy exposes exactly the
  # Parallels bridge address instead of enabling the app's 0.0.0.0 LAN mode.
  launchd.user.agents = {
    diarization-server = {
      serviceConfig = {
        Label = "net.faragao.diarization-server";
        ProgramArguments = [ appExecutable ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "/tmp/diarization-server.out";
        StandardErrorPath = "/tmp/diarization-server.err";
        ThrottleInterval = 30;
        ProcessType = "Adaptive";
      };
    };

    diarization-proxy = {
      serviceConfig = {
        Label = "net.faragao.diarization-proxy";
        ProgramArguments = [ "${proxyScript}" ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "/tmp/diarization-proxy.out";
        StandardErrorPath = "/tmp/diarization-proxy.err";
        ThrottleInterval = 30;
        ProcessType = "Background";
      };
    };
  };
}
