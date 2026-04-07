{
  config,
  pkgs,
  lib,
  hostName,
  ...
}:

let
  vault = "%h/projects/work/notes";
  image = "fulcrum:latest";
  docker = "${pkgs.docker}/bin/docker";
in

lib.mkIf (hostName == "prl-dev-vm") {
  systemd.user.services.fulcrum = {
    Unit = {
      Description = "Fulcrum AI assistant (Docker)";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };

    Service = {
      Type = "exec";
      Environment = [
        "PATH=${pkgs.docker}/bin:${config.home.profileDirectory}/bin:/run/current-system/sw/bin"
      ];
      ExecStartPre = "-${docker} rm -f fulcrum";
      ExecStart = lib.concatStringsSep " " [
        "${docker} run"
        "--name fulcrum"
        "--rm"
        "--network host"
        "--env-file ${vault}/.fulcrum/.env"
        "-e FULCRUM_PORT=3100"
        "-v ${vault}:/data"
        image
      ];
      ExecStop = "${docker} stop fulcrum";
      Restart = "on-failure";
      RestartSec = "5s";
    };

    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
