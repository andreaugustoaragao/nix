{
  pkgs,
  unstable-pkgs,
  ...
}:
let
  layoutSync = pkgs.writeScriptBin "prl-display-layout" ''
    #!${pkgs.python3}/bin/python3
    ${builtins.readFile ./parallels-display-layout.py}
  '';
in
{
  systemd.user.services.prl-display-layout = {
    Unit = {
      Description = "Place Wayland outputs using the Parallels host display layout";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      Environment = [
        "NIRI_BIN=${unstable-pkgs.niri}/bin/niri"
        "HYPRCTL_BIN=${pkgs.hyprland}/bin/hyprctl"
        "TAIL_BIN=${pkgs.coreutils}/bin/tail"
        "UDEVADM_BIN=${pkgs.systemd}/bin/udevadm"
      ];
      ExecStart = "${layoutSync}/bin/prl-display-layout";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
