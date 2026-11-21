{
  pkgs,
  lib,
  hostName,
  ...
}:

# One keyboard and mouse between prl-dev-vm and the workstation. The VM owns
# the devices. Both machines run lan-mouse against loopback, and cursor-bridge
# carries its datagrams both ways over the single QUIC connection the VM
# opens. The workstation cannot address the VM, so nothing listens there.
let
  bridge = pkgs.callPackage ../../pkgs/cursor-bridge.nix { };
  port = 4242;
  loopback = "127.0.0.1:${toString port}";
  bridgePort = 4243;
  release = ''["KeyScrollLock"]'';
  role =
    if hostName == "workstation" then
      "listen"
    else if hostName == "prl-dev-vm" then
      "dial"
    else
      null;
in
lib.mkIf (role != null) {
  home.packages = [
    pkgs.lan-mouse
    bridge
  ];

  xdg.configFile."lan-mouse/config.toml".text =
    if role == "listen" then
      ''
        port = ${toString port}
        release_bind = ${release}

        [left]
        hostname = "localhost"
        ips = ["127.0.0.1"]
        port = ${toString port}
        activate_on_startup = true
      ''
    else
      ''
        port = ${toString port}
        release_bind = ${release}

        [right]
        hostname = "localhost"
        ips = ["127.0.0.1"]
        port = ${toString port}
        activate_on_startup = true
      '';

  systemd.user.services.lan-mouse = {
    Unit = {
      Description = "Share the keyboard and pointer with the other machine";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      ExecStart = [ "${lib.getExe pkgs.lan-mouse} --daemon" ];
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.cursor-bridge = {
    Unit = {
      Description = "Carry the shared pointer across one connection";
      After = [
        "graphical-session.target"
        "lan-mouse.service"
      ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      ExecStart = [
        (
          if role == "listen" then
            "${lib.getExe bridge} --listen --local 127.0.0.1:${toString bridgePort} --peer ${loopback} --cert %d/cert --key %d/key"
          else
            "${lib.getExe bridge} --dial --local 127.0.0.1:${toString bridgePort} --peer 192.168.10.75:${toString bridgePort} --cert %d/cert --key %d/key --input /dev/input/event0"
        )
      ];
      Restart = "on-failure";
      RestartSec = 2;
      SupplementaryGroups = lib.optionals (role == "dial") [ "input" ];
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
