{
  pkgs,
  owner,
  homePrefix,
  ...
}:

let
  worker = pkgs.callPackage ../../pkgs/record-call-diarizer { };
  port = 12018;
  bridgePort = 8083;
  proxy = pkgs.writeShellScript "record-call-diarizer-proxy" ''
    exec ${pkgs.socat}/bin/socat \
      TCP-LISTEN:${toString bridgePort},bind=10.211.55.2,reuseaddr,fork \
      TCP:127.0.0.1:${toString port}
  '';
in
{
  environment.systemPackages = [
    worker
    (pkgs.writeShellScriptBin "record-call-diarizer-health" ''
      exec ${pkgs.curl}/bin/curl --fail --silent --show-error \
        http://127.0.0.1:${toString port}/health
    '')
    (pkgs.writeShellScriptBin "record-call-diarizer-logs" ''
      exec ${pkgs.coreutils}/bin/tail -F \
        /tmp/record-call-diarizer.out /tmp/record-call-diarizer.err \
        /tmp/record-call-diarizer-proxy.err
    '')
  ];

  launchd.user.agents = {
    record-call-diarizer.serviceConfig = {
      Label = "net.faragao.record-call-diarizer";
      ProgramArguments = [
        "${pkgs.python3}/bin/python3"
        "${./diarization-server.py}"
        "--worker"
        "${worker}/bin/record-call-diarizer"
        "--port"
        (toString port)
      ];
      EnvironmentVariables = {
        RECORD_CALL_DIARIZER_MODEL_DIR = "${homePrefix}/${owner.name}/.cache/record-call-diarizer/models";
        # The CPU path is fast for this workload and leaves the GPU available
        # to Whisper if a new call starts while an earlier call is finalizing.
        RECORD_CALL_DIARIZER_CPU_ONLY = "1";
      };
      RunAtLoad = true;
      KeepAlive = true;
      Nice = 10;
      ProcessType = "Background";
      ThrottleInterval = 30;
      StandardOutPath = "/tmp/record-call-diarizer.out";
      StandardErrorPath = "/tmp/record-call-diarizer.err";
    };
    record-call-diarizer-proxy.serviceConfig = {
      Label = "net.faragao.record-call-diarizer-proxy";
      ProgramArguments = [ "${proxy}" ];
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      ThrottleInterval = 30;
      StandardOutPath = "/tmp/record-call-diarizer-proxy.out";
      StandardErrorPath = "/tmp/record-call-diarizer-proxy.err";
    };
  };
}
