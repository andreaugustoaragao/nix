{
  config,
  lib,
  pkgs,
  ...
}:

let
  docker = "${pkgs.docker_29}/bin/docker";
  dataDir = "${config.home.homeDirectory}/projects/work/notes/.fulcrum/chroma";
  # Keep the currently deployed version while moving its database to the
  # actual /data path used by this image.
  chromaImage = "chromadb/chroma@sha256:1e0b73a187a28757c572acba508c46f48c9e8b0acaf5c20e6d95cdedce1acdf6";
in
{
  home.activation.rootlessDockerContext = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    runtimeDir="''${XDG_RUNTIME_DIR:-/run/user/$(${pkgs.coreutils}/bin/id -u)}"
    if ${docker} context inspect rootless >/dev/null 2>&1; then
      run ${docker} context update rootless --docker "host=unix://$runtimeDir/docker.sock"
    else
      run ${docker} context create rootless --docker "host=unix://$runtimeDir/docker.sock"
    fi
    run ${docker} context use rootless
  '';

  systemd.user.services.chroma = {
    Unit = {
      Description = "ChromaDB on rootless Docker";
      Requires = [ "docker.service" ];
      After = [ "docker.service" ];
      PartOf = [ "docker.service" ];
      StartLimitIntervalSec = 0;
    };
    Service = {
      Environment = "DOCKER_HOST=unix://%t/docker.sock";
      ExecStartPre = [
        "${pkgs.coreutils}/bin/mkdir -p ${dataDir}"
        "-${docker} rm -f chroma-rootless"
      ];
      ExecStart = lib.escapeShellArgs [
        docker
        "run"
        "--rm"
        "--name=chroma-rootless"
        "--pull=missing"
        "--publish=127.0.0.1:8000:8000"
        "--mount=type=bind,source=${dataDir},destination=/data"
        "--env=ANONYMIZED_TELEMETRY=FALSE"
        chromaImage
      ];
      ExecStop = "${docker} stop --time=30 chroma-rootless";
      Restart = "always";
      RestartSec = 5;
      TimeoutStartSec = 300;
      TimeoutStopSec = 45;
    };
    Install.WantedBy = [
      "default.target"
      "docker.service"
    ];
  };
}
